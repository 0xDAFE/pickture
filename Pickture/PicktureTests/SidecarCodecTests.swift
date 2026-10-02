import Foundation
import Testing
@testable import Pickture

struct SidecarCodecTests {

    private func makeTemporaryDirectory() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("PicktureSidecarTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    // MARK: - Sidecar Discovery & Dual-Convention Precedence

    @Test("Sidecar read discovery checks <basename>.xmp and <filename>.<ext>.xmp, preferring <basename>.xmp when both exist")
    func sidecarReadDiscoveryPrecedence() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let rawURL = root.appendingPathComponent("DSC0100.ARW")
        let jpgURL = root.appendingPathComponent("DSC0100.JPG")
        try Data("raw".utf8).write(to: rawURL)
        try Data("jpg".utf8).write(to: jpgURL)

        let rawFile = MediaFile(url: rawURL, formatKind: .raw)
        let jpgFile = MediaFile(url: jpgURL, formatKind: .raster)
        let pair = MediaPair(rawFile: rawFile, rasterFile: jpgFile)
        let pairItem = MediaItem(
            id: "\(root.path)#DSC0100",
            baseName: "DSC0100",
            directoryURL: root,
            relativeDirectoryPath: "",
            kind: .photo,
            primaryFile: jpgFile,
            mediaPair: pair,
            sidecarURL: nil
        )

        let basenameXmp = root.appendingPathComponent("DSC0100.xmp")
        let extensionXmp = root.appendingPathComponent("DSC0100.ARW.xmp")

        // 1. Neither sidecar exists
        #expect(SidecarCodec.resolveSidecarReadURL(for: pairItem) == nil)

        // 2. Only <filename>.<ext>.xmp exists -> returns extensionXmp
        try Data("<xmp:extension/>".utf8).write(to: extensionXmp)
        #expect(SidecarCodec.resolveSidecarReadURL(for: pairItem)?.standardizedFileURL == extensionXmp.standardizedFileURL)

        // 3. Both exist -> prefers <basename>.xmp
        try Data("<xmp:basename/>".utf8).write(to: basenameXmp)
        #expect(SidecarCodec.resolveSidecarReadURL(for: pairItem)?.standardizedFileURL == basenameXmp.standardizedFileURL)
    }

    @Test("Sidecar write targets write <basename>.xmp by default and update <filename>.<ext>.xmp if it already exists")
    func sidecarWriteTargetsDualConvention() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let rawURL = root.appendingPathComponent("DSC0200.CR3")
        let jpgURL = root.appendingPathComponent("DSC0200.JPG")
        try Data("raw".utf8).write(to: rawURL)
        try Data("jpg".utf8).write(to: jpgURL)

        let rawFile = MediaFile(url: rawURL, formatKind: .raw)
        let jpgFile = MediaFile(url: jpgURL, formatKind: .raster)
        let pair = MediaPair(rawFile: rawFile, rasterFile: jpgFile)
        let pairItem = MediaItem(
            id: "\(root.path)#DSC0200",
            baseName: "DSC0200",
            directoryURL: root,
            relativeDirectoryPath: "",
            kind: .photo,
            primaryFile: jpgFile,
            mediaPair: pair,
            sidecarURL: nil
        )

        let basenameXmp = root.appendingPathComponent("DSC0200.xmp")
        let rawExtXmp = root.appendingPathComponent("DSC0200.CR3.xmp")
        let jpgExtXmp = root.appendingPathComponent("DSC0200.JPG.xmp")

        // Case A: No existing sidecars on disk -> write target is only <basename>.xmp
        let targetsInitial = SidecarCodec.resolveSidecarWriteURLs(for: pairItem)
        #expect(targetsInitial.map(\.standardizedFileURL) == [basenameXmp.standardizedFileURL])

        // Case B: An external tool created DSC0200.CR3.xmp on disk -> write targets include BOTH
        try Data("<existing/>".utf8).write(to: rawExtXmp)
        let targetsWithRawXmp = SidecarCodec.resolveSidecarWriteURLs(for: pairItem)
        let targetsPaths = Set(targetsWithRawXmp.map(\.standardizedFileURL.path))
        #expect(targetsPaths.contains(basenameXmp.standardizedFileURL.path))
        #expect(targetsPaths.contains(rawExtXmp.standardizedFileURL.path))
        #expect(!targetsPaths.contains(jpgExtXmp.standardizedFileURL.path))
    }

    // MARK: - CurationMetadata Parsing & Dialect Normalization

    @Test("Parse Lightroom attribute-style CurationMetadata (crs:Pick, xmp:Rating, xmp:Label)")
    func parseLightroomAttributeStyleCurationMetadata() throws {
        let xml = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about=""
            xmlns:xmp="http://ns.adobe.com/xap/1.0/"
            xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
            xmp:Rating="4"
            crs:Pick="1"
            xmp:Label="Red">
          </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>
        """
        let data = Data(xml.utf8)
        let parsed = try SidecarCodec.parse(data: data)
        #expect(parsed.curation.starRating == 4)
        #expect(parsed.curation.pickFlag == .picked)
        #expect(parsed.curation.colorLabel == .red)
    }

    @Test("Parse element-style CurationMetadata (Capture One / element tags) and xmpDM:pick")
    func parseElementStyleCurationMetadata() throws {
        let xml = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about=""
            xmlns:xmp="http://ns.adobe.com/xap/1.0/"
            xmlns:xmpDM="http://ns.adobe.com/xmp/1.0/DynamicMedia/">
           <xmp:Rating>3</xmp:Rating>
           <xmpDM:pick>1</xmpDM:pick>
           <xmp:Label>Green</xmp:Label>
          </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>
        """
        let data = Data(xml.utf8)
        let parsed = try SidecarCodec.parse(data: data)
        #expect(parsed.curation.starRating == 3)
        #expect(parsed.curation.pickFlag == .picked)
        #expect(parsed.curation.colorLabel == .green)
    }

    @Test("Incoming xmp:Rating='-1' without explicit crs:Pick is normalized to PickFlag.rejected and StarRating(0)")
    func legacyBridgeRatingMinusOneNormalization() throws {
        let xml = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about=""
            xmlns:xmp="http://ns.adobe.com/xap/1.0/"
            xmp:Rating="-1">
          </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>
        """
        let data = Data(xml.utf8)
        let parsed = try SidecarCodec.parse(data: data)
        #expect(parsed.curation.pickFlag == .rejected)
        #expect(parsed.curation.starRating == 0)
    }

    @Test("Parse various color label values and aliases")
    func parseColorLabels() throws {
        func checkLabel(_ text: String, expected: ColorLabel) throws {
            let xml = """
            <x:xmpmeta xmlns:x="adobe:ns:meta/">
             <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
              <rdf:Description rdf:about="" xmlns:xmp="http://ns.adobe.com/xap/1.0/" xmp:Label="\(text)"/>
             </rdf:RDF>
            </x:xmpmeta>
            """
            let parsed = try SidecarCodec.parse(data: Data(xml.utf8))
            #expect(parsed.curation.colorLabel == expected)
        }

        try checkLabel("Yellow", expected: .yellow)
        try checkLabel("blue", expected: .blue)
        try checkLabel("Purple", expected: .purple)
        try checkLabel("Gray", expected: .grey)
        try checkLabel("Grey", expected: .grey)
        try checkLabel("Orange", expected: .orange)
        try checkLabel("None", expected: .none)
    }

    // MARK: - ExifMetadata Parsing

    @Test("Parse EXIF attributes in XMP (tiff:Model, aux:Lens, exif:FocalLength, exif:FNumber, exif:ExposureTime, exif:ISOSpeedRatings, exif:DateTimeOriginal)")
    func parseExifAttributesFromXMP() throws {
        let xml = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about=""
            xmlns:tiff="http://ns.adobe.com/tiff/1.0/"
            xmlns:exif="http://ns.adobe.com/exif/1.0/"
            xmlns:aux="http://ns.adobe.com/exif/1.0/aux/"
            tiff:Model="Sony Alpha 1"
            aux:Lens="FE 50mm F1.2 GM"
            exif:FocalLength="50/1"
            exif:FNumber="14/10"
            exif:ExposureTime="1/500"
            exif:DateTimeOriginal="2026-09-29T14:30:00Z">
           <exif:ISOSpeedRatings>
            <rdf:Seq>
             <rdf:li>100</rdf:li>
            </rdf:Seq>
           </exif:ISOSpeedRatings>
          </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>
        """
        let parsed = try SidecarCodec.parse(data: Data(xml.utf8))
        let exif = parsed.exif

        #expect(exif.cameraModel == "Sony Alpha 1")
        #expect(exif.lensModel == "FE 50mm F1.2 GM")
        #expect(exif.focalLength == 50.0)
        #expect(exif.fNumber == 1.4)
        #expect(exif.exposureTime == 0.002) // 1/500
        #expect(exif.isoSpeedRatings == [100])
        #expect(exif.dateTimeOriginal != nil)
    }

    // MARK: - Round-Trip Updating & Third-Party Node Preservation

    @Test("Update XMP patches only curation metadata while preserving third-party namespaces, develop tags, and child nodes intact")
    func updateXMPPreservesThirdPartyNodes() throws {
        let originalXML = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about=""
            xmlns:xmp="http://ns.adobe.com/xap/1.0/"
            xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
            xmlns:exif="http://ns.adobe.com/exif/1.0/"
            xmlns:custom="http://example.com/desktop/develop"
            crs:Exposure2012="+0.75"
            crs:Temperature="6200"
            crs:Tint="+10"
            crs:Pick="0"
            xmp:Rating="1"
            xmp:Label="Blue">
           <crs:ToneCurve>
            <rdf:Seq>
             <rdf:li>0, 0</rdf:li>
             <rdf:li>255, 255</rdf:li>
            </rdf:Seq>
           </crs:ToneCurve>
           <custom:Adjustments version="2.0">
            <custom:Param name="Vibrance" value="+15"/>
           </custom:Adjustments>
          </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>
        """
        let originalData = Data(originalXML.utf8)
        let newCuration = CurationMetadata(
            starRating: 5,
            pickFlag: .picked,
            colorLabel: .yellow
        )

        let updatedData = try SidecarCodec.update(xmlData: originalData, with: newCuration)
        let updatedString = String(decoding: updatedData, as: UTF8.self)

        // 1. Unrelated namespaces and attributes preserved
        #expect(updatedString.contains("xmlns:custom=\"http://example.com/desktop/develop\""))
        #expect(updatedString.contains("crs:Exposure2012=\"+0.75\""))
        #expect(updatedString.contains("crs:Temperature=\"6200\""))
        #expect(updatedString.contains("crs:Tint=\"+10\""))

        // 2. Unrelated child nodes preserved
        #expect(updatedString.contains("<crs:ToneCurve>"))
        #expect(updatedString.contains("<custom:Adjustments"))
        #expect(updatedString.contains("custom:Param"))

        // 3. Curation metadata updated
        #expect(updatedString.contains("crs:Pick=\"1\""))
        #expect(updatedString.contains("xmp:Rating=\"5\""))
        #expect(updatedString.contains("xmp:Label=\"Yellow\""))
        #expect(updatedString.contains("xmpDM:pick=\"1\""))

        // 4. Re-parsing the updated document returns the new curation values
        let reParsed = try SidecarCodec.parse(data: updatedData)
        #expect(reParsed.curation.starRating == 5)
        #expect(reParsed.curation.pickFlag == .picked)
        #expect(reParsed.curation.colorLabel == .yellow)

        // 5. Digest verification
        let digest1 = SidecarCodec.computeDigest(for: updatedData)
        let digest2 = SidecarCodec.computeDigest(for: updatedData)
        #expect(!digest1.isEmpty)
        #expect(digest1 == digest2)
    }

    @Test("Update nil/empty XML generates standard-conformant XMP sidecar with proper namespaces")
    func updateNilDataGeneratesConformantXMP() throws {
        let curation = CurationMetadata(starRating: 4, pickFlag: .rejected, colorLabel: .purple)
        let generatedData = try SidecarCodec.update(xmlData: nil, with: curation)
        let parsed = try SidecarCodec.parse(data: generatedData)

        #expect(parsed.curation.starRating == 4)
        #expect(parsed.curation.pickFlag == .rejected)
        #expect(parsed.curation.colorLabel == .purple)

        let xmlString = String(decoding: generatedData, as: UTF8.self)
        #expect(xmlString.contains("crs:Pick=\"-1\""))
        #expect(xmlString.contains("xmpDM:pick=\"-1\""))
        #expect(xmlString.contains("xmp:Rating=\"4\""))
        #expect(xmlString.contains("xmp:Label=\"Purple\""))
    }

    @Test("SidecarCodec.write persists curation to <basename>.xmp and updates existing <filename>.<ext>.xmp on disk")
    func sidecarCodecWriteDualConventionDiskPersistence() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let rawURL = root.appendingPathComponent("DSC0800.ARW")
        let jpgURL = root.appendingPathComponent("DSC0800.JPG")
        try Data("raw".utf8).write(to: rawURL)
        try Data("jpg".utf8).write(to: jpgURL)

        let rawFile = MediaFile(url: rawURL, formatKind: .raw)
        let jpgFile = MediaFile(url: jpgURL, formatKind: .raster)
        let pair = MediaPair(rawFile: rawFile, rasterFile: jpgFile)
        let pairItem = MediaItem(
            id: "\(root.path)#DSC0800",
            baseName: "DSC0800",
            directoryURL: root,
            relativeDirectoryPath: "",
            kind: .photo,
            primaryFile: jpgFile,
            mediaPair: pair,
            sidecarURL: nil
        )

        let rawExtXmp = root.appendingPathComponent("DSC0800.ARW.xmp")
        let externalCaptureOneXML = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about=""
            xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
            xmlns:xmp="http://ns.adobe.com/xap/1.0/"
            crs:Exposure2012="+2.00"
            crs:Pick="0"
            xmp:Rating="1"/>
         </rdf:RDF>
        </x:xmpmeta>
        """
        try Data(externalCaptureOneXML.utf8).write(to: rawExtXmp)

        let newCuration = CurationMetadata(starRating: 5, pickFlag: .picked, colorLabel: .green)
        let writtenURLs = try await SidecarCodec.write(curation: newCuration, for: pairItem)

        let basenameXmp = root.appendingPathComponent("DSC0800.xmp")
        #expect(writtenURLs.contains { $0.standardizedFileURL.path == basenameXmp.standardizedFileURL.path })
        #expect(writtenURLs.contains { $0.standardizedFileURL.path == rawExtXmp.standardizedFileURL.path })

        // Check basename XMP was created
        let baseParsed = try SidecarCodec.parse(data: Data(contentsOf: basenameXmp))
        #expect(baseParsed.curation == newCuration)

        // Check existing extension XMP was updated without losing develop settings
        let extData = try Data(contentsOf: rawExtXmp)
        let extString = String(decoding: extData, as: UTF8.self)
        #expect(extString.contains("crs:Exposure2012=\"+2.00\""))
        #expect(extString.contains("crs:Pick=\"1\""))
        #expect(extString.contains("xmp:Rating=\"5\""))
        let extParsed = try SidecarCodec.parse(data: extData)
        #expect(extParsed.curation == newCuration)
    }

    @Test("SidecarCodec.update preserves <?xpacket?> wrapper when present in source data")
    func updatePreservesXPacketWrapper() throws {
        let originalXML = """
        <?xpacket begin="﻿" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about="" xmlns:xmp="http://ns.adobe.com/xap/1.0/" xmp:Rating="1"/>
         </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """
        let updatedData = try SidecarCodec.update(
            xmlData: Data(originalXML.utf8),
            with: CurationMetadata(starRating: 4, pickFlag: .picked, colorLabel: .none)
        )
        let updatedString = String(decoding: updatedData, as: UTF8.self)
        #expect(updatedString.contains("<?xpacket begin"))
        #expect(updatedString.contains("<?xpacket end"))
    }

    @Test("SidecarCodec.update throws an error on corrupt XML without overwriting")
    func updateThrowsOnCorruptXML() {
        let corruptData = Data("<<<not valid xml>>>".utf8)
        #expect(throws: (any Error).self) {
            try SidecarCodec.update(xmlData: corruptData, with: CurationMetadata(starRating: 3))
        }
    }

    @Test("SidecarCodec.write supports direct sequential overwrites on existing sidecar without auxiliary file collision")
    func sidecarCodecWriteDirectSequentialOverwritesWithoutAuxiliaryCollision() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let jpgURL = root.appendingPathComponent("TEST001.JPG")
        try Data("jpg-content".utf8).write(to: jpgURL)

        let jpgFile = MediaFile(url: jpgURL, formatKind: .raster)
        let item = MediaItem(
            id: "\(root.path)#TEST001",
            baseName: "TEST001",
            directoryURL: root,
            relativeDirectoryPath: "",
            kind: .photo,
            primaryFile: jpgFile,
            mediaPair: nil,
            sidecarURL: nil
        )

        let xmpURL = root.appendingPathComponent("TEST001.xmp")

        // First write: creates TEST001.xmp
        let curation1 = CurationMetadata(starRating: 1, pickFlag: .unflagged, colorLabel: .none)
        let written1 = try await SidecarCodec.write(curation: curation1, for: item)
        #expect(written1.map(\.standardizedFileURL.path).contains(xmpURL.standardizedFileURL.path))

        let parsed1 = try SidecarCodec.parse(data: try Data(contentsOf: xmpURL))
        #expect(parsed1.curation == curation1)

        // Second write (direct sequential overwrite on existing file)
        let curation2 = CurationMetadata(starRating: 5, pickFlag: .picked, colorLabel: .red)
        let written2 = try await SidecarCodec.write(curation: curation2, for: item)
        #expect(written2.map(\.standardizedFileURL.path).contains(xmpURL.standardizedFileURL.path))

        let parsed2 = try SidecarCodec.parse(data: try Data(contentsOf: xmpURL))
        #expect(parsed2.curation == curation2)

        // Third write (another immediate overwrite)
        let curation3 = CurationMetadata(starRating: 3, pickFlag: .rejected, colorLabel: .blue)
        let written3 = try await SidecarCodec.write(curation: curation3, for: item)
        #expect(written3.map(\.standardizedFileURL.path).contains(xmpURL.standardizedFileURL.path))

        let parsed3 = try SidecarCodec.parse(data: try Data(contentsOf: xmpURL))
        #expect(parsed3.curation == curation3)
    }

    @Test("SidecarCodec classifies ESTALE (errno 70) correctly across direct and underlying error containers")
    func classifiesESTALECorrectly() {
        // Direct POSIX 70 error
        let directStale = NSError(domain: NSPOSIXErrorDomain, code: 70)
        #expect(SidecarCodec.isStaleFileHandleError(directStale))

        // CocoaError 512 wrapping POSIX 70 in NSUnderlyingErrorKey
        let wrappedStale = NSError(
            domain: NSCocoaErrorDomain,
            code: 512,
            userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: 70)]
        )
        #expect(SidecarCodec.isStaleFileHandleError(wrappedStale))

        // Non-stale POSIX error (e.g. ENOENT = 2 or EACCES = 13)
        let otherPOSIX = NSError(domain: NSPOSIXErrorDomain, code: 2)
        #expect(!SidecarCodec.isStaleFileHandleError(otherPOSIX))

        // Generic error without underlying error
        let genericError = NSError(domain: NSCocoaErrorDomain, code: 512)
        #expect(!SidecarCodec.isStaleFileHandleError(genericError))
    }

    @Test("SidecarCodec POSIX helpers write and read data cleanly")
    func posixHelpersWriteAndReadCleanly() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let testFile = root.appendingPathComponent("posix_test.xmp")
        let sampleData = "Sample POSIX XMP Content".data(using: .utf8)!

        // Write via POSIX
        let writeErr = SidecarCodec.writeViaPOSIX(data: sampleData, to: testFile.path)
        #expect(writeErr == nil)

        // Read via SidecarCodec.readData
        let readBack = SidecarCodec.readData(from: testFile)
        #expect(readBack == sampleData)

        // Overwrite via POSIX
        let updatedData = "Updated POSIX XMP Content".data(using: .utf8)!
        let overwriteErr = SidecarCodec.writeViaPOSIX(data: updatedData, to: testFile.path)
        #expect(overwriteErr == nil)

        let readBackUpdated = SidecarCodec.readData(from: testFile)
        #expect(readBackUpdated == updatedData)

        // Read non-existent file returns nil
        let nonExistent = root.appendingPathComponent("does_not_exist.xmp")
        #expect(SidecarCodec.readData(from: nonExistent) == nil)
    }

    @Test("SidecarCodec.resolveSidecarWriteURLs always targets standard lowercase <basename>.xmp")
    func resolveSidecarWriteURLsAlwaysTargetsStandardLowercaseXMP() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let jpgURL = root.appendingPathComponent("PHOTO01.JPG")
        try Data("jpg-content".utf8).write(to: jpgURL)

        // Even if an uppercase sidecar exists on disk, writes must strictly use standard lowercase .xmp
        let upperXMP = root.appendingPathComponent("PHOTO01.XMP")
        try Data("xmp-content".utf8).write(to: upperXMP)

        let item = MediaItem(
            id: "\(root.path)#PHOTO01",
            baseName: "PHOTO01",
            directoryURL: root,
            relativeDirectoryPath: "",
            kind: .photo,
            primaryFile: MediaFile(url: jpgURL, formatKind: .raster),
            mediaPair: nil,
            sidecarURL: upperXMP
        )

        let targets = SidecarCodec.resolveSidecarWriteURLs(for: item)
        #expect(targets.first?.lastPathComponent == "PHOTO01.xmp")
        #expect(!targets.contains(where: { $0.lastPathComponent == "PHOTO01.XMP" }))
    }

    @Test("SidecarCodec.userFacingErrorMessage returns actionable Files app reconnection guidance on ESTALE")
    func userFacingErrorMessageReturnsActionableGuidanceOnESTALE() {
        // Direct POSIX 70
        let directStale = NSError(domain: NSPOSIXErrorDomain, code: 70)
        let directMsg = SidecarCodec.userFacingErrorMessage(for: directStale, fallback: "Generic fallback")
        #expect(directMsg.contains("Files app"))
        #expect(directMsg.contains("reconnect the server"))

        // CocoaError 512 with underlying POSIX 70
        let wrappedStale = NSError(
            domain: NSCocoaErrorDomain,
            code: 512,
            userInfo: [NSUnderlyingErrorKey: directStale]
        )
        let wrappedMsg = SidecarCodec.userFacingErrorMessage(for: wrappedStale, fallback: "Generic fallback")
        #expect(wrappedMsg.contains("Files app"))
        #expect(wrappedMsg.contains("reconnect the server"))

        // Unrelated error returns fallback
        let otherError = NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileWriteNoPermission.rawValue)
        let fallbackMsg = SidecarCodec.userFacingErrorMessage(for: otherError, fallback: "Permission denied")
        #expect(fallbackMsg == "Permission denied")
    }
}
