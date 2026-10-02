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

    @Test("SidecarCodec.readData reads data cleanly")
    func readDataReadsCleanly() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let testFile = root.appendingPathComponent("read_test.xmp")
        let sampleData = "Sample XMP Content".data(using: .utf8)!

        try sampleData.write(to: testFile)

        // Read via SidecarCodec.readData
        let readBack = SidecarCodec.readData(from: testFile)
        #expect(readBack == sampleData)

        // Overwrite
        let updatedData = "Updated XMP Content".data(using: .utf8)!
        try updatedData.write(to: testFile)

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

    // MARK: - Synthetic Torture Matrix (Capture One & ExifTool Fixtures)

    @Test("Torture Matrix 1: Capture One real-world fixture (DSC04639.xmp) round-trip mutation, style preservation, and tag clearing")
    func tortureMatrixCaptureOneRealWorldFixtureRoundTrip() throws {
        // Authentic Capture One sidecar based on testfiles/xmps/DSC04639.xmp & P9086852.xmp
        let fixtureXML = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="XMP Core 5.5.0">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about=""
            xmlns:xmp="http://ns.adobe.com/xap/1.0/"
            xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/"
            xmlns:dc="http://purl.org/dc/elements/1.1/">
           <xmp:Rating>0</xmp:Rating>
           <xmp:Label>Green</xmp:Label>
           <xmp:CreatorTool>ILCE-7RM3 v3.10</xmp:CreatorTool>
           <photoshop:Urgency>2</photoshop:Urgency>
           <dc:description>
            <rdf:Alt>
             <rdf:li xml:lang="x-default">                               </rdf:li>
            </rdf:Alt>
           </dc:description>
          </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>
        """
        let originalData = Data(fixtureXML.utf8)

        // 1. Initial parse
        let initialParsed = try SidecarCodec.parse(data: originalData)
        #expect(initialParsed.curation.starRating == 0)
        #expect(initialParsed.curation.pickFlag == .unflagged)
        #expect(initialParsed.curation.colorLabel == .green)

        // 2. Mutate curation: Rating 5, PickFlag .picked, ColorLabel .blue (Urgency 4)
        let mutatedCuration = CurationMetadata(starRating: 5, pickFlag: .picked, colorLabel: .blue)
        let mutatedData = try SidecarCodec.update(xmlData: originalData, with: mutatedCuration)
        let mutatedXML = String(decoding: mutatedData, as: UTF8.self)

        // Verify preservation of element-based style for Capture One
        #expect(mutatedXML.contains("<xmp:Rating>5</xmp:Rating>"))
        #expect(mutatedXML.contains("<xmp:Label>Blue</xmp:Label>"))
        #expect(mutatedXML.contains("<photoshop:Urgency>4</photoshop:Urgency>"))
        #expect(mutatedXML.contains("<crs:Pick>1</crs:Pick>"))
        #expect(mutatedXML.contains("<xmpDM:pick>1</xmpDM:pick>"))

        // Verify preservation of non-curation nodes and whitespace within child elements
        #expect(mutatedXML.contains("<xmp:CreatorTool>ILCE-7RM3 v3.10</xmp:CreatorTool>"))
        #expect(mutatedXML.contains("<dc:description>"))
        #expect(mutatedXML.contains("<rdf:li xml:lang=\"x-default\">                               </rdf:li>"))

        // Verify re-parsing matches mutated curation
        let reparsedMutated = try SidecarCodec.parse(data: mutatedData)
        #expect(reparsedMutated.curation == mutatedCuration)

        // 3. Clear curation: Rating 0, PickFlag .unflagged, ColorLabel .none
        let clearedCuration = CurationMetadata(starRating: 0, pickFlag: .unflagged, colorLabel: .none)
        let clearedData = try SidecarCodec.update(xmlData: mutatedData, with: clearedCuration)
        let clearedXML = String(decoding: clearedData, as: UTF8.self)

        #expect(clearedXML.contains("<xmp:Rating>0</xmp:Rating>"))
        #expect(!clearedXML.contains("xmp:Label"))
        #expect(!clearedXML.contains("photoshop:Urgency"))
        #expect(clearedXML.contains("<xmp:CreatorTool>ILCE-7RM3 v3.10</xmp:CreatorTool>"))
        #expect(clearedXML.contains("<dc:description>"))

        let reparsedCleared = try SidecarCodec.parse(data: clearedData)
        #expect(reparsedCleared.curation == clearedCuration)
    }

    @Test("Torture Matrix 2: Capture One urgency fallback across all values and foreign labels")
    func tortureMatrixCaptureOneUrgencyFallback() throws {
        // Urgency 1 = Red, 2 = Green, 3 = Yellow, 4 = Blue, 5 = Orange, 6 = Purple
        let cases: [(Int, ColorLabel)] = [
            (1, .red),
            (2, .green),
            (3, .yellow),
            (4, .blue),
            (5, .orange),
            (6, .purple)
        ]

        for (urgency, expectedLabel) in cases {
            // Case A: Missing xmp:Label entirely (e.g. Capture One localized or custom tag setup)
            let xmlMissingLabel = """
            <x:xmpmeta xmlns:x="adobe:ns:meta/">
             <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
              <rdf:Description rdf:about=""
                xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/">
               <photoshop:Urgency>\(urgency)</photoshop:Urgency>
              </rdf:Description>
             </rdf:RDF>
            </x:xmpmeta>
            """
            let parsedA = try SidecarCodec.parse(data: Data(xmlMissingLabel.utf8))
            #expect(parsedA.curation.colorLabel == expectedLabel)

            // Case B: Non-English or unrecognized xmp:Label (e.g. German "Grün", French "Vert")
            let xmlForeignLabel = """
            <x:xmpmeta xmlns:x="adobe:ns:meta/">
             <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
              <rdf:Description rdf:about=""
                xmlns:xmp="http://ns.adobe.com/xap/1.0/"
                xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/">
               <xmp:Label>Farbetikett_\(urgency)</xmp:Label>
               <photoshop:Urgency>\(urgency)</photoshop:Urgency>
              </rdf:Description>
             </rdf:RDF>
            </x:xmpmeta>
            """
            let parsedB = try SidecarCodec.parse(data: Data(xmlForeignLabel.utf8))
            #expect(parsedB.curation.colorLabel == expectedLabel)
        }
    }

    @Test("Torture Matrix 3: ExifTool multi-description partitioning and namespace routing")
    func tortureMatrixExifToolMultiDescriptionPartitioning() throws {
        // Directly replicates ExifTool's output partitioning across multiple rdf:Description elements
        let exiftoolXML = """
        <x:xmpmeta xmlns:x='adobe:ns:meta/' x:xmptk='Image::ExifTool 13.55'>
        <rdf:RDF xmlns:rdf='http://www.w3.org/1999/02/22-rdf-syntax-ns#'>

         <rdf:Description rdf:about=''
          xmlns:dc='http://purl.org/dc/elements/1.1/'>
          <dc:description>
           <rdf:Alt>
            <rdf:li xml:lang='x-default'>OLYMPUS DIGITAL CAMERA         </rdf:li>
           </rdf:Alt>
          </dc:description>
         </rdf:Description>

         <rdf:Description rdf:about=''
          xmlns:photoshop='http://ns.adobe.com/photoshop/1.0/'>
          <photoshop:Urgency>1</photoshop:Urgency>
         </rdf:Description>

         <rdf:Description rdf:about=''
          xmlns:xmp='http://ns.adobe.com/xap/1.0/'>
          <xmp:CreatorTool>Version 3.7                    </xmp:CreatorTool>
          <xmp:Label>Red</xmp:Label>
          <xmp:Rating>5</xmp:Rating>
         </rdf:Description>
        </rdf:RDF>
        </x:xmpmeta>
        """
        let originalData = Data(exiftoolXML.utf8)

        // 1. Verify reading across separate description blocks
        let initialParsed = try SidecarCodec.parse(data: originalData)
        #expect(initialParsed.curation.starRating == 5)
        #expect(initialParsed.curation.colorLabel == .red)
        #expect(initialParsed.curation.pickFlag == .unflagged)

        // 2. Mutate curation: Rating 2, ColorLabel .green (Urgency 2), PickFlag .picked
        let newCuration = CurationMetadata(starRating: 2, pickFlag: .picked, colorLabel: .green)
        let updatedData = try SidecarCodec.update(xmlData: originalData, with: newCuration)
        let updatedXML = String(decoding: updatedData, as: UTF8.self)

        // Verify namespace routing:
        // photoshop:Urgency should be updated inside the photoshop description block
        #expect(updatedXML.contains("<photoshop:Urgency>2</photoshop:Urgency>"))
        // xmp:Rating and xmp:Label should be updated inside the xmp description block
        #expect(updatedXML.contains("<xmp:Rating>2</xmp:Rating>"))
        #expect(updatedXML.contains("<xmp:Label>Green</xmp:Label>"))
        // dc:description should remain completely intact in its own block
        #expect(updatedXML.contains("<dc:description>"))
        #expect(updatedXML.contains("<rdf:li xml:lang=\"x-default\">OLYMPUS DIGITAL CAMERA         </rdf:li>"))

        // Verify re-parsing
        let reparsed = try SidecarCodec.parse(data: updatedData)
        #expect(reparsed.curation == newCuration)
    }

    @Test("Torture Matrix 4: Duplicate and conflicting property pruning across description blocks")
    func tortureMatrixDuplicateAndConflictingPropertyPruning() throws {
        // Document with intentional conflicting duplicate tags across blocks
        let conflictingXML = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about=""
            xmlns:xmp="http://ns.adobe.com/xap/1.0/"
            xmp:Rating="1">
           <xmp:Label>Red</xmp:Label>
          </rdf:Description>
          <rdf:Description rdf:about=""
            xmlns:xmp="http://ns.adobe.com/xap/1.0/"
            xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/">
           <xmp:Rating>3</xmp:Rating>
           <photoshop:Urgency>1</photoshop:Urgency>
          </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>
        """
        let data = Data(conflictingXML.utf8)

        // Mutate to clean state: Rating 4, Label Blue (Urgency 4), PickFlag unflagged
        let targetCuration = CurationMetadata(starRating: 4, pickFlag: .unflagged, colorLabel: .blue)
        let cleanedData = try SidecarCodec.update(xmlData: data, with: targetCuration)
        let cleanedXML = String(decoding: cleanedData, as: UTF8.self)

        // Ensure there is only ONE Rating in the output and it is 4
        #expect(cleanedXML.contains("Rating>4</") || cleanedXML.contains("Rating=\"4\""))
        #expect(!cleanedXML.contains("Rating>1</") && !cleanedXML.contains("Rating=\"1\""))
        #expect(!cleanedXML.contains("Rating>3</") && !cleanedXML.contains("Rating=\"3\""))

        // Ensure there is only ONE Urgency in the output and it is 4
        #expect(cleanedXML.contains("Urgency>4</") || cleanedXML.contains("Urgency=\"4\""))
        #expect(!cleanedXML.contains("Urgency>1</") && !cleanedXML.contains("Urgency=\"1\""))

        let parsed = try SidecarCodec.parse(data: cleanedData)
        #expect(parsed.curation == targetCuration)
    }

    @Test("Torture Matrix 5: Lossless preservation of XML declarations, comments, CDATA, and packet wrappers")
    func tortureMatrixLosslessPreservationOfComplexXML() throws {
        let complexXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <?xpacket begin="﻿" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <!-- Global Top Comment -->
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="XMP Core 6.0.0">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <!-- Description Level Comment -->
          <rdf:Description rdf:about=""
            xmlns:xmp="http://ns.adobe.com/xap/1.0/"
            xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/"
            xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
            xmp:Rating="2">
           <!-- Child Level Comment -->
           <photoshop:Headline><![CDATA[Sunset & <Sunrise> "Special" Characters]]></photoshop:Headline>
           <crs:RawFileName>DSC04639.ARW</crs:RawFileName>
          </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """
        let data = Data(complexXML.utf8)

        let targetCuration = CurationMetadata(starRating: 5, pickFlag: .picked, colorLabel: .yellow)
        let updatedData = try SidecarCodec.update(xmlData: data, with: targetCuration)
        let updatedXML = String(decoding: updatedData, as: UTF8.self)

        // Verify XML declaration preserved
        #expect(updatedXML.contains("<?xml version=\"1.0\" encoding=\"UTF-8\"?>"))

        // Verify xpacket header and trailer preserved
        #expect(updatedXML.contains("<?xpacket begin="))
        #expect(updatedXML.contains("<?xpacket end=\"w\"?>"))

        // Verify comments preserved
        #expect(updatedXML.contains("<!-- Global Top Comment -->") || updatedXML.contains("Global Top Comment"))
        #expect(updatedXML.contains("<!-- Description Level Comment -->") || updatedXML.contains("Description Level Comment"))
        #expect(updatedXML.contains("<!-- Child Level Comment -->") || updatedXML.contains("Child Level Comment"))

        // Verify CDATA block preserved byte-for-byte
        #expect(updatedXML.contains("<![CDATA[Sunset & <Sunrise> \"Special\" Characters]]>"))

        // Verify untouched metadata nodes
        #expect(updatedXML.contains("<crs:RawFileName>DSC04639.ARW</crs:RawFileName>"))

        // Verify curation updated
        let reparsed = try SidecarCodec.parse(data: updatedData)
        #expect(reparsed.curation == targetCuration)
    }

    @Test("Torture Matrix 6: Repeated round-trip invariance (zero tag accumulation and zero whitespace drift)")
    func tortureMatrixRepeatedRoundTripInvariance() throws {
        let fixtureXML = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="XMP Core 5.5.0">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about=""
            xmlns:xmp="http://ns.adobe.com/xap/1.0/"
            xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/">
           <xmp:Rating>3</xmp:Rating>
           <xmp:Label>Green</xmp:Label>
           <photoshop:Urgency>2</photoshop:Urgency>
          </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>
        """
        let originalData = Data(fixtureXML.utf8)
        let curation = CurationMetadata(starRating: 4, pickFlag: .picked, colorLabel: .red)

        // Run 3 consecutive update passes
        let pass1Data = try SidecarCodec.update(xmlData: originalData, with: curation)
        let pass2Data = try SidecarCodec.update(xmlData: pass1Data, with: curation)
        let pass3Data = try SidecarCodec.update(xmlData: pass2Data, with: curation)

        let str1 = String(decoding: pass1Data, as: UTF8.self)
        let str2 = String(decoding: pass2Data, as: UTF8.self)
        let str3 = String(decoding: pass3Data, as: UTF8.self)

        #expect(str1 == str2)
        #expect(str2 == str3)
    }

    @Test("Torture Matrix 7: ApolloOne / Adobe large sidecar with trailing whitespace padding (C0149.xmp fixture)")
    func tortureMatrixLargeSidecarWithWhitespacePadding() throws {
        let padding = String(repeating: "                                                                                                    \n", count: 20)
        let apolloXML = """
        <?xpacket begin="﻿" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="XMP Core 6.0.0">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about=""
            xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/"
            xmlns:xmp="http://ns.adobe.com/xap/1.0/"
            photoshop:DateCreated="(null)(null)"
            photoshop:SidecarForExtension="MP4"
            xmp:MetadataDate="2026-09-23T23:10:55+09:00"
            xmp:CreatorTool="ApolloOne 4.9.1"
            xmp:Label=""
            xmp:Rating="2"/>
         </rdf:RDF>
        </x:xmpmeta>
        \(padding)<?xpacket end="w"?>
        """
        let data = Data(apolloXML.utf8)

        // Initial parse
        let initial = try SidecarCodec.parse(data: data)
        #expect(initial.curation.starRating == 2)
        #expect(initial.curation.colorLabel == .none)

        // Mutate: Rating 5, PickFlag .picked, ColorLabel .red
        let targetCuration = CurationMetadata(starRating: 5, pickFlag: .picked, colorLabel: .red)
        let updatedData = try SidecarCodec.update(xmlData: data, with: targetCuration)
        let updatedXML = String(decoding: updatedData, as: UTF8.self)

        #expect(updatedXML.contains("xmp:Rating=\"5\""))
        #expect(updatedXML.contains("photoshop:SidecarForExtension=\"MP4\""))
        #expect(updatedXML.contains("<?xpacket begin="))
        #expect(updatedXML.contains("<?xpacket end=\"w\"?>"))

        let reparsed = try SidecarCodec.parse(data: updatedData)
        #expect(reparsed.curation == targetCuration)
    }
}
