import CryptoKit
import Darwin
import Foundation
import OSLog

nonisolated enum SidecarCodec {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.pickture", category: "sync")

    // MARK: - Sidecar Path Discovery & Targets

    static func resolveSidecarReadURL(for item: MediaItem) -> URL? {
        let fm = FileManager.default
        let dir = item.directoryURL.standardizedFileURL

        // 1. Check <basename>.xmp first (Lightroom / Bridge / default convention)
        let basenameURL = dir.appendingPathComponent("\(item.baseName).xmp").standardizedFileURL
        if fm.fileExists(atPath: basenameURL.path) {
            return basenameURL
        }

        // Also check case-insensitive match for <basename>.xmp in the directory
        if let contents = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            let targetBase = "\(item.baseName).xmp".lowercased()
            if let matched = contents.first(where: { $0.lastPathComponent.lowercased() == targetBase }) {
                return matched.standardizedFileURL
            }
        }

        // 2. Check <filename>.<ext>.xmp (Capture One / Darktable convention)
        let files = associatedFiles(for: item)
        for file in files {
            let extURL = dir.appendingPathComponent("\(file.fileName).xmp").standardizedFileURL
            if fm.fileExists(atPath: extURL.path) {
                return extURL
            }
        }

        if let contents = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            let candidateNames = Set(files.map { "\($0.fileName).xmp".lowercased() })
            if let matched = contents.first(where: { candidateNames.contains($0.lastPathComponent.lowercased()) }) {
                return matched.standardizedFileURL
            }
        }

        return nil
    }

    static func resolveSidecarWriteURLs(for item: MediaItem) -> [URL] {
        let fm = FileManager.default
        let dir = item.directoryURL.standardizedFileURL

        // Always write to <basename>.xmp by default
        let basenameURL = dir.appendingPathComponent("\(item.baseName).xmp").standardizedFileURL
        var targets: [URL] = [basenameURL]

        // 2. Also update any <filename>.<ext>.xmp that already exists on disk
        let files = associatedFiles(for: item)
        for file in files {
            let extURL = dir.appendingPathComponent("\(file.fileName).xmp").standardizedFileURL
            if fm.fileExists(atPath: extURL.path) {
                if !targets.contains(where: { $0.standardizedFileURL.path == extURL.standardizedFileURL.path }) {
                    targets.append(extURL)
                }
            }
        }

        return targets
    }

    private static func associatedFiles(for item: MediaItem) -> [MediaFile] {
        var files: [MediaFile] = []
        if let pair = item.mediaPair {
            files.append(pair.rawFile)
            files.append(pair.rasterFile)
        }
        if !files.contains(where: { $0.id == item.primaryFile.id }) {
            files.append(item.primaryFile)
        }
        return files
    }

    // MARK: - Safe POSIX I/O & Invalidation Helpers

    static func readData(from url: URL) -> Data? {
        if let data = try? Data(contentsOf: url) {
            return data
        }
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var statBuf = stat()
        guard fstat(fd, &statBuf) == 0 else { return nil }
        let size = Int(statBuf.st_size)
        guard size > 0 else { return Data() }
        var data = Data(count: size)
        let readSuccess = data.withUnsafeMutableBytes { rawBuffer -> Bool in
            guard let base = rawBuffer.baseAddress else { return false }
            var totalRead = 0
            while totalRead < size {
                let r = Darwin.read(fd, base.advanced(by: totalRead), size - totalRead)
                if r <= 0 { return false }
                totalRead += r
            }
            return true
        }
        return readSuccess ? data : nil
    }

    @discardableResult
    static func writeViaPOSIX(data: Data, to path: String, flags: Int32 = O_WRONLY | O_CREAT | O_TRUNC, mode: mode_t = 0o666) -> Error? {
        let fd = open(path, flags, mode)
        if fd < 0 {
            let err = errno
            return NSError(domain: NSPOSIXErrorDomain, code: Int(err), userInfo: [
                NSLocalizedDescriptionKey: String(cString: strerror(err)),
                NSFilePathErrorKey: path
            ])
        }
        defer { close(fd) }

        var remaining = data.count
        var offset = 0
        let writeError: Int32 = data.withUnsafeBytes { rawBuffer -> Int32 in
            guard let base = rawBuffer.baseAddress else { return 0 }
            while remaining > 0 {
                let written = Darwin.write(fd, base.advanced(by: offset), remaining)
                if written < 0 {
                    return errno
                }
                remaining -= written
                offset += written
            }
            return 0
        }

        if writeError != 0 {
            return NSError(domain: NSPOSIXErrorDomain, code: Int(writeError), userInfo: [
                NSLocalizedDescriptionKey: String(cString: strerror(writeError)),
                NSFilePathErrorKey: path
            ])
        }

        return nil
    }

    // MARK: - XMP Parsing

    static func parse(data: Data) throws -> (curation: CurationMetadata, exif: ExifMetadata) {
        let tree = try XMPTreeParser.parse(data: data)
        return (curation: tree.extractCurationMetadata(), exif: tree.extractExifMetadata())
    }

    // MARK: - XMP Round-Trip Serialization & Disk Persistence

    @discardableResult
    static func write(curation: CurationMetadata, for item: MediaItem) async throws -> [URL] {
        let targets = resolveSidecarWriteURLs(for: item)
        let fm = FileManager.default
        var actualWritten: [URL] = []
        for url in targets {
            let existingData = readData(from: url)
            let updatedData = try update(xmlData: existingData, with: curation)
            let dir = url.deletingLastPathComponent()
            if !fm.fileExists(atPath: dir.path) {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            let writtenURL = try await writeCoordinatedWithRetry(data: updatedData, to: url)
            actualWritten.append(writtenURL)
        }
        return actualWritten
    }

    @discardableResult
    static func writeCoordinatedWithRetry(data: Data, to url: URL) async throws -> URL {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        let fm = FileManager.default

        struct AttemptResult {
            var coordError: NSError?
            var writeError: Error?
            var accessorRan: Bool = false
            var targetURL: URL?

            var error: Error? {
                coordError ?? writeError
            }
        }

        func attemptWrite(useReplacing: Bool) -> AttemptResult {
            var result = AttemptResult()
            let options: NSFileCoordinator.WritingOptions = useReplacing ? .forReplacing : []
            coordinator.coordinate(writingItemAt: url, options: options, error: &result.coordError) { targetURL in
                result.accessorRan = true
                result.targetURL = targetURL
                do {
                    try data.write(to: targetURL, options: [])
                } catch {
                    // Foundation's data.write fails on stat() before even attempting open().
                    // Direct POSIX open(O_CREAT) does not stat() first and may bypass the stale handle.
                    if isStaleOrMissingFileError(error) {
                        if let posixErr = writeViaPOSIX(data: data, to: targetURL.path) {
                            result.writeError = posixErr
                        } else {
                            result.writeError = nil
                        }
                    } else {
                        result.writeError = error
                    }
                }
            }
            return result
        }

        let initialExists = fm.fileExists(atPath: url.path)
        var lastAttempt = attemptWrite(useReplacing: !initialExists)

        if lastAttempt.error == nil {
            return url
        }

        let error = lastAttempt.error!
        var statBuf = stat()
        let statRes = stat(url.path, &statBuf)
        let statErr = errno
        let folderURL = url.deletingLastPathComponent()
        let folderExists = fm.fileExists(atPath: folderURL.path)

        logger.debug("""
        Initial write failed for \(url.lastPathComponent, privacy: .public): \
        coordError=\(String(describing: lastAttempt.coordError), privacy: .public) \
        accessorRan=\(lastAttempt.accessorRan) \
        targetURL=\(lastAttempt.targetURL?.path ?? "nil", privacy: .public) \
        writeError=\(String(describing: lastAttempt.writeError), privacy: .public) \
        fm.fileExists=\(initialExists) statRes=\(statRes) (errno \(statErr): \(String(cString: strerror(statErr)), privacy: .public)) \
        folderExists=\(folderExists)
        """)

        if isStaleOrMissingFileError(error) {
            // Progressive backoff with .forReplacing
            let retryDelays: [UInt64] = [50_000_000, 150_000_000]
            for (idx, delay) in retryDelays.enumerated() {
                try await Task.sleep(nanoseconds: delay)
                let retryAttempt = attemptWrite(useReplacing: true)
                if retryAttempt.error == nil {
                    logger.info("SidecarCodec.write succeeded on backoff retry #\(idx + 1) for \(url.lastPathComponent, privacy: .public)")
                    return url
                }
                lastAttempt = retryAttempt
            }

            logger.debug("Backoff retries exhausted for \(url.lastPathComponent, privacy: .public). Probing recovery fallbacks:")

            // Probe 1: Parent directory cache invalidation via readdir + fsync
            let folderPath = folderURL.path
            if let dir = opendir(folderPath) {
                while readdir(dir) != nil {}
                closedir(dir)
            }
            let dirFd = open(folderPath, O_RDONLY)
            if dirFd >= 0 {
                fsync(dirFd)
                close(dirFd)
            }
            if writeViaPOSIX(data: data, to: url.path) == nil {
                logger.info("Recovery via directory fsync + POSIX write succeeded for \(url.lastPathComponent, privacy: .public)")
                return url
            }

            // Probe 2: POSIX open with O_CREAT | O_EXCL
            if writeViaPOSIX(data: data, to: url.path, flags: O_WRONLY | O_CREAT | O_EXCL) == nil {
                logger.info("Recovery via POSIX O_EXCL succeeded for \(url.lastPathComponent, privacy: .public)")
                return url
            }

            // Probe 3: Explicit POSIX unlink to evict stale kernel/smbclientd inode cache
            let unlinkRes = unlink(url.path)
            let unlinkErr = errno
            logger.debug("Probe 3 (POSIX unlink): res=\(unlinkRes), errno=\(unlinkErr)")
            if writeViaPOSIX(data: data, to: url.path) == nil {
                logger.info("Recovery via POSIX unlink + POSIX write succeeded for \(url.lastPathComponent, privacy: .public)")
                return url
            }

            // Probe 4: Write to fresh temporary file in same folder and atomic rename
            let tempName = ".\(url.deletingPathExtension().lastPathComponent).tmp-\(UUID().uuidString.prefix(8)).xmp"
            let tempURL = folderURL.appendingPathComponent(tempName)
            var tempWriteSucceeded = false
            do {
                logger.debug("Probe 4: Attempting write to temp file: \(tempName, privacy: .public)")
                try data.write(to: tempURL, options: [])
                tempWriteSucceeded = true
                logger.debug("Probe 4: Temp write succeeded. Renaming to target...")
                let renameRes = rename(tempURL.path, url.path)
                if renameRes == 0 {
                    logger.info("Recovery via temp file + rename succeeded for \(url.lastPathComponent, privacy: .public)")
                    return url
                } else {
                    let renameErr = errno
                    logger.debug("Probe 4: rename failed with errno=\(renameErr)")
                    do {
                        _ = try fm.replaceItemAt(url, withItemAt: tempURL, backupItemName: nil, options: [])
                        logger.info("Recovery via fm.replaceItemAt succeeded for \(url.lastPathComponent, privacy: .public)")
                        return url
                    } catch {
                        logger.debug("Probe 4: fm.replaceItemAt also failed: \(error.localizedDescription, privacy: .public)")
                    }
                }
            } catch {
                logger.debug("Probe 4: Temp write failed: \(error.localizedDescription, privacy: .public)")
            }
            if tempWriteSucceeded && fm.fileExists(atPath: tempURL.path) {
                try? fm.removeItem(at: tempURL)
            }

            let finalError = lastAttempt.error ?? error
            let nsError = finalError as NSError
            let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
            logger.error("SidecarCodec.write all retries and fallbacks failed for \(url.lastPathComponent, privacy: .public): domain=\(nsError.domain, privacy: .public) code=\(nsError.code) underlying=\(underlying?.domain ?? "none", privacy: .public)(\(underlying?.code ?? -1))")
            throw finalError
        } else {
            let nsError = error as NSError
            let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
            logger.error("SidecarCodec.write direct failed for \(url.lastPathComponent, privacy: .public): domain=\(nsError.domain, privacy: .public) code=\(nsError.code) underlying=\(underlying?.domain ?? "none", privacy: .public)(\(underlying?.code ?? -1))")
            throw error
        }
    }

    static func hasPOSIXErrorCode(_ error: Error, code: Int) -> Bool {
        var current: NSError? = error as NSError
        while let err = current {
            if err.domain == NSPOSIXErrorDomain && err.code == code {
                return true
            }
            current = err.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }

    static func isStaleFileHandleError(_ error: Error) -> Bool {
        hasPOSIXErrorCode(error, code: Int(POSIXError.Code.ESTALE.rawValue))
    }

    static func userFacingErrorMessage(for error: Error, fallback: String) -> String {
        if isStaleFileHandleError(error) {
            return "Network share has stale file handles from external file deletion. Disconnect and reconnect the server in the Files app to restore write access."
        }
        return fallback
    }

    static func isStaleOrMissingFileError(_ error: Error) -> Bool {
        if isStaleFileHandleError(error) {
            return true
        }
        if hasPOSIXErrorCode(error, code: Int(POSIXError.Code.ENOENT.rawValue)) {
            return true
        }
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain && nsError.code == CocoaError.fileNoSuchFile.rawValue {
            return true
        }
        return false
    }

    static func update(xmlData: Data?, with curation: CurationMetadata) throws -> Data {
        guard let xmlData, !xmlData.isEmpty else {
            return generateDefaultXMPData(with: curation)
        }

        let tree = try XMPTreeParser.parse(data: xmlData)
        guard let desc = tree.findDescriptionNode() else {
            throw CocoaError(.fileReadCorruptFile)
        }

        // Apply curation changes directly to the description node
        desc.apply(curation: curation)

        var serializedXML = tree.serialize()

        // Preserve <?xpacket ... ?> header/footer wrapper if present in source data
        let sourceString = String(decoding: xmlData, as: UTF8.self)
        if sourceString.contains("<?xpacket begin") {
            let xpacketHeader: String
            if let startRange = sourceString.range(of: "<?xpacket begin"),
               let endTagRange = sourceString[startRange.lowerBound...].range(of: "?>") {
                xpacketHeader = String(sourceString[startRange.lowerBound...endTagRange.upperBound]) + "\n"
            } else {
                xpacketHeader = "<?xpacket begin=\"﻿\" id=\"W5M0MpCehiHzreSzNTczkc9d\"?>\n"
            }
            let xpacketTrailer = "<?xpacket end=\"w\"?>\n"
            serializedXML = xpacketHeader + serializedXML + xpacketTrailer
        }

        return Data(serializedXML.utf8)
    }

    static func computeDigest(for data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func generateDefaultXMPData(with curation: CurationMetadata) -> Data {
        let pickVal = curation.pickFlag.xmpPickValue

        let labelAttr: String
        if curation.colorLabel != .none {
            labelAttr = "\n    xmp:Label=\"\(curation.colorLabel.rawValue.capitalized)\""
        } else {
            labelAttr = ""
        }

        let xml = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Pickture">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about=""
            xmlns:xmp="http://ns.adobe.com/xap/1.0/"
            xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
            xmlns:xmpDM="http://ns.adobe.com/xmp/1.0/DynamicMedia/"
            xmp:Rating="\(curation.starRating.value)"
            crs:Pick="\(pickVal)"
            xmpDM:pick="\(pickVal)"\(labelAttr)>
          </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>
        """
        return Data(xml.utf8)
    }
}


// MARK: - Internal Lightweight XMP Tree & Parser

final class XMPNode {
    var name: String
    var attributes: [String: String]
    var children: [XMPNode]
    var text: String

    init(name: String, attributes: [String: String] = [:], children: [XMPNode] = [], text: String = "") {
        self.name = name
        self.attributes = attributes
        self.children = children
        self.text = text
    }

    func findDescendant(named localOrQualifiedName: String) -> XMPNode? {
        if matches(name: name, target: localOrQualifiedName) {
            return self
        }
        for child in children {
            if let found = child.findDescendant(named: localOrQualifiedName) {
                return found
            }
        }
        return nil
    }

    func attributeValue(for names: [String]) -> String? {
        for (key, value) in attributes {
            for target in names {
                if matches(name: key, target: target) {
                    return value
                }
            }
        }
        return nil
    }

    func childText(for names: [String]) -> String? {
        for child in children {
            for target in names {
                if matches(name: child.name, target: target) {
                    let trimmed = child.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        return trimmed
                    }
                }
            }
        }
        return nil
    }

    func matches(name: String, target: String) -> Bool {
        if name.lowercased() == target.lowercased() {
            return true
        }
        if let colonIndex = name.firstIndex(of: ":") {
            let localPart = String(name[name.index(after: colonIndex)...])
            if localPart.lowercased() == target.lowercased() {
                return true
            }
        }
        if let targetColon = target.firstIndex(of: ":") {
            let targetLocal = String(target[target.index(after: targetColon)...])
            if name.lowercased() == targetLocal.lowercased() {
                return true
            }
        }
        return false
    }

    func setAttribute(name: String, value: String) {
        if let existingKey = attributes.keys.first(where: { matches(name: $0, target: name) }) {
            attributes.removeValue(forKey: existingKey)
        }
        attributes[name] = value
    }

    func removeAttribute(matching targetName: String) {
        let keysToRemove = attributes.keys.filter { matches(name: $0, target: targetName) }
        for key in keysToRemove {
            attributes.removeValue(forKey: key)
        }
    }

    func serialize(indent: Int) -> String {
        let indentStr = String(repeating: " ", count: indent * 2)
        var result = "\(indentStr)<\(name)"

        let sortedKeys = attributes.keys.sorted { k1, k2 in
            let isNs1 = k1.starts(with: "xmlns")
            let isNs2 = k2.starts(with: "xmlns")
            if isNs1 != isNs2 { return isNs1 }
            return k1.localizedStandardCompare(k2) == .orderedAscending
        }
        for key in sortedKeys {
            if let val = attributes[key] {
                result += " \(key)=\"\(Self.escapeXMLAttribute(val))\""
            }
        }

        let hasChildren = !children.isEmpty
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasText = !trimmedText.isEmpty

        if !hasChildren && !hasText {
            result += "/>\n"
        } else if !hasChildren && hasText {
            result += ">\(Self.escapeXMLText(trimmedText))</\(name)>\n"
        } else {
            result += ">\n"
            for child in children {
                result += child.serialize(indent: indent + 1)
            }
            if hasText {
                result += "\(indentStr)  \(Self.escapeXMLText(trimmedText))\n"
            }
            result += "\(indentStr)</\(name)>\n"
        }
        return result
    }

    private static func escapeXMLAttribute(_ str: String) -> String {
        str.replacingOccurrences(of: "&", with: "&amp;")
           .replacingOccurrences(of: "\"", with: "&quot;")
           .replacingOccurrences(of: "<", with: "&lt;")
           .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func escapeXMLText(_ str: String) -> String {
        str.replacingOccurrences(of: "&", with: "&amp;")
           .replacingOccurrences(of: "<", with: "&lt;")
           .replacingOccurrences(of: ">", with: "&gt;")
    }
    func apply(curation: CurationMetadata) {
        if attributes["xmlns:xmp"] == nil {
            attributes["xmlns:xmp"] = "http://ns.adobe.com/xap/1.0/"
        }
        if attributes["xmlns:crs"] == nil {
            attributes["xmlns:crs"] = "http://ns.adobe.com/camera-raw-settings/1.0/"
        }

        let pickVal = curation.pickFlag.xmpPickValue

        // crs:Pick
        let crsPickChild = children.first(where: { matches(name: $0.name, target: "crs:Pick") || matches(name: $0.name, target: "Pick") })
        if let crsPickChild {
            crsPickChild.text = "\(pickVal)"
        } else {
            setAttribute(name: "crs:Pick", value: "\(pickVal)")
        }

        // xmpDM:pick
        let dmPickChild = children.first(where: { matches(name: $0.name, target: "xmpDM:pick") || matches(name: $0.name, target: "pick") })
        if let dmPickChild {
            dmPickChild.text = "\(pickVal)"
        } else {
            setAttribute(name: "xmpDM:pick", value: "\(pickVal)")
            if attributes["xmlns:xmpDM"] == nil {
                attributes["xmlns:xmpDM"] = "http://ns.adobe.com/xmp/1.0/DynamicMedia/"
            }
        }

        // xmp:Rating
        let ratingChild = children.first(where: { matches(name: $0.name, target: "xmp:Rating") || matches(name: $0.name, target: "Rating") })
        if let ratingChild {
            ratingChild.text = "\(curation.starRating.value)"
        } else {
            setAttribute(name: "xmp:Rating", value: "\(curation.starRating.value)")
        }

        // xmp:Label
        let labelChild = children.first(where: { matches(name: $0.name, target: "xmp:Label") || matches(name: $0.name, target: "Label") })
        if curation.colorLabel != .none {
            let labelName = curation.colorLabel.rawValue.capitalized
            if let labelChild {
                labelChild.text = labelName
            } else {
                setAttribute(name: "xmp:Label", value: labelName)
            }
        } else {
            removeAttribute(matching: "xmp:Label")
            children.removeAll(where: { matches(name: $0.name, target: "xmp:Label") || matches(name: $0.name, target: "Label") })
        }
    }
}

final class XMPDocumentTree {
    var root: XMPNode?

    init(root: XMPNode? = nil) {
        self.root = root
    }

    func findDescriptionNode() -> XMPNode? {
        guard let root else { return nil }
        return root.findDescendant(named: "rdf:Description") ?? root.findDescendant(named: "Description")
    }

    func serialize() -> String {
        guard let root else { return "" }
        return root.serialize(indent: 0)
    }



    func extractCurationMetadata() -> CurationMetadata {
        guard let desc = findDescriptionNode() else {
            return CurationMetadata()
        }

        // 1. Raw Pick values
        let pickAttr = desc.attributeValue(for: ["crs:Pick", "Pick"])
        let pickChild = desc.childText(for: ["crs:Pick", "Pick"])
        let dmPickAttr = desc.attributeValue(for: ["xmpDM:pick", "pick"])
        let dmPickChild = desc.childText(for: ["xmpDM:pick", "pick"])
        let explicitPickStr = pickAttr ?? pickChild ?? dmPickAttr ?? dmPickChild

        // 2. Rating values
        let ratingAttr = desc.attributeValue(for: ["xmp:Rating", "Rating"])
        let ratingChild = desc.childText(for: ["xmp:Rating", "Rating"])
        let ratingStr = ratingAttr ?? ratingChild

        var parsedRating = 0
        var isMinusOneRating = false
        if let ratingStr, let intVal = Int(ratingStr.trimmingCharacters(in: .whitespacesAndNewlines)) {
            if intVal == -1 {
                isMinusOneRating = true
            } else {
                parsedRating = min(5, max(0, intVal))
            }
        }

        // PickFlag determination
        let pickFlag: PickFlag
        if let explicitPickStr, let pickVal = Int(explicitPickStr.trimmingCharacters(in: .whitespacesAndNewlines)) {
            switch pickVal {
            case 1: pickFlag = .picked
            case -1: pickFlag = .rejected
            default: pickFlag = .unflagged
            }
        } else if isMinusOneRating {
            // Incoming xmp:Rating="-1" without explicit crs:Pick normalized to .rejected and StarRating(0)
            pickFlag = .rejected
            parsedRating = 0
        } else {
            pickFlag = .unflagged
        }

        // 3. ColorLabel values
        let labelAttr = desc.attributeValue(for: ["xmp:Label", "Label"])
        let labelChild = desc.childText(for: ["xmp:Label", "Label"])
        let labelStr = (labelAttr ?? labelChild)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        let colorLabel: ColorLabel
        switch labelStr {
        case "red": colorLabel = .red
        case "orange": colorLabel = .orange
        case "yellow": colorLabel = .yellow
        case "green": colorLabel = .green
        case "blue": colorLabel = .blue
        case "purple": colorLabel = .purple
        case "grey", "gray": colorLabel = .grey
        default: colorLabel = .none
        }

        return CurationMetadata(
            starRating: StarRating(parsedRating),
            pickFlag: pickFlag,
            colorLabel: colorLabel
        )
    }

    func extractExifMetadata() -> ExifMetadata {
        guard let desc = findDescriptionNode() else {
            return ExifMetadata()
        }

        // Camera Model
        let cameraModel = desc.attributeValue(for: ["tiff:Model", "Model"])
            ?? desc.childText(for: ["tiff:Model", "Model"])

        // Lens Model
        let lensModel = desc.attributeValue(for: ["aux:Lens", "exifEX:LensModel", "Lens", "LensModel"])
            ?? desc.childText(for: ["aux:Lens", "exifEX:LensModel", "Lens", "LensModel"])

        // Focal Length
        let focalStr = desc.attributeValue(for: ["exif:FocalLength", "FocalLength"])
            ?? desc.childText(for: ["exif:FocalLength", "FocalLength"])
        let focalLength = focalStr.flatMap(Self.parseRationalOrDecimal)

        // FNumber (Aperture)
        let fNumberStr = desc.attributeValue(for: ["exif:FNumber", "FNumber"])
            ?? desc.childText(for: ["exif:FNumber", "FNumber"])
        let fNumber = fNumberStr.flatMap(Self.parseRationalOrDecimal)

        // Exposure Time (Shutter Speed)
        let expStr = desc.attributeValue(for: ["exif:ExposureTime", "ExposureTime"])
            ?? desc.childText(for: ["exif:ExposureTime", "ExposureTime"])
        let exposureTime = expStr.flatMap(Self.parseRationalOrDecimal)

        // ISO Speed Ratings
        var isoRatings: [Int] = []
        if let isoAttr = desc.attributeValue(for: ["exif:ISOSpeedRatings", "ISOSpeedRatings"]) {
            for part in isoAttr.components(separatedBy: CharacterSet(charactersIn: ",; ")) {
                if let val = Int(part.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    isoRatings.append(val)
                }
            }
        }
        if isoRatings.isEmpty {
            if let isoNode = desc.children.first(where: {
                $0.name.lowercased().contains("isospeedratings")
            }) {
                let liNodes = Self.collectLiNodes(under: isoNode)
                if !liNodes.isEmpty {
                    for li in liNodes {
                        if let val = Int(li.text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                            isoRatings.append(val)
                        }
                    }
                } else if let direct = Int(isoNode.text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    isoRatings.append(direct)
                }
            }
        }

        // Date Time Original
        let dateStr = desc.attributeValue(for: ["exif:DateTimeOriginal", "DateTimeOriginal", "photoshop:DateCreated", "xmp:CreateDate"])
            ?? desc.childText(for: ["exif:DateTimeOriginal", "DateTimeOriginal", "photoshop:DateCreated", "xmp:CreateDate"])
        let dateTimeOriginal = dateStr.flatMap(Self.parseDate)

        return ExifMetadata(
            cameraModel: cameraModel,
            lensModel: lensModel,
            focalLength: focalLength,
            fNumber: fNumber,
            exposureTime: exposureTime,
            isoSpeedRatings: isoRatings,
            dateTimeOriginal: dateTimeOriginal
        )
    }

    private static func collectLiNodes(under node: XMPNode) -> [XMPNode] {
        var result: [XMPNode] = []
        for child in node.children {
            let lower = child.name.lowercased()
            if lower == "rdf:li" || lower == "li" {
                result.append(child)
            } else {
                result.append(contentsOf: collectLiNodes(under: child))
            }
        }
        return result
    }

    private static func parseRationalOrDecimal(_ string: String) -> Double? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("/") {
            let parts = trimmed.split(separator: "/")
            if parts.count == 2,
               let num = Double(parts[0].trimmingCharacters(in: .whitespaces)),
               let denom = Double(parts[1].trimmingCharacters(in: .whitespaces)),
               denom != 0 {
                return num / denom
            }
        }
        return Double(trimmed)
    }

    private static func parseDate(_ string: String) -> Date? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }

        // Try standard ISO8601
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        if let d = isoFormatter.date(from: trimmed) {
            return d
        }
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds, .withDashSeparatorInDate, .withColonSeparatorInTime]
        if let d = isoFormatter.date(from: trimmed) {
            return d
        }

        // Try EXIF date format yyyy:MM:dd HH:mm:ss or yyyy-MM-dd'T'HH:mm:ss
        let customFormatter = DateFormatter()
        customFormatter.locale = Locale(identifier: "en_US_POSIX")
        customFormatter.timeZone = TimeZone(secondsFromGMT: 0)

        let formats = [
            "yyyy:MM:dd HH:mm:ss",
            "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy-MM-dd'T'HH:mm:ssZ",
            "yyyy-MM-dd'T'HH:mm:ssXXX",
            "yyyy-MM-dd"
        ]
        for f in formats {
            customFormatter.dateFormat = f
            if let d = customFormatter.date(from: trimmed) {
                return d
            }
        }
        return nil
    }
}

final class XMPTreeParser: NSObject, XMLParserDelegate {
    private var stack: [XMPNode] = []
    private var root: XMPNode?

    static func parse(data: Data) throws -> XMPDocumentTree {
        let parser = XMLParser(data: data)
        let delegate = XMPTreeParser()
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false

        guard parser.parse() else {
            if let error = parser.parserError {
                throw error
            }
            throw CocoaError(.fileReadCorruptFile)
        }
        return XMPDocumentTree(root: delegate.root)
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let node = XMPNode(name: elementName, attributes: attributeDict)
        if let current = stack.last {
            current.children.append(node)
        } else {
            root = node
        }
        stack.append(node)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        stack.last?.text.append(string)
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        _ = stack.popLast()
    }
}

