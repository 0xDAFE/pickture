import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Pickture

@MainActor
struct CullingSessionFilmstripAndShortcutTests {

    private func makeTemporaryDirectory() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("PicktureFilmstripTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private func createTestJPEG(at url: URL, width: Int = 320, height: Int = 240, r: UInt8 = 100, g: UInt8 = 150, b: UInt8 = 200) throws {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                pixels[offset] = r
                pixels[offset + 1] = g
                pixels[offset + 2] = b
                pixels[offset + 3] = 255
            }
        }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let cgImage = CGImage(
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: width * 4,
                  space: colorSpace,
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: true,
                  intent: .defaultIntent
              ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let mutableData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            mutableData as CFMutableData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try (mutableData as Data).write(to: url)
    }

    // MARK: - Slice 1: PreviewSource Toggling on MediaPairs

    @Test("Viewing a MediaPair defaults to PreferRaster and toggling PreviewSource switches to PreferRAW")
    func mediaPairPreviewSourceToggling() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let jpgURL = root.appendingPathComponent("DSC0001.JPG")
        let rawURL = root.appendingPathComponent("DSC0001.ARW")

        try createTestJPEG(at: jpgURL, width: 320, height: 240, r: 80, g: 120, b: 220)

        // Create an embedded JPEG inside the RAW file header prefix to simulate a RAW container with embedded preview
        let rawHeaderPrefix = try Data(contentsOf: jpgURL)
        var rawData = rawHeaderPrefix
        rawData.append(Data(repeating: 0xAA, count: 2048))
        try rawData.write(to: rawURL)

        let storeRoot = root.appendingPathComponent(".test-store", isDirectory: true)
        let session = CullingSession(storageRootURL: storeRoot)
        try session.openFolder(at: root)

        #expect(session.items.count == 1)
        let item = try #require(session.items.first)
        #expect(item.isMediaPair)

        // Default PreviewSource is preferRaster
        #expect(session.previewSource == .preferRaster)
        #expect(item.preferredFile(for: session.previewSource).formatKind == .raster)
        #expect(item.preferredFile(for: session.previewSource).fileName == "DSC0001.JPG")

        let rasterThumbData = await session.loadThumbnailData(for: item, maxPixelSize: 360)
        #expect(rasterThumbData != nil)

        // Toggle PreviewSource to preferRAW
        session.togglePreviewSource()
        #expect(session.previewSource == .preferRAW)
        #expect(item.preferredFile(for: session.previewSource).formatKind == .raw)
        #expect(item.preferredFile(for: session.previewSource).fileName == "DSC0001.ARW")

        let rawThumbData = await session.loadThumbnailData(for: item, maxPixelSize: 360)
        #expect(rawThumbData != nil)

        // Toggle back to preferRaster
        session.togglePreviewSource()
        #expect(session.previewSource == .preferRaster)
    }

    // MARK: - Slice 2: BorderTapNavigation State & Edge Tap Handling

    @Test("BorderTapNavigation edge tap zones navigate to previous/next items when enabled and no-op when disabled")
    func borderTapNavigationZoneCalculationsAndItemProgression() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        // Create 3 test items: IMG001.JPG, IMG002.JPG, IMG003.JPG
        for i in 1...3 {
            let url = root.appendingPathComponent("IMG00\(i).JPG")
            try createTestJPEG(at: url, width: 320, height: 240)
        }

        let storeRoot = root.appendingPathComponent(".test-store", isDirectory: true)
        let session = CullingSession(storageRootURL: storeRoot)
        try session.openFolder(at: root)

        #expect(session.items.count == 3)
        let item0 = session.items[0]
        let item1 = session.items[1]
        let item2 = session.items[2]

        // BorderTapNavigation enabled by default
        #expect(session.isBorderTapNavigationEnabled == true)

        // Verify border tap zone calculation: min(width * 0.12, 64pt)
        #expect(session.borderTapZoneWidth(for: 1000.0) == 64.0)
        #expect(session.borderTapZoneWidth(for: 400.0) == 48.0)

        // Select the middle item
        session.selectedItemID = item1.id
        #expect(session.selectedItemID == item1.id)

        let containerSize = CGSize(width: 1000.0, height: 800.0)

        // Tapping inside the left border zone (x <= 64) navigates to previous item (item0)
        let handledLeft = session.handleBorderTap(at: CGPoint(x: 30.0, y: 400.0), in: containerSize)
        #expect(handledLeft == true)
        #expect(session.selectedItemID == item0.id)

        // Tapping left again when already at first item stays at item0
        let handledLeftAtStart = session.handleBorderTap(at: CGPoint(x: 30.0, y: 400.0), in: containerSize)
        #expect(handledLeftAtStart == true)
        #expect(session.selectedItemID == item0.id)

        // Tapping inside the right border zone (x >= 936) navigates to next item (item1)
        let handledRight1 = session.handleBorderTap(at: CGPoint(x: 970.0, y: 400.0), in: containerSize)
        #expect(handledRight1 == true)
        #expect(session.selectedItemID == item1.id)

        // Tapping right again navigates to item2
        let handledRight2 = session.handleBorderTap(at: CGPoint(x: 970.0, y: 400.0), in: containerSize)
        #expect(handledRight2 == true)
        #expect(session.selectedItemID == item2.id)

        // Tapping right at end stays at item2
        let handledRightAtEnd = session.handleBorderTap(at: CGPoint(x: 970.0, y: 400.0), in: containerSize)
        #expect(handledRightAtEnd == true)
        #expect(session.selectedItemID == item2.id)

        // Center tap (between border zones) returns false and does not navigate
        session.selectedItemID = item1.id
        let handledCenter = session.handleBorderTap(at: CGPoint(x: 500.0, y: 400.0), in: containerSize)
        #expect(handledCenter == false)
        #expect(session.selectedItemID == item1.id)

        // Toggle BorderTapNavigation OFF
        session.toggleBorderTapNavigation()
        #expect(session.isBorderTapNavigationEnabled == false)

        // When disabled, edge taps return false and do not navigate
        let handledDisabledLeft = session.handleBorderTap(at: CGPoint(x: 30.0, y: 400.0), in: containerSize)
        #expect(handledDisabledLeft == false)
        #expect(session.selectedItemID == item1.id)

        let handledDisabledRight = session.handleBorderTap(at: CGPoint(x: 970.0, y: 400.0), in: containerSize)
        #expect(handledDisabledRight == false)
        #expect(session.selectedItemID == item1.id)

        // Toggle back ON
        session.toggleBorderTapNavigation()
        #expect(session.isBorderTapNavigationEnabled == true)
    }

    // MARK: - Slice 3: ShortcutProfile Key Dispatch (Lightroom, Capture One, Custom)

    @Test("ShortcutProfile dispatches keys across Lightroom, Capture One, and Custom profiles")
    func shortcutProfileKeyDispatchAcrossLightroomCaptureOneAndCustom() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        for i in 1...3 {
            let url = root.appendingPathComponent("IMG00\(i).JPG")
            try createTestJPEG(at: url, width: 320, height: 240)
        }

        let storeRoot = root.appendingPathComponent(".test-store", isDirectory: true)
        let session = CullingSession(storageRootURL: storeRoot)
        session.isSyncSuspended = true
        try session.openFolder(at: root)

        let item0 = session.items[0]
        let item1 = session.items[1]

        // Default profile is Lightroom
        #expect(session.shortcutProfileKind == .lightroom)
        session.selectedItemID = item0.id

        // Lightroom rating keys: 0..5
        #expect(session.handleShortcutKey("5") == true)
        #expect(session.curationMetadata(for: item0).starRating == 5)

        #expect(session.handleShortcutKey("0") == true)
        #expect(session.curationMetadata(for: item0).starRating == 0)

        #expect(session.handleShortcutKey("3") == true)
        #expect(session.curationMetadata(for: item0).starRating == 3)

        // Lightroom flag keys: P (Picked), X (Rejected), U (Unflagged)
        #expect(session.handleShortcutKey("P") == true)
        #expect(session.curationMetadata(for: item0).pickFlag == .picked)

        #expect(session.handleShortcutKey("x") == true)
        #expect(session.curationMetadata(for: item0).pickFlag == .rejected)

        #expect(session.handleShortcutKey("u") == true)
        #expect(session.curationMetadata(for: item0).pickFlag == .unflagged)

        // Lightroom color labels: 6 (Red), 7 (Yellow), 8 (Green), 9 (Blue)
        #expect(session.handleShortcutKey("6") == true)
        #expect(session.curationMetadata(for: item0).colorLabel == .red)

        #expect(session.handleShortcutKey("7") == true)
        #expect(session.curationMetadata(for: item0).colorLabel == .yellow)

        #expect(session.handleShortcutKey("8") == true)
        #expect(session.curationMetadata(for: item0).colorLabel == .green)

        #expect(session.handleShortcutKey("9") == true)
        #expect(session.curationMetadata(for: item0).colorLabel == .blue)

        // View mode switching: G (Grid), E (Filmstrip), Space (Toggle)
        #expect(session.viewMode == .grid)
        #expect(session.handleShortcutKey("e") == true)
        #expect(session.viewMode == .filmstrip)

        #expect(session.handleShortcutKey("g") == true)
        #expect(session.viewMode == .grid)

        #expect(session.handleShortcutKey(" ") == true)
        #expect(session.viewMode == .filmstrip)

        #expect(session.handleShortcutKey("space") == true)
        #expect(session.viewMode == .grid)

        // PreviewSource toggle shortcut: J
        #expect(session.previewSource == .preferRaster)
        #expect(session.handleShortcutKey("j") == true)
        #expect(session.previewSource == .preferRAW)
        #expect(session.handleShortcutKey("J") == true)
        #expect(session.previewSource == .preferRaster)

        // Navigation shortcuts: right, left
        session.selectedItemID = item0.id
        #expect(session.handleShortcutKey("right") == true)
        #expect(session.selectedItemID == item1.id)

        #expect(session.handleShortcutKey("left") == true)
        #expect(session.selectedItemID == item0.id)

        // Switch to Capture One profile
        session.setShortcutProfileKind(.captureOne)
        #expect(session.shortcutProfileKind == .captureOne)

        // Capture One flag keys: + (Picked), - (Rejected), U (Unflagged)
        #expect(session.handleShortcutKey("+") == true)
        #expect(session.curationMetadata(for: item0).pickFlag == .picked)

        #expect(session.handleShortcutKey("-") == true)
        #expect(session.curationMetadata(for: item0).pickFlag == .rejected)

        #expect(session.handleShortcutKey("u") == true)
        #expect(session.curationMetadata(for: item0).pickFlag == .unflagged)

        // Capture One color label tag: *
        #expect(session.handleShortcutKey("*") == true)
        #expect(session.curationMetadata(for: item0).colorLabel == .green)

        // Switch to Custom profile with user override
        session.setShortcutProfileKind(.custom)
        #expect(session.shortcutProfileKind == .custom)

        session.setCustomShortcut(key: "z", command: .curation(.setPickFlag(.picked)))
        session.setCustomShortcut(key: "r", command: .curation(.setColorLabel(.red)))

        #expect(session.handleShortcutKey("z") == true)
        #expect(session.curationMetadata(for: item0).pickFlag == .picked)

        #expect(session.handleShortcutKey("r") == true)
        #expect(session.curationMetadata(for: item0).colorLabel == .red)

        // Unrecognized key returns false
        #expect(session.handleShortcutKey("F12") == false)
    }

    // MARK: - Slice 4: Auto-Advance Selection Progression

    @Test("Toggling Auto-Advance automatically advances selection immediately after StarRating, PickFlag, or ColorLabel")
    func autoAdvanceSelectionProgressionOnCurationMutations() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        for i in 1...3 {
            let url = root.appendingPathComponent("IMG00\(i).JPG")
            try createTestJPEG(at: url, width: 320, height: 240)
        }

        let storeRoot = root.appendingPathComponent(".test-store", isDirectory: true)
        let session = CullingSession(storageRootURL: storeRoot)
        session.isSyncSuspended = true
        try session.openFolder(at: root)

        let item0 = session.items[0]
        let item1 = session.items[1]
        let item2 = session.items[2]

        // 1. When Auto-Advance is disabled, mutations do NOT advance selection
        #expect(session.isAutoAdvanceEnabled == false)
        session.selectedItemID = item0.id

        session.setStarRating(4, for: item0)
        #expect(session.curationMetadata(for: item0).starRating == 4)
        #expect(session.selectedItemID == item0.id)

        session.setPickFlag(.picked, for: item0)
        #expect(session.curationMetadata(for: item0).pickFlag == .picked)
        #expect(session.selectedItemID == item0.id)

        session.setColorLabel(.red, for: item0)
        #expect(session.curationMetadata(for: item0).colorLabel == .red)
        #expect(session.selectedItemID == item0.id)

        // 2. Toggle Auto-Advance ON (via A key or method)
        #expect(session.handleShortcutKey("a") == true)
        #expect(session.isAutoAdvanceEnabled == true)

        session.selectedItemID = item0.id

        // Mutating StarRating on item0 automatically advances selection to item1
        session.setStarRating(5, for: item0)
        #expect(session.curationMetadata(for: item0).starRating == 5)
        #expect(session.selectedItemID == item1.id)

        // Mutating PickFlag on item1 automatically advances selection to item2
        session.setPickFlag(.rejected, for: item1)
        #expect(session.curationMetadata(for: item1).pickFlag == .rejected)
        #expect(session.selectedItemID == item2.id)

        // Mutating ColorLabel on item2 advances or remains on last item (item2)
        session.setColorLabel(.blue, for: item2)
        #expect(session.curationMetadata(for: item2).colorLabel == .blue)
        #expect(session.selectedItemID == item2.id)

        // 3. Test keyboard shortcuts auto-advance with active profile
        session.selectedItemID = item0.id

        // Press '3' -> sets StarRating 3 on item0, advances to item1
        #expect(session.handleShortcutKey("3") == true)
        #expect(session.curationMetadata(for: item0).starRating == 3)
        #expect(session.selectedItemID == item1.id)

        // Press 'p' -> sets PickFlag.picked on item1, advances to item2
        #expect(session.handleShortcutKey("p") == true)
        #expect(session.curationMetadata(for: item1).pickFlag == .picked)
        #expect(session.selectedItemID == item2.id)

        // Press '8' -> sets ColorLabel.green on item2, stays on item2
        #expect(session.handleShortcutKey("8") == true)
        #expect(session.curationMetadata(for: item2).colorLabel == .green)
        #expect(session.selectedItemID == item2.id)

        // 4. Toggle Auto-Advance OFF via 'A' key
        #expect(session.handleShortcutKey("A") == true)
        #expect(session.isAutoAdvanceEnabled == false)

        session.selectedItemID = item0.id
        #expect(session.handleShortcutKey("2") == true)
        #expect(session.curationMetadata(for: item0).starRating == 2)
        #expect(session.selectedItemID == item0.id) // does not advance
    }
}
