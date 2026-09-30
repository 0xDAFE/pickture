import CryptoKit
import Foundation

nonisolated enum SidecarCodec {

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

        // Also update any <filename>.<ext>.xmp that already exists on disk
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

    // MARK: - XMP Parsing

    static func parse(data: Data) throws -> (curation: CurationMetadata, exif: ExifMetadata) {
        let tree = try XMPTreeParser.parse(data: data)
        return (curation: tree.extractCurationMetadata(), exif: tree.extractExifMetadata())
    }

    // MARK: - XMP Round-Trip Serialization

    static func update(xmlData: Data?, with curation: CurationMetadata) throws -> Data {
        guard let xmlData, !xmlData.isEmpty else {
            return generateDefaultXMPData(with: curation)
        }

        let tree: XMPDocumentTree
        do {
            tree = try XMPTreeParser.parse(data: xmlData)
        } catch {
            return generateDefaultXMPData(with: curation)
        }

        guard let desc = tree.findDescriptionNode() else {
            return generateDefaultXMPData(with: curation)
        }

        // Apply curation changes to the XML tree
        tree.apply(curation: curation, to: desc)

        let serializedXML = tree.serialize()
        return Data(serializedXML.utf8)
    }

    static func computeDigest(for data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func generateDefaultXMPData(with curation: CurationMetadata) -> Data {
        let pickVal: Int
        switch curation.pickFlag {
        case .picked: pickVal = 1
        case .rejected: pickVal = -1
        case .unflagged: pickVal = 0
        }

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

    func apply(curation: CurationMetadata, to desc: XMPNode) {
        if desc.attributes["xmlns:xmp"] == nil {
            desc.attributes["xmlns:xmp"] = "http://ns.adobe.com/xap/1.0/"
        }
        if desc.attributes["xmlns:crs"] == nil {
            desc.attributes["xmlns:crs"] = "http://ns.adobe.com/camera-raw-settings/1.0/"
        }
        if desc.attributes["xmlns:xmpDM"] == nil {
            desc.attributes["xmlns:xmpDM"] = "http://ns.adobe.com/xmp/1.0/DynamicMedia/"
        }

        let pickVal: Int
        switch curation.pickFlag {
        case .picked: pickVal = 1
        case .rejected: pickVal = -1
        case .unflagged: pickVal = 0
        }

        desc.setAttribute(name: "crs:Pick", value: "\(pickVal)")
        desc.setAttribute(name: "xmpDM:pick", value: "\(pickVal)")
        desc.setAttribute(name: "xmp:Rating", value: "\(curation.starRating.value)")

        if let pickChild = desc.children.first(where: { $0.matches(name: $0.name, target: "crs:Pick") || $0.matches(name: $0.name, target: "Pick") }) {
            pickChild.text = "\(pickVal)"
        }
        if let dmPickChild = desc.children.first(where: { $0.matches(name: $0.name, target: "xmpDM:pick") || $0.matches(name: $0.name, target: "pick") }) {
            dmPickChild.text = "\(pickVal)"
        }
        if let ratingChild = desc.children.first(where: { $0.matches(name: $0.name, target: "xmp:Rating") || $0.matches(name: $0.name, target: "Rating") }) {
            ratingChild.text = "\(curation.starRating.value)"
        }

        if curation.colorLabel != .none {
            let labelName = curation.colorLabel.rawValue.capitalized
            desc.setAttribute(name: "xmp:Label", value: labelName)
            if let labelChild = desc.children.first(where: { $0.matches(name: $0.name, target: "xmp:Label") || $0.matches(name: $0.name, target: "Label") }) {
                labelChild.text = labelName
            }
        } else {
            desc.removeAttribute(matching: "xmp:Label")
            desc.children.removeAll(where: { $0.matches(name: $0.name, target: "xmp:Label") || $0.matches(name: $0.name, target: "Label") })
        }
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

