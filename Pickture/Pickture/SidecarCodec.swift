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

        // 1. Check <basename>.xmp first (Lightroom / Capture One / Bridge / default convention)
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

        // 2. Check <filename>.<ext>.xmp (Darktable sidecar convention)
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

    // MARK: - Safe Disk I/O & Invalidation Helpers

    static func readData(from url: URL) -> Data? {
        try? Data(contentsOf: url)
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
        try await Task.detached(priority: .utility) {
            let coordinator = NSFileCoordinator(filePresenter: nil)
            let fm = FileManager.default

            struct AttemptResult {
                var coordError: NSError?
                var writeError: Error?

                var error: Error? {
                    coordError ?? writeError
                }
            }

            func attemptWrite(useReplacing: Bool) -> AttemptResult {
                var result = AttemptResult()
                let options: NSFileCoordinator.WritingOptions = useReplacing ? [.forReplacing] : []
                coordinator.coordinate(writingItemAt: url, options: options, error: &result.coordError) { targetURL in
                    do {
                        try data.write(to: targetURL, options: [])
                    } catch {
                        result.writeError = error
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
            if isStaleOrMissingFileError(error) {
                // Progressive backoff with .forReplacing
                let retryDelays: [UInt64] = [50_000_000, 150_000_000]
                for delay in retryDelays {
                    try? await Task.sleep(nanoseconds: delay)
                    let retryAttempt = attemptWrite(useReplacing: true)
                    if retryAttempt.error == nil {
                        return url
                    }
                    lastAttempt = retryAttempt
                }
            }

            let finalError = lastAttempt.error ?? error
            throw finalError
        }.value
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
            return "Network share encountered stale file handles. If using a network share, disconnect and reconnect the server in the Files app to help restore write access."
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
        guard tree.findDescriptionNode() != nil else {
            throw CocoaError(.fileReadCorruptFile)
        }

        // Apply curation changes across all description nodes
        tree.apply(curation: curation)

        let serializedXML = tree.serialize()
        var outputData = Data()
        if tree.hasBOM {
            outputData.append(contentsOf: [0xEF, 0xBB, 0xBF])
        }
        outputData.append(Data(serializedXML.utf8))
        return outputData
    }

    static func computeDigest(for data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func generateDefaultXMPData(with curation: CurationMetadata) -> Data {
        let pickVal = curation.pickFlag.xmpPickValue

        let labelAttr: String
        let urgencyAttr: String
        if curation.colorLabel != .none {
            labelAttr = "\n    xmp:Label=\"\(curation.colorLabel.rawValue.capitalized)\""
            if let urgency = curation.colorLabel.photoshopUrgency {
                urgencyAttr = "\n    photoshop:Urgency=\"\(urgency)\""
            } else {
                urgencyAttr = ""
            }
        } else {
            labelAttr = ""
            urgencyAttr = ""
        }

        let xml = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Pickture">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about=""
            xmlns:xmp="http://ns.adobe.com/xap/1.0/"
            xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
            xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/"
            xmlns:xmpDM="http://ns.adobe.com/xmp/1.0/DynamicMedia/"
            xmp:Rating="\(curation.starRating.value)"
            crs:Pick="\(pickVal)"
            xmpDM:pick="\(pickVal)"\(labelAttr)\(urgencyAttr)>
          </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>
        """
        return Data(xml.utf8)
    }
}


// MARK: - Internal Lossless XMP AST, Tree & Parser

enum XMPChild {
    case element(XMPNode)
    case text(String)
    case comment(String)
    case cdata(String)
    case processingInstruction(target: String, data: String?)
}

enum XMPPreambleItem {
    case xmlDeclaration(String)
    case processingInstruction(target: String, data: String?)
    case comment(String)
    case text(String)

    func serialize() -> String {
        switch self {
        case .xmlDeclaration(let decl):
            return decl.hasSuffix("\n") ? decl : (decl + "\n")
        case .processingInstruction(let target, let data):
            if let data, !data.isEmpty {
                return "<?\(target) \(data)?>\n"
            }
            return "<?\(target)?>\n"
        case .comment(let c):
            return "<!--\(c)-->\n"
        case .text(let t):
            return t
        }
    }
}

final class XMPNode {
    var name: String
    var attributes: [String: String]
    var attributeOrder: [String]
    var children: [XMPChild]

    init(
        name: String,
        attributes: [String: String] = [:],
        attributeOrder: [String] = [],
        children: [XMPChild] = []
    ) {
        self.name = name
        self.attributes = attributes
        self.attributeOrder = attributeOrder.isEmpty ? attributes.keys.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) : attributeOrder
        self.children = children
    }

    var elementChildren: [XMPNode] {
        children.compactMap {
            if case .element(let node) = $0 { return node }
            return nil
        }
    }

    var textContent: String {
        get {
            var str = ""
            for child in children {
                switch child {
                case .text(let t), .cdata(let t):
                    str += t
                default:
                    break
                }
            }
            return str
        }
        set {
            children.removeAll {
                switch $0 {
                case .text, .cdata: return true
                default: return false
                }
            }
            if !newValue.isEmpty {
                children.append(.text(newValue))
            }
        }
    }

    func appendChildElement(_ childNode: XMPNode) {
        children.append(.element(childNode))
    }

    func hasNamespaceDeclared(prefix: String) -> Bool {
        let target = "xmlns:\(prefix)".lowercased()
        return attributes.keys.contains { $0.lowercased() == target }
    }

    func findAllDescendants(matching predicate: (XMPNode) -> Bool) -> [XMPNode] {
        var results: [XMPNode] = []
        if predicate(self) {
            results.append(self)
        }
        for child in children {
            if case .element(let childElem) = child {
                results.append(contentsOf: childElem.findAllDescendants(matching: predicate))
            }
        }
        return results
    }

    func findDescendant(named localOrQualifiedName: String) -> XMPNode? {
        if matches(target: localOrQualifiedName) {
            return self
        }
        for child in children {
            if case .element(let childElem) = child {
                if let found = childElem.findDescendant(named: localOrQualifiedName) {
                    return found
                }
            }
        }
        return nil
    }

    func attributeValue(for names: [String]) -> String? {
        for (key, value) in attributes {
            for target in names {
                if Self.matches(name: key, target: target) {
                    return value
                }
            }
        }
        return nil
    }

    func childText(for names: [String]) -> String? {
        for child in children {
            if case .element(let childElem) = child {
                for target in names {
                    if childElem.matches(target: target) {
                        let trimmed = childElem.textContent.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            return trimmed
                        }
                    }
                }
            }
        }
        return nil
    }

    func matches(target: String) -> Bool {
        Self.matches(name: name, target: target)
    }

    static func matches(name: String, target: String) -> Bool {
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
        if let existingKey = attributes.keys.first(where: { Self.matches(name: $0, target: name) }) {
            attributes[existingKey] = value
        } else {
            attributes[name] = value
            attributeOrder.append(name)
        }
    }

    func removeAttribute(matching targetName: String) {
        let keysToRemove = attributes.keys.filter { Self.matches(name: $0, target: targetName) }
        for key in keysToRemove {
            attributes.removeValue(forKey: key)
            attributeOrder.removeAll(where: { $0 == key })
        }
    }

    func serialize(indent: Int) -> String {
        let indentStr = String(repeating: " ", count: indent * 2)
        var result = "\(indentStr)<\(name)"

        let sortedKeys = attributes.keys.sorted { k1, k2 in
            let isNs1 = k1.starts(with: "xmlns")
            let isNs2 = k2.starts(with: "xmlns")
            if isNs1 != isNs2 { return isNs1 }
            if isNs1 && isNs2 {
                if k1 == "xmlns" { return true }
                if k2 == "xmlns" { return false }
                if k1 == "xmlns:rdf" { return true }
                if k2 == "xmlns:rdf" { return false }
                return k1.localizedStandardCompare(k2) == .orderedAscending
            }
            if k1 == "rdf:about" { return true }
            if k2 == "rdf:about" { return false }
            let idx1 = attributeOrder.firstIndex(of: k1) ?? Int.max
            let idx2 = attributeOrder.firstIndex(of: k2) ?? Int.max
            if idx1 != idx2 { return idx1 < idx2 }
            return k1.localizedStandardCompare(k2) == .orderedAscending
        }
        for key in sortedKeys {
            if let val = attributes[key] {
                result += " \(key)=\"\(Self.escapeXMLAttribute(val))\""
            }
        }

        if children.isEmpty {
            result += "/>\n"
            return result
        }

        let hasElementChildren = children.contains {
            if case .element = $0 { return true }
            return false
        }

        if !hasElementChildren {
            var inner = ""
            for child in children {
                switch child {
                case .text(let t):
                    inner += Self.escapeXMLText(t)
                case .cdata(let d):
                    inner += "<![CDATA[\(d)]]>"
                case .comment(let c):
                    inner += "<!--\(c)-->"
                case .processingInstruction(let target, let data):
                    if let data, !data.isEmpty {
                        inner += "<?\(target) \(data)?>"
                    } else {
                        inner += "<?\(target)?>"
                    }
                case .element:
                    break
                }
            }
            if inner.isEmpty {
                result += "/>\n"
            } else {
                result += ">\(inner)</\(name)>\n"
            }
        } else {
            result += ">\n"
            for child in children {
                switch child {
                case .element(let node):
                    result += node.serialize(indent: indent + 1)
                case .text(let t):
                    let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        result += "\(indentStr)  \(Self.escapeXMLText(trimmed))\n"
                    }
                case .comment(let c):
                    result += "\(indentStr)  <!--\(c)-->\n"
                case .cdata(let d):
                    result += "\(indentStr)  <![CDATA[\(d)]]>\n"
                case .processingInstruction(let target, let data):
                    if let data, !data.isEmpty {
                        result += "\(indentStr)  <?\(target) \(data)?>\n"
                    } else {
                        result += "\(indentStr)  <?\(target)?>\n"
                    }
                }
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
    var preamble: [XMPPreambleItem] = []
    var postamble: [XMPPreambleItem] = []
    var hasBOM: Bool = false
    var xmlDeclaration: String? = nil

    init(
        root: XMPNode? = nil,
        preamble: [XMPPreambleItem] = [],
        postamble: [XMPPreambleItem] = [],
        hasBOM: Bool = false,
        xmlDeclaration: String? = nil
    ) {
        self.root = root
        self.preamble = preamble
        self.postamble = postamble
        self.hasBOM = hasBOM
        self.xmlDeclaration = xmlDeclaration
    }

    func findDescriptionNodes() -> [XMPNode] {
        guard let root else { return [] }
        return root.findAllDescendants(matching: { node in
            node.matches(target: "rdf:Description") || node.matches(target: "Description")
        })
    }

    func findDescriptionNode() -> XMPNode? {
        findDescriptionNodes().first
    }

    func serialize() -> String {
        var out = ""
        if let xmlDeclaration {
            out += xmlDeclaration.hasSuffix("\n") ? xmlDeclaration : (xmlDeclaration + "\n")
        }
        for item in preamble {
            out += item.serialize()
        }
        if let root {
            out += root.serialize(indent: 0)
        }
        for item in postamble {
            out += item.serialize()
        }
        return out
    }

    func apply(curation: CurationMetadata) {
        var descriptions = findDescriptionNodes()
        if descriptions.isEmpty {
            let newDesc = XMPNode(name: "rdf:Description", attributes: ["rdf:about": ""])
            if let root {
                let rdfNode = root.elementChildren.first(where: {
                    $0.matches(target: "rdf:RDF") || $0.matches(target: "RDF")
                })
                if let rdfNode {
                    rdfNode.appendChildElement(newDesc)
                } else {
                    let newRDF = XMPNode(
                        name: "rdf:RDF",
                        attributes: ["xmlns:rdf": "http://www.w3.org/1999/02/22-rdf-syntax-ns#"],
                        children: [.element(newDesc)]
                    )
                    root.appendChildElement(newRDF)
                }
            }
            descriptions = [newDesc]
        }
        let primaryDesc = descriptions[0]

        // 1. crs:Pick
        let pickVal = curation.pickFlag.xmpPickValue
        setProperty(
            targetName: "crs:Pick",
            value: "\(pickVal)",
            namespacePrefix: "crs",
            namespaceURI: "http://ns.adobe.com/camera-raw-settings/1.0/",
            descriptions: descriptions,
            primaryDesc: primaryDesc
        )

        // 2. xmpDM:pick
        setProperty(
            targetName: "xmpDM:pick",
            value: "\(pickVal)",
            namespacePrefix: "xmpDM",
            namespaceURI: "http://ns.adobe.com/xmp/1.0/DynamicMedia/",
            descriptions: descriptions,
            primaryDesc: primaryDesc
        )

        // 3. xmp:Rating
        setProperty(
            targetName: "xmp:Rating",
            value: "\(curation.starRating.value)",
            namespacePrefix: "xmp",
            namespaceURI: "http://ns.adobe.com/xap/1.0/",
            descriptions: descriptions,
            primaryDesc: primaryDesc
        )

        // 4. xmp:Label and photoshop:Urgency
        if curation.colorLabel != .none {
            let labelName = curation.colorLabel.rawValue.capitalized
            setProperty(
                targetName: "xmp:Label",
                value: labelName,
                namespacePrefix: "xmp",
                namespaceURI: "http://ns.adobe.com/xap/1.0/",
                descriptions: descriptions,
                primaryDesc: primaryDesc
            )

            if let urgency = curation.colorLabel.photoshopUrgency {
                setProperty(
                    targetName: "photoshop:Urgency",
                    value: "\(urgency)",
                    namespacePrefix: "photoshop",
                    namespaceURI: "http://ns.adobe.com/photoshop/1.0/",
                    descriptions: descriptions,
                    primaryDesc: primaryDesc
                )
            } else {
                pruneProperty(named: "photoshop:Urgency", descriptions: descriptions)
            }
        } else {
            pruneProperty(named: "xmp:Label", descriptions: descriptions)
            pruneProperty(named: "photoshop:Urgency", descriptions: descriptions)
        }
    }

    private func setProperty(
        targetName: String,
        value: String,
        namespacePrefix: String,
        namespaceURI: String,
        descriptions: [XMPNode],
        primaryDesc: XMPNode
    ) {
        // A. Does targetName already exist as a child element in ANY description?
        for desc in descriptions {
            for child in desc.children {
                if case .element(let elem) = child, elem.matches(target: targetName) {
                    elem.textContent = value
                    pruneProperty(named: targetName, descriptions: descriptions, exceptIn: desc, exceptChild: elem)
                    return
                }
            }
        }

        // B. Does targetName already exist as an attribute in ANY description?
        for desc in descriptions {
            if desc.attributeValue(for: [targetName]) != nil {
                desc.setAttribute(name: targetName, value: value)
                pruneProperty(named: targetName, descriptions: descriptions, exceptIn: desc, exceptChild: nil)
                return
            }
        }

        // C. Target property does not exist in any description block.
        // Route to the description block declaring the namespace (Q9), or primaryDesc.
        let targetDesc: XMPNode
        if let matching = descriptions.first(where: { isNamespaceDeclaredInScope(prefix: namespacePrefix, on: $0) }) {
            targetDesc = matching
        } else {
            targetDesc = primaryDesc
            if !isNamespaceDeclaredInScope(prefix: namespacePrefix, on: targetDesc) {
                targetDesc.setAttribute(name: "xmlns:\(namespacePrefix)", value: namespaceURI)
            }
        }

        // Adaptive style (Q8): Does targetDesc use scalar child elements (Capture One) or attributes (Lightroom)?
        let hasScalarChildElements = targetDesc.children.contains {
            if case .element(let elem) = $0, elem.elementChildren.isEmpty {
                return true
            }
            return false
        }
        let hasScalarAttributes = targetDesc.attributes.keys.contains { key in
            let lower = key.lowercased()
            return lower.starts(with: "xmp:") || lower.starts(with: "crs:") || lower.starts(with: "photoshop:") || lower.starts(with: "xmpdm:")
        }
        let preferChildElement = hasScalarChildElements && !hasScalarAttributes

        if preferChildElement {
            let newElem = XMPNode(name: targetName, children: [.text(value)])
            targetDesc.appendChildElement(newElem)
            pruneProperty(named: targetName, descriptions: descriptions, exceptIn: targetDesc, exceptChild: newElem)
        } else {
            targetDesc.setAttribute(name: targetName, value: value)
            pruneProperty(named: targetName, descriptions: descriptions, exceptIn: targetDesc, exceptChild: nil)
        }
    }

    private func pruneProperty(
        named targetName: String,
        descriptions: [XMPNode],
        exceptIn keepDesc: XMPNode? = nil,
        exceptChild: XMPNode? = nil
    ) {
        for desc in descriptions {
            if desc !== keepDesc || exceptChild != nil {
                desc.removeAttribute(matching: targetName)
            }
            desc.children.removeAll { child in
                if case .element(let elem) = child, elem.matches(target: targetName) {
                    if let exceptChild, elem === exceptChild {
                        return false
                    }
                    return true
                }
                return false
            }
        }
    }

    func isNamespaceDeclaredInScope(prefix: String, on node: XMPNode) -> Bool {
        if node.hasNamespaceDeclared(prefix: prefix) {
            return true
        }
        if let root, root.hasNamespaceDeclared(prefix: prefix) {
            return true
        }
        if let rdf = root?.elementChildren.first(where: { $0.matches(target: "rdf:RDF") || $0.matches(target: "RDF") }),
           rdf.hasNamespaceDeclared(prefix: prefix) {
            return true
        }
        return false
    }

    func extractCurationMetadata() -> CurationMetadata {
        let descriptions = findDescriptionNodes()
        guard !descriptions.isEmpty else {
            return CurationMetadata()
        }

        // 1. Raw Pick values across all descriptions
        var explicitPickStr: String?
        for desc in descriptions {
            let pickAttr = desc.attributeValue(for: ["crs:Pick", "Pick"])
            let pickChild = desc.childText(for: ["crs:Pick", "Pick"])
            let dmPickAttr = desc.attributeValue(for: ["xmpDM:pick", "pick"])
            let dmPickChild = desc.childText(for: ["xmpDM:pick", "pick"])
            if let found = pickAttr ?? pickChild ?? dmPickAttr ?? dmPickChild {
                explicitPickStr = found
                break
            }
        }

        // 2. Rating values across all descriptions
        var ratingStr: String?
        for desc in descriptions {
            let ratingAttr = desc.attributeValue(for: ["xmp:Rating", "Rating"])
            let ratingChild = desc.childText(for: ["xmp:Rating", "Rating"])
            if let found = ratingAttr ?? ratingChild {
                ratingStr = found
                break
            }
        }

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

        // 3. ColorLabel and photoshop:Urgency across all descriptions
        var labelStr: String?
        var urgencyVal: Int?
        for desc in descriptions {
            if labelStr == nil {
                let labelAttr = desc.attributeValue(for: ["xmp:Label", "Label"])
                let labelChild = desc.childText(for: ["xmp:Label", "Label"])
                if let found = labelAttr ?? labelChild {
                    labelStr = found
                }
            }
            if urgencyVal == nil {
                let uAttr = desc.attributeValue(for: ["photoshop:Urgency", "Urgency"])
                let uChild = desc.childText(for: ["photoshop:Urgency", "Urgency"])
                if let str = uAttr ?? uChild, let intVal = Int(str.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    urgencyVal = intVal
                }
            }
        }

        let trimmedLabel = labelStr?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let colorLabel: ColorLabel
        switch trimmedLabel {
        case "red": colorLabel = .red
        case "orange": colorLabel = .orange
        case "yellow": colorLabel = .yellow
        case "green": colorLabel = .green
        case "blue": colorLabel = .blue
        case "purple": colorLabel = .purple
        case "grey", "gray": colorLabel = .grey
        default:
            if let urgencyVal, let mapped = ColorLabel(photoshopUrgency: urgencyVal) {
                colorLabel = mapped
            } else {
                colorLabel = .none
            }
        }

        return CurationMetadata(
            starRating: StarRating(parsedRating),
            pickFlag: pickFlag,
            colorLabel: colorLabel
        )
    }

    func extractExifMetadata() -> ExifMetadata {
        let descriptions = findDescriptionNodes()
        guard !descriptions.isEmpty else {
            return ExifMetadata()
        }

        func firstAttrOrChild(for names: [String]) -> String? {
            for desc in descriptions {
                if let val = desc.attributeValue(for: names) ?? desc.childText(for: names) {
                    return val
                }
            }
            return nil
        }

        // Camera Model
        let cameraModel = firstAttrOrChild(for: ["tiff:Model", "Model"])

        // Lens Model
        let lensModel = firstAttrOrChild(for: ["aux:Lens", "exifEX:LensModel", "Lens", "LensModel"])

        // Focal Length
        let focalStr = firstAttrOrChild(for: ["exif:FocalLength", "FocalLength"])
        let focalLength = focalStr.flatMap(Self.parseRationalOrDecimal)

        // FNumber (Aperture)
        let fNumberStr = firstAttrOrChild(for: ["exif:FNumber", "FNumber"])
        let fNumber = fNumberStr.flatMap(Self.parseRationalOrDecimal)

        // Exposure Time (Shutter Speed)
        let expStr = firstAttrOrChild(for: ["exif:ExposureTime", "ExposureTime"])
        let exposureTime = expStr.flatMap(Self.parseRationalOrDecimal)

        // ISO Speed Ratings
        var isoRatings: [Int] = []
        for desc in descriptions {
            if let isoAttr = desc.attributeValue(for: ["exif:ISOSpeedRatings", "ISOSpeedRatings"]) {
                for part in isoAttr.components(separatedBy: CharacterSet(charactersIn: ",; ")) {
                    if let val = Int(part.trimmingCharacters(in: .whitespacesAndNewlines)) {
                        isoRatings.append(val)
                    }
                }
            }
            if isoRatings.isEmpty {
                if let isoNode = desc.elementChildren.first(where: {
                    $0.name.lowercased().contains("isospeedratings")
                }) {
                    let liNodes = Self.collectLiNodes(under: isoNode)
                    if !liNodes.isEmpty {
                        for li in liNodes {
                            if let val = Int(li.textContent.trimmingCharacters(in: .whitespacesAndNewlines)) {
                                isoRatings.append(val)
                            }
                        }
                    } else if let direct = Int(isoNode.textContent.trimmingCharacters(in: .whitespacesAndNewlines)) {
                        isoRatings.append(direct)
                    }
                }
            }
            if !isoRatings.isEmpty {
                break
            }
        }

        // Date Time Original
        let dateStr = firstAttrOrChild(for: ["exif:DateTimeOriginal", "DateTimeOriginal", "photoshop:DateCreated", "xmp:CreateDate"])
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
            if case .element(let childElem) = child {
                let lower = childElem.name.lowercased()
                if lower == "rdf:li" || lower == "li" {
                    result.append(childElem)
                } else {
                    result.append(contentsOf: collectLiNodes(under: childElem))
                }
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

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        if let d = isoFormatter.date(from: trimmed) {
            return d
        }
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds, .withDashSeparatorInDate, .withColonSeparatorInTime]
        if let d = isoFormatter.date(from: trimmed) {
            return d
        }

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
    private var preamble: [XMPPreambleItem] = []
    private var postamble: [XMPPreambleItem] = []
    private var hasBOM: Bool = false
    private var xmlDeclaration: String? = nil

    static func parse(data: Data) throws -> XMPDocumentTree {
        var workingData = data
        var hasBOM = false
        if workingData.starts(with: [0xEF, 0xBB, 0xBF]) {
            hasBOM = true
            workingData = workingData.dropFirst(3)
        }

        let sourceStr = String(decoding: workingData, as: UTF8.self)
        var xmlDeclaration: String? = nil
        let trimmedLeading = sourceStr.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedLeading.starts(with: "<?xml") {
            if let endTag = trimmedLeading.range(of: "?>") {
                xmlDeclaration = String(trimmedLeading[..<endTag.upperBound]) + "\n"
            }
        }

        let parser = XMLParser(data: workingData)
        let delegate = XMPTreeParser()
        delegate.hasBOM = hasBOM
        delegate.xmlDeclaration = xmlDeclaration
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

        if sourceStr.contains("<?xpacket begin") && !delegate.preamble.contains(where: {
            if case .processingInstruction(let target, _) = $0, target == "xpacket" { return true }
            return false
        }) {
            if let dataPart = extractProcessingInstruction(matching: "<?xpacket begin", from: sourceStr) {
                delegate.preamble.insert(.processingInstruction(target: "xpacket", data: dataPart), at: 0)
            }
        }

        if sourceStr.contains("<?xpacket end") && !delegate.postamble.contains(where: {
            if case .processingInstruction(let target, _) = $0, target == "xpacket" { return true }
            return false
        }) {
            if let dataPart = extractProcessingInstruction(matching: "<?xpacket end", from: sourceStr) {
                delegate.postamble.append(.processingInstruction(target: "xpacket", data: dataPart))
            }
        }

        return XMPDocumentTree(
            root: delegate.root,
            preamble: delegate.preamble,
            postamble: delegate.postamble,
            hasBOM: delegate.hasBOM,
            xmlDeclaration: delegate.xmlDeclaration
        )
    }

    private static func extractProcessingInstruction(matching marker: String, from sourceStr: String) -> String? {
        guard let startRange = sourceStr.range(of: marker),
              let endRange = sourceStr[startRange.lowerBound...].range(of: "?>") else {
            return nil
        }
        let fullPI = String(sourceStr[startRange.lowerBound...endRange.upperBound])
        return fullPI.replacingOccurrences(of: "<?xpacket", with: "")
            .replacingOccurrences(of: "?>", with: "")
            .trimmingCharacters(in: .whitespaces)
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
            current.children.append(.element(node))
        } else {
            root = node
        }
        stack.append(node)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if let current = stack.last {
            if case .text(let prev)? = current.children.last {
                current.children[current.children.count - 1] = .text(prev + string)
            } else {
                current.children.append(.text(string))
            }
        } else if root == nil {
            if case .text(let prev)? = preamble.last {
                preamble[preamble.count - 1] = .text(prev + string)
            } else {
                preamble.append(.text(string))
            }
        } else {
            if case .text(let prev)? = postamble.last {
                postamble[postamble.count - 1] = .text(prev + string)
            } else {
                postamble.append(.text(string))
            }
        }
    }

    func parser(_ parser: XMLParser, foundComment comment: String) {
        if let current = stack.last {
            current.children.append(.comment(comment))
        } else if root == nil {
            preamble.append(.comment(comment))
        } else {
            postamble.append(.comment(comment))
        }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        let str = String(decoding: CDATABlock, as: UTF8.self)
        if let current = stack.last {
            current.children.append(.cdata(str))
        }
    }

    func parser(_ parser: XMLParser, foundProcessingInstructionWithTarget target: String, data: String?) {
        if let current = stack.last {
            current.children.append(.processingInstruction(target: target, data: data))
        } else if root == nil {
            preamble.append(.processingInstruction(target: target, data: data))
        } else {
            postamble.append(.processingInstruction(target: target, data: data))
        }
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


