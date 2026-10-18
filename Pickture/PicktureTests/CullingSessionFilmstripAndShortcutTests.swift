import CoreGraphics
import Foundation
import ImageIO
import Observation
import Testing
import UniformTypeIdentifiers
@testable import Pickture

@Suite("CullingSession Filmstrip and Shortcut Tests", .serialized)
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

    // MARK: - Slice 5: Dynamic Aspect-Ratio Sizing & Clean Framing (Issue #11)

    @Test("Standard aspect ratios in bottom dock scale width dynamically clamped between 48pt and 128pt with 72pt height")
    func filmstripThumbnailSizeBottomDockStandardAspectRatios() {
        let session = CullingSession()

        // 16:9 widescreen video (1.777) -> 128 x 72pt
        let videoSize = session.filmstripThumbnailSize(aspectRatio: 1.777, dockPosition: .bottom)
        #expect(videoSize.width == 128)
        #expect(videoSize.height == 72)

        // 3:2 DSLR RAW (1.5) -> 108 x 72pt
        let dslrRawSize = session.filmstripThumbnailSize(aspectRatio: 1.5, dockPosition: .bottom)
        #expect(dslrRawSize.width == 108)
        #expect(dslrRawSize.height == 72)

        // 4:3 standard photo (1.333) -> 96 x 72pt
        let photo43Size = session.filmstripThumbnailSize(aspectRatio: 1.333, dockPosition: .bottom)
        #expect(photo43Size.width == 96)
        #expect(photo43Size.height == 72)

        // 1:1 square crop (1.0) -> 72 x 72pt
        let squareSize = session.filmstripThumbnailSize(aspectRatio: 1.0, dockPosition: .bottom)
        #expect(squareSize.width == 72)
        #expect(squareSize.height == 72)

        // 2:3 portrait photo (0.667) -> 48 x 72pt
        let portrait23Size = session.filmstripThumbnailSize(aspectRatio: 0.667, dockPosition: .bottom)
        #expect(portrait23Size.width == 48)
        #expect(portrait23Size.height == 72)
    }

    @Test("Standard aspect ratios in right dock scale height dynamically clamped between 64pt and 150pt with 112pt width")
    func filmstripThumbnailSizeRightDockStandardAspectRatios() {
        let session = CullingSession()

        // 16:9 widescreen video (1.777) -> 112 x 64pt (clamped)
        let videoSize = session.filmstripThumbnailSize(aspectRatio: 1.777, dockPosition: .right)
        #expect(videoSize.width == 112)
        #expect(videoSize.height == 64)

        // 3:2 DSLR RAW (1.5) -> 112 x 75pt
        let dslrRawSize = session.filmstripThumbnailSize(aspectRatio: 1.5, dockPosition: .right)
        #expect(dslrRawSize.width == 112)
        #expect(dslrRawSize.height == 75)

        // 4:3 standard photo (1.333) -> 112 x 84pt
        let photo43Size = session.filmstripThumbnailSize(aspectRatio: 1.333, dockPosition: .right)
        #expect(photo43Size.width == 112)
        #expect(photo43Size.height == 84)

        // 1:1 square crop (1.0) -> 112 x 112pt
        let squareSize = session.filmstripThumbnailSize(aspectRatio: 1.0, dockPosition: .right)
        #expect(squareSize.width == 112)
        #expect(squareSize.height == 112)

        // 2:3 portrait photo (0.667) -> 112 x 150pt (clamped)
        let portrait23Size = session.filmstripThumbnailSize(aspectRatio: 0.667, dockPosition: .right)
        #expect(portrait23Size.width == 112)
        #expect(portrait23Size.height == 150)
    }

    @Test("Boundary clamping and invalid aspect ratios safely clamp and fall back without throwing or crashing")
    func filmstripThumbnailSizeBoundaryClampingAndSafeFallbacks() {
        let session = CullingSession()

        // Ultra-wide 3.5:1 panorama in bottom dock clamps to max width 128pt
        let panoBottom = session.filmstripThumbnailSize(aspectRatio: 3.5, dockPosition: .bottom)
        #expect(panoBottom.width == 128)
        #expect(panoBottom.height == 72)

        // Ultra-tall 1:3 vertical image in bottom dock clamps to min width 48pt
        let tallBottom = session.filmstripThumbnailSize(aspectRatio: 1.0 / 3.0, dockPosition: .bottom)
        #expect(tallBottom.width == 48)
        #expect(tallBottom.height == 72)

        // Ultra-tall 1:3 vertical image in right dock clamps to max height 150pt
        let tallRight = session.filmstripThumbnailSize(aspectRatio: 1.0 / 3.0, dockPosition: .right)
        #expect(tallRight.width == 112)
        #expect(tallRight.height == 150)

        // Ultra-wide 3.5:1 panorama in right dock clamps to min height 64pt
        let panoRight = session.filmstripThumbnailSize(aspectRatio: 3.5, dockPosition: .right)
        #expect(panoRight.width == 112)
        #expect(panoRight.height == 64)

        // Zero aspect ratio safely falls back to standard default dimensions (3:2 DSLR)
        let zeroBottom = session.filmstripThumbnailSize(aspectRatio: 0.0, dockPosition: .bottom)
        #expect(zeroBottom.width == 108)
        #expect(zeroBottom.height == 72)

        let zeroRight = session.filmstripThumbnailSize(aspectRatio: 0.0, dockPosition: .right)
        #expect(zeroRight.width == 112)
        #expect(zeroRight.height == 75)

        // Negative aspect ratio safely falls back to standard default dimensions
        let negativeBottom = session.filmstripThumbnailSize(aspectRatio: -1.5, dockPosition: .bottom)
        #expect(negativeBottom.width == 108)
        #expect(negativeBottom.height == 72)

        // NaN aspect ratio safely falls back to standard default dimensions
        let nanBottom = session.filmstripThumbnailSize(aspectRatio: CGFloat.nan, dockPosition: .bottom)
        #expect(nanBottom.width == 108)
        #expect(nanBottom.height == 72)

        let nanRight = session.filmstripThumbnailSize(aspectRatio: CGFloat.nan, dockPosition: .right)
        #expect(nanRight.width == 112)
        #expect(nanRight.height == 75)

        // Infinite aspect ratio safely falls back to standard default dimensions
        let infiniteBottom = session.filmstripThumbnailSize(aspectRatio: CGFloat.infinity, dockPosition: .bottom)
        #expect(infiniteBottom.width == 108)
        #expect(infiniteBottom.height == 72)
    }

    @Test("Changing filmstripDockPosition toggles resolved dimensions and MediaItem fallbacks respect photo and video ratios")
    func filmstripDockPositionSwitchingAndFallbackAspectRatios() {
        let session = CullingSession()

        #expect(session.fallbackAspectRatio(for: .photo) == 1.5)
        #expect(session.fallbackAspectRatio(for: .video) == 1.777)

        let photoFile = MediaFile(url: URL(fileURLWithPath: "/tmp/test.jpg"), formatKind: .raster)
        let photoItem = MediaItem(
            id: "/tmp/test.jpg",
            baseName: "test",
            directoryURL: URL(fileURLWithPath: "/tmp"),
            relativeDirectoryPath: "",
            kind: .photo,
            primaryFile: photoFile,
            mediaPair: nil,
            sidecarURL: nil
        )

        let videoFile = MediaFile(url: URL(fileURLWithPath: "/tmp/clip.mov"), formatKind: .video)
        let videoItem = MediaItem(
            id: "/tmp/clip.mov",
            baseName: "clip",
            directoryURL: URL(fileURLWithPath: "/tmp"),
            relativeDirectoryPath: "",
            kind: .video,
            primaryFile: videoFile,
            mediaPair: nil,
            sidecarURL: nil
        )

        #expect(session.fallbackAspectRatio(for: photoItem) == 1.5)
        #expect(session.fallbackAspectRatio(for: videoItem) == 1.777)

        // Bottom dock (default)
        session.setFilmstripDockPosition(.bottom)
        #expect(session.filmstripDockPosition == .bottom)

        let photoBottomSize = session.filmstripThumbnailSize(for: photoItem)
        #expect(photoBottomSize.width == 108)
        #expect(photoBottomSize.height == 72)

        let videoBottomSize = session.filmstripThumbnailSize(for: videoItem)
        #expect(videoBottomSize.width == 128)
        #expect(videoBottomSize.height == 72)

        // Switch to Right dock
        session.setFilmstripDockPosition(.right)
        #expect(session.filmstripDockPosition == .right)

        let photoRightSize = session.filmstripThumbnailSize(for: photoItem)
        #expect(photoRightSize.width == 112)
        #expect(photoRightSize.height == 75)

        let videoRightSize = session.filmstripThumbnailSize(for: videoItem)
        #expect(videoRightSize.width == 112)
        #expect(videoRightSize.height == 64)
    }

    @Test("Filmstrip task key contract incorporates item.id, previewSource, and cacheGeneration, invalidating on toggle and cache clear")
    func filmstripTaskKeyContract() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try createTestJPEG(at: root.appendingPathComponent("TEST.JPG"))

        let session = CullingSession(storageRootURL: root.appendingPathComponent(".test-store", isDirectory: true))
        try session.openFolder(at: root)

        let item = try #require(session.items.first)
        let initialGen = session.cacheGeneration
        let key1 = "\(item.id)-\(session.previewSource.rawValue)-\(session.cacheGeneration)"

        // Toggle preview source: key must change
        session.togglePreviewSource()
        let key2 = "\(item.id)-\(session.previewSource.rawValue)-\(session.cacheGeneration)"
        #expect(key1 != key2)

        // Clear media cache: cacheGeneration must increment, key must change
        await session.clearMediaCache()
        #expect(session.cacheGeneration == initialGen + 1)
        let key3 = "\(item.id)-\(session.previewSource.rawValue)-\(session.cacheGeneration)"
        #expect(key2 != key3)
    }

    @Test("ContentView and SettingsSheetView support injected session and suppress dismiss button when requested")
    func viewStateAndPresentationContracts() {
        let session = CullingSession()
        let contentView = ContentView(session: session)
        #expect(contentView.session === session)

        let settingsSheetModal = SettingsSheetView(session: session)
        #expect(settingsSheetModal.showsDismissButton == true)

        let settingsScene = SettingsSheetView(session: session, showsDismissButton: false)
        #expect(settingsScene.showsDismissButton == false)
    }

    @Test("Full RAW on-demand loading updates session state without mutating previewSource, and reflects memory cache state accurately")
    func fullRAWLoadingSessionStateAndCacheLifecycle() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let jpgURL = root.appendingPathComponent("DSC0002.JPG")
        let rawURL = root.appendingPathComponent("DSC0002.ARW")

        try createTestJPEG(at: jpgURL, width: 320, height: 240, r: 50, g: 100, b: 150)
        let rawHeaderPrefix = try Data(contentsOf: jpgURL)
        var rawData = rawHeaderPrefix
        rawData.append(Data(repeating: 0xBB, count: 2048))
        try rawData.write(to: rawURL)

        let storeRoot = root.appendingPathComponent(".test-store", isDirectory: true)
        let session = CullingSession(storageRootURL: storeRoot)
        try session.openFolder(at: root)

        let item = try #require(session.items.first)
        #expect(item.hasRAWFile)
        #expect(item.isMediaPair)

        // Initially not loaded and in preferRaster
        #expect(!session.isFullRAWLoaded(for: item))
        #expect(!session.isLoadingFullRAW(for: item))
        #expect(session.previewSource == .preferRaster)

        // Load full RAW
        let fullImage = await session.loadFullRAW(for: item)
        #expect(fullImage != nil)
        #expect(session.isFullRAWLoaded(for: item))
        #expect(session.loadedFullRAWItemIDs.contains(item.id))
        #expect(!session.isLoadingFullRAW(for: item))
        // Calling loadFullRAW does NOT alter the user's global session representation preference
        #expect(session.previewSource == .preferRaster)

        // Repeated load returns cached image immediately
        let cachedImage = await session.loadFullRAW(for: item)
        #expect(cachedImage != nil)
        #expect(session.isFullRAWLoaded(for: item))
        #expect(session.loadedFullRAWItemIDs.contains(item.id))

        // clearMediaCache evicts cache, so isFullRAWLoaded becomes false and permits reload
        await session.clearMediaCache()
        #expect(!session.isFullRAWLoaded(for: item))
        #expect(!session.loadedFullRAWItemIDs.contains(item.id))
    }

    @Test("FilmstripRepresentationControls resolves states accurately across MediaPairs, standalone RAWs, toggles, demosaicing, and cache evictions")
    func filmstripRepresentationControlsStateTransitions() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let jpgURL = root.appendingPathComponent("DSC0002.JPG")
        let rawURL = root.appendingPathComponent("DSC0002.ARW")
        let standaloneRawURL = root.appendingPathComponent("DSC0003.ARW")

        try createTestJPEG(at: jpgURL, width: 320, height: 240, r: 50, g: 100, b: 150)
        let rawHeaderPrefix = try Data(contentsOf: jpgURL)
        var rawData = rawHeaderPrefix
        rawData.append(Data(repeating: 0xBB, count: 2048))
        try rawData.write(to: rawURL)
        try rawData.write(to: standaloneRawURL)

        let storeRoot = root.appendingPathComponent(".test-store", isDirectory: true)
        let session = CullingSession(storageRootURL: storeRoot)
        try session.openFolder(at: root)

        let pairItem = try #require(session.items.first { $0.isMediaPair })
        let standaloneItem = try #require(session.items.first { !$0.isMediaPair && $0.hasRAWFile })

        // 1. MediaPair in .preferRaster -> .raster
        #expect(session.previewSource == .preferRaster)
        #expect(session.previewRepresentation(for: pairItem) == .raster)
        let pairControlsRaster = FilmstripRepresentationControls(item: pairItem, session: session)
        #expect(pairControlsRaster.state == .raster)

        // 2. MediaPair in .preferRAW without full RAW -> .rawPreview
        session.setPreviewSource(.preferRAW)
        #expect(session.previewRepresentation(for: pairItem) == .rawPreview)
        let pairControlsRAWPreview = FilmstripRepresentationControls(item: pairItem, session: session)
        #expect(pairControlsRAWPreview.state == .rawPreview)

        // 3. MediaPair in .preferRAW with full RAW demosaiced -> .fullRAW
        _ = await session.loadFullRAW(for: pairItem)
        #expect(session.previewRepresentation(for: pairItem) == .fullRAW)
        let pairControlsFullRAW = FilmstripRepresentationControls(item: pairItem, session: session)
        #expect(pairControlsFullRAW.state == .fullRAW)

        // 4. MediaPair toggled back to .preferRaster retains raster state even with full RAW cached in memory
        session.setPreviewSource(.preferRaster)
        #expect(session.previewRepresentation(for: pairItem) == .raster)
        let pairControlsBackToRaster = FilmstripRepresentationControls(item: pairItem, session: session)
        #expect(pairControlsBackToRaster.state == .raster)

        // 5. Standalone RAW without full RAW -> .rawPreview
        #expect(session.previewRepresentation(for: standaloneItem) == .rawPreview)
        let standaloneControlsPreview = FilmstripRepresentationControls(item: standaloneItem, session: session)
        #expect(standaloneControlsPreview.state == .rawPreview)

        // 6. Standalone RAW with full RAW demosaiced -> .fullRAW
        _ = await session.loadFullRAW(for: standaloneItem)
        #expect(session.previewRepresentation(for: standaloneItem) == .fullRAW)
        let standaloneControlsFullRAW = FilmstripRepresentationControls(item: standaloneItem, session: session)
        #expect(standaloneControlsFullRAW.state == .fullRAW)

        // 7. Cache eviction resets both items back to .rawPreview (when in RAW mode)
        await session.clearMediaCache()
        session.setPreviewSource(.preferRAW)
        #expect(session.previewRepresentation(for: pairItem) == .rawPreview)
        #expect(session.previewRepresentation(for: standaloneItem) == .rawPreview)
        let pairEvicted = FilmstripRepresentationControls(item: pairItem, session: session)
        #expect(pairEvicted.state == .rawPreview)

        let standaloneEvicted = FilmstripRepresentationControls(item: standaloneItem, session: session)
        #expect(standaloneEvicted.state == .rawPreview)
    }

    @Test("Loading full RAW triggers Observation tracking on previewRepresentation so UI reactively updates to .fullRAW")
    func loadingFullRAWTriggersObservationTracking() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let jpgURL = root.appendingPathComponent("DSC0002.JPG")
        let rawURL = root.appendingPathComponent("DSC0002.ARW")

        try createTestJPEG(at: jpgURL, width: 320, height: 240, r: 50, g: 100, b: 150)
        let rawHeaderPrefix = try Data(contentsOf: jpgURL)
        var rawData = rawHeaderPrefix
        rawData.append(Data(repeating: 0xBB, count: 2048))
        try rawData.write(to: rawURL)

        let storeRoot = root.appendingPathComponent(".test-store", isDirectory: true)
        let session = CullingSession(storageRootURL: storeRoot)
        try session.openFolder(at: root)
        session.setPreviewSource(.preferRAW)

        let item = try #require(session.items.first)

        /// **Concurrency Safety Invariant**:
        /// - Marked `@unchecked Sendable` because it encapsulates synchronous state (`fired`)
        ///   guarded by an internal `NSLock`.
        /// - `withObservationTracking(apply:onChange:)` calls `onChange` when tracked properties change,
        ///   requiring thread-safe mutation across observation contexts.
        ///
        /// **Follow-Up Removal Plan**:
        /// - Migrate to `Mutex<Bool>` when minimum deployment targets include the Swift 6 `Synchronization` library.
        final class ObservationFlag: @unchecked Sendable {
            private let lock = NSLock()
            private var fired = false
            func markFired() { lock.withLock { fired = true } }
            var isFired: Bool { lock.withLock { fired } }
        }

        let observationFlag = ObservationFlag()
        withObservationTracking {
            _ = session.previewRepresentation(for: item)
        } onChange: {
            observationFlag.markFired()
        }

        #expect(!observationFlag.isFired)
        #expect(session.previewRepresentation(for: item) == .rawPreview)

        _ = await session.loadFullRAW(for: item)

        #expect(observationFlag.isFired == true)
        #expect(session.previewRepresentation(for: item) == .fullRAW)

        let evictionFlag = ObservationFlag()
        withObservationTracking {
            _ = session.previewRepresentation(for: item)
        } onChange: {
            evictionFlag.markFired()
        }

        #expect(!evictionFlag.isFired)
        await session.clearMediaCache()

        #expect(evictionFlag.isFired == true)
        #expect(session.previewRepresentation(for: item) == .rawPreview)
    }

    @Test("FullRAWActionButton renders stable Button view across idle and loading states")
    func fullRAWActionButtonViewStructureStability() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let jpgURL = root.appendingPathComponent("DSC0005.JPG")
        let rawURL = root.appendingPathComponent("DSC0005.ARW")

        try createTestJPEG(at: jpgURL, width: 320, height: 240, r: 50, g: 100, b: 150)
        let rawHeaderPrefix = try Data(contentsOf: jpgURL)
        var rawData = rawHeaderPrefix
        rawData.append(Data(repeating: 0xBB, count: 2048))
        try rawData.write(to: rawURL)

        let storeRoot = root.appendingPathComponent(".test-store", isDirectory: true)
        let session = CullingSession(storageRootURL: storeRoot)
        try session.openFolder(at: root)
        session.setPreviewSource(.preferRAW)

        let item = try #require(session.items.first)
        #expect(item.hasRAWFile)
        #expect(!session.isFullRAWLoaded(for: item))
        #expect(!session.isLoadingFullRAW(for: item))

        // 1. Idle state produces non-empty button
        let actionButton = FullRAWActionButton(item: item, session: session)
        #expect(actionButton.item.id == item.id)
        _ = actionButton.body

        // 2. Perform full RAW load on session
        let fullImage = await session.loadFullRAW(for: item)
        #expect(fullImage != nil)
        #expect(session.isFullRAWLoaded(for: item))
        #expect(!session.isLoadingFullRAW(for: item))

        // 3. Loaded state (button disappears from body when full RAW is loaded)
        let loadedButton = FullRAWActionButton(item: item, session: session)
        _ = loadedButton.body
        #expect(session.previewRepresentation(for: item) == .fullRAW)
    }

    // MARK: - Slice 6: FilmstripScrubber Expanding Ribbon Metrics & Playhead Insets (#72)

    @Test("FilmstripScrubber dock span, active/inactive tile sizes, breathing margins, and center playhead insets match spec")
    func filmstripScrubberLayoutMetricsAndPlayheadInsets() {
        // Dock container spans: Bottom = 92pt, Right = 128pt
        #expect(CullingLayoutCalculator.scrubberDockSpan(for: .bottom) == 92.0)
        #expect(CullingLayoutCalculator.scrubberDockSpan(for: .right) == 128.0)
        #expect(CullingLayoutCalculator.scrubberInterTileSpacing == 2.0)
        #expect(CullingLayoutCalculator.scrubberActiveTileBreathingMargin == 8.0)

        // Inactive tiles: 40x72 in bottom dock, 112x44 in right dock
        let inactiveBottom = CullingLayoutCalculator.scrubberTileSize(
            isSelected: false,
            aspectRatio: 1.5,
            dockPosition: .bottom
        )
        #expect(inactiveBottom == CGSize(width: 40.0, height: 72.0))

        let inactiveRight = CullingLayoutCalculator.scrubberTileSize(
            isSelected: false,
            aspectRatio: 1.5,
            dockPosition: .right
        )
        #expect(inactiveRight == CGSize(width: 112.0, height: 44.0))

        // Active center tile: true aspect ratio width (48-128pt x 72pt in bottom, 112pt x 64-150pt in right)
        let activeBottom3x2 = CullingLayoutCalculator.scrubberTileSize(
            isSelected: true,
            aspectRatio: 1.5,
            dockPosition: .bottom
        )
        #expect(activeBottom3x2 == CGSize(width: 108.0, height: 72.0))

        let activeRight3x2 = CullingLayoutCalculator.scrubberTileSize(
            isSelected: true,
            aspectRatio: 1.5,
            dockPosition: .right
        )
        #expect(activeRight3x2 == CGSize(width: 112.0, height: 75.0))

        // Half-viewport inset: max(0, (scrubberSpan - activeTileSpan) / 2)
        #expect(CullingLayoutCalculator.scrubberHalfViewportInset(scrubberSpan: 800.0, activeTileSpan: 108.0) == 346.0)
        #expect(CullingLayoutCalculator.scrubberHalfViewportInset(scrubberSpan: 80.0, activeTileSpan: 108.0) == 0.0)
    }

    // MARK: - Slice 7: True Fitted Aspect-Rect Panning, Edge-Pan Handoff & Point-Anchored Double-Tap Zoom (#72)

    @Test("Zoomed panning clamps to actual fitted aspect rect rather than container bounds and hands off horizontal overflow into paging")
    func fittedAspectRectPanClampingAndContinuousEdgePanHandoff() {
        let containerSize = CGSize(width: 1000.0, height: 600.0)

        // 2:3 portrait image inside 1000x600 container fits to 400x600 (pillarboxed with 300pt bars on each side)
        let fittedPortrait = CullingLayoutCalculator.fittedImageSize(
            aspectRatio: 2.0 / 3.0,
            in: containerSize
        )
        #expect( abs(fittedPortrait.width - 400.0) < 0.5 )
        #expect( abs(fittedPortrait.height - 600.0) < 0.5 )

        // At 2.0x scale, maxPanX is clamped to fitted width (400 * (2 - 1) / 2 = 200pt), NOT container width (500pt)
        let maxPan = CullingLayoutCalculator.maxPanOffset(fittedSize: fittedPortrait, scale: 2.0)
        #expect( abs(maxPan.width - 200.0) < 0.5 )
        #expect( abs(maxPan.height - 300.0) < 0.5 )

        // Dragging within fitted pan bounds (-150pt) stays 100% in panOffset with 0 pageDragOffset
        let insideResult = CullingLayoutCalculator.resolveZoomPanAndPageHandoff(
            currentPanOffset: .zero,
            dragTranslation: CGSize(width: -150.0, height: 100.0),
            fittedSize: fittedPortrait,
            scale: 2.0,
            hasPrevious: true,
            hasNext: true
        )
        #expect( abs(insideResult.clampedPanOffset.width - (-150.0)) < 0.5 )
        #expect( abs(insideResult.clampedPanOffset.height - 100.0) < 0.5 )
        #expect( insideResult.pageDragOffset == 0.0 )

        // Dragging past the right image edge (-260pt total when maxPan.width is 200pt) clamps pan at -200pt and hands off -60pt to pageDragOffset
        let handoffNext = CullingLayoutCalculator.resolveZoomPanAndPageHandoff(
            currentPanOffset: CGSize(width: -180.0, height: 0.0),
            dragTranslation: CGSize(width: -80.0, height: 0.0),
            fittedSize: fittedPortrait,
            scale: 2.0,
            hasPrevious: true,
            hasNext: true
        )
        #expect( abs(handoffNext.clampedPanOffset.width - (-200.0)) < 0.5 )
        #expect( abs(handoffNext.pageDragOffset - (-60.0)) < 0.5 )

        // At the last item (hasNext == false), dragging past the right edge applies rubber-band resistance (< 60pt magnitude)
        let rubberBandEnd = CullingLayoutCalculator.resolveZoomPanAndPageHandoff(
            currentPanOffset: CGSize(width: -200.0, height: 0.0),
            dragTranslation: CGSize(width: -100.0, height: 0.0),
            fittedSize: fittedPortrait,
            scale: 2.0,
            hasPrevious: true,
            hasNext: false
        )
        #expect( abs(rubberBandEnd.clampedPanOffset.width - (-200.0)) < 0.5 )
        #expect( rubberBandEnd.pageDragOffset < 0.0 && rubberBandEnd.pageDragOffset > -100.0 )
    }

    @Test("Double-tap zoom toggles between 1.0x and 2.5x anchored to the tapped point within fitted bounds")
    func pointAnchoredDoubleTapZoomCalculation() {
        let containerSize = CGSize(width: 1000.0, height: 800.0)
        let fittedSize = CGSize(width: 800.0, height: 600.0)

        // Double-tapping at top-left quadrant (300, 250) from 1.0x zooms to 2.5x and shifts pan toward (+300, +225)
        let zoomIn = CullingLayoutCalculator.resolveDoubleTapZoom(
            currentScale: 1.0,
            tapLocation: CGPoint(x: 300.0, y: 250.0),
            containerSize: containerSize,
            fittedSize: fittedSize
        )
        #expect(zoomIn.scale == 2.5)
        #expect(zoomIn.panOffset == CGSize(width: 300.0, height: 225.0))

        // Double-tapping while zoomed in (> 1.0x) resets to 1.0x and .zero panOffset
        let zoomOut = CullingLayoutCalculator.resolveDoubleTapZoom(
            currentScale: 2.5,
            tapLocation: CGPoint(x: 300.0, y: 250.0),
            containerSize: containerSize,
            fittedSize: fittedSize
        )
        #expect(zoomOut.scale == 1.0)
        #expect(zoomOut.panOffset == .zero)
    }

    // MARK: - Slice 8: Velocity-Throttled Scrubbing & Vertical Pull-to-Grid Configuration (#72)

    @Test("allowVerticalPullToGridInSwipeMode configuration flag controls 1-finger vertical pull-to-Grid in SwipeMode")
    func verticalPullToGridConfigurationInSwipeMode() {
        let session = CullingSession()

        // Default: SwipeMode is off, allowVerticalPullToGridInSwipeMode is false -> pull-to-Grid is allowed
        #expect(session.isSwipeModeEnabled == false)
        #expect(session.allowVerticalPullToGridInSwipeMode == false)
        #expect(session.isVerticalPullToGridAllowed == true)

        // Enable SwipeMode -> 1-finger vertical pull-to-Grid is disabled by default
        session.setSwipeMode(true)
        #expect(session.isVerticalPullToGridAllowed == false)

        // Enable allowVerticalPullToGridInSwipeMode -> 1-finger vertical pull-to-Grid is allowed even in SwipeMode
        session.allowVerticalPullToGridInSwipeMode = true
        #expect(session.interactionController.allowVerticalPullToGridInSwipeMode == true)
        #expect(session.isVerticalPullToGridAllowed == true)
    }

    @Test("High-velocity scrubbing suppresses full-resolution preview decodes until velocity drops or scrubbing settles")
    func velocityThrottledScrubbingSuppressesFullDecodeUntilSettled() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let img1URL = root.appendingPathComponent("IMG001.JPG")
        let img2URL = root.appendingPathComponent("IMG002.JPG")
        try createTestJPEG(at: img1URL, width: 640, height: 480, r: 120, g: 80, b: 200)
        try createTestJPEG(at: img2URL, width: 640, height: 480, r: 200, g: 120, b: 80)

        let storeRoot = root.appendingPathComponent(".test-store", isDirectory: true)
        let session = CullingSession(storageRootURL: storeRoot)
        try session.openFolder(at: root)

        let item1 = session.items[0]
        let item2 = session.items[1]

        // Warm thumbnail for item2 so it's available in memory during fast scrubbing
        let thumb2 = await session.loadThumbnailImage(for: item2, maxPixelSize: 360)
        #expect(thumb2 != nil)
        #expect(session.inMemoryThumbnailImage(for: item2, maxPixelSize: 360) != nil)
        #expect(session.inMemoryPreviewImage(for: item2, maxPixelSize: 2048) == nil)

        // Begin high-velocity scrubbing
        session.updateScrubState(isScrubbing: true, velocityPointsPerSecond: 1200.0)
        #expect(session.isScrubbing == true)
        #expect(session.isHighVelocityScrubbing == true)

        // Selecting item2 updates selection immediately, but loadPreviewImage is suppressed while high-velocity scrubbing
        session.selectedItemID = item2.id
        #expect(session.selectedItem?.id == item2.id)
        let suppressedPreview = await session.loadPreviewImage(for: item2, maxPixelSize: 2048)
        #expect(suppressedPreview == nil)
        #expect(session.inMemoryThumbnailImage(for: item2, maxPixelSize: 360) != nil)

        // Once scrub velocity drops below threshold / settles to idle, full-resolution preview decode succeeds
        session.updateScrubState(isScrubbing: false, velocityPointsPerSecond: 0.0)
        #expect(session.isScrubbing == false)
        #expect(session.isHighVelocityScrubbing == false)

        let settledPreview = await session.loadPreviewImage(for: item2, maxPixelSize: 2048)
        #expect(settledPreview != nil)
        #expect(session.inMemoryPreviewImage(for: item2, maxPixelSize: 2048) != nil)
        _ = item1
    }

    // MARK: - Slice 9: 3-Page Carousel Neighbors, Stationary HUD Midpoint & Scrubber Interpolation (#72)

    @Test("Adjacent items in CullingSequence and stationary HUD midpoint switching resolve previous, current, and next items")
    func threePageCarouselAdjacentItemsAndHUDMidpointResolution() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        for i in 1...3 {
            let url = root.appendingPathComponent("IMG00\(i).JPG")
            try createTestJPEG(at: url, width: 320, height: 240)
        }

        let storeRoot = root.appendingPathComponent(".test-store", isDirectory: true)
        let session = CullingSession(storageRootURL: storeRoot)
        try session.openFolder(at: root)

        let item0 = session.items[0]
        let item1 = session.items[1]
        let item2 = session.items[2]

        // At item0: previous is nil, current is item0, next is item1
        session.selectedItemID = item0.id
        let adj0 = session.adjacentItems(for: item0.id)
        #expect(adj0.previous == nil)
        #expect(adj0.current?.id == item0.id)
        #expect(adj0.next?.id == item1.id)

        // At item1: previous is item0, current is item1, next is item2
        session.selectedItemID = item1.id
        let adj1 = session.adjacentItems(for: item1.id)
        #expect(adj1.previous?.id == item0.id)
        #expect(adj1.current?.id == item1.id)
        #expect(adj1.next?.id == item2.id)

        // Stationary HUD item stays on item1 before midpoint, and switches to item2 or item0 past midpoint (width = 1000 -> midpoint = 500)
        #expect(session.displayedHUDItem(pageDragOffset: -200.0, containerWidth: 1000.0)?.id == item1.id)
        #expect(session.displayedHUDItem(pageDragOffset: -550.0, containerWidth: 1000.0)?.id == item2.id)
        #expect(session.displayedHUDItem(pageDragOffset: 550.0, containerWidth: 1000.0)?.id == item0.id)

        // Scrubber playhead interpolation offset scales continuously with main-canvas swipe progress
        let interpZero = CullingLayoutCalculator.scrubberDragInterpolationOffset(
            pageDragOffset: 0.0,
            pageStride: 1016.0,
            activeTileSpan: 108.0,
            dockPosition: .bottom
        )
        #expect(interpZero == 0.0)

        let interpHalfNext = CullingLayoutCalculator.scrubberDragInterpolationOffset(
            pageDragOffset: -508.0,
            pageStride: 1016.0,
            activeTileSpan: 108.0,
            dockPosition: .bottom
        )
        // Expected full step in bottom dock = (108 / 2) + 8 (margin) + 2 (spacing) + (40 / 2) = 84pt; half step = -42pt
        #expect(abs(interpHalfNext - (-42.0)) < 0.5)
    }

    // MARK: - Slice 10: Interactive Hero Transition to Grid Choreography & Thresholds (#72)

    @Test("Hero transition to Grid computes chrome fade, finger-tracked scale/offset toward target Grid cell, and commit thresholds")
    func interactiveHeroTransitionToGridChoreographyAndThresholds() {
        let canvasRect = CGRect(x: 0.0, y: 0.0, width: 1000.0, height: 800.0)
        let targetCellRect = CGRect(x: 120.0, y: 240.0, width: 200.0, height: 150.0)

        // 1. Pinching below 1.0x (e.g., 0.85x) enters interactive transition but does NOT commit on release without velocity
        let partialPinch = CullingLayoutCalculator.resolveHeroGridTransition(
            rawScale: 0.85,
            dragTranslation: .zero,
            predictedEndTranslation: .zero,
            canvasRect: canvasRect,
            targetGridCellRect: targetCellRect,
            isVerticalPullAllowed: true
        )
        #expect(partialPinch.isActive == true)
        #expect(partialPinch.progress > 0.0 && partialPinch.progress < 1.0)
        #expect(partialPinch.chromeOpacity < 1.0 && partialPinch.chromeOpacity > 0.0)
        #expect(partialPinch.backdropOpacity < 0.92 && partialPinch.backdropOpacity > 0.0)
        #expect(partialPinch.shouldCommit == false)

        // 2. Pinching below ~0.75x threshold (e.g., 0.70x) commits to Grid on release
        let commitPinch = CullingLayoutCalculator.resolveHeroGridTransition(
            rawScale: 0.70,
            dragTranslation: CGSize(width: -40.0, height: 30.0),
            predictedEndTranslation: CGSize(width: -40.0, height: 30.0),
            canvasRect: canvasRect,
            targetGridCellRect: targetCellRect,
            isVerticalPullAllowed: true
        )
        #expect(commitPinch.isActive == true)
        #expect(commitPinch.shouldCommit == true)

        // 3. 1-finger vertical pull-down at 1.0x when allowed enters transition and commits past threshold
        let commitVerticalPull = CullingLayoutCalculator.resolveHeroGridTransition(
            rawScale: 1.0,
            dragTranslation: CGSize(width: 10.0, height: 140.0),
            predictedEndTranslation: CGSize(width: 15.0, height: 220.0),
            canvasRect: canvasRect,
            targetGridCellRect: targetCellRect,
            isVerticalPullAllowed: true
        )
        #expect(commitVerticalPull.isActive == true)
        #expect(commitVerticalPull.shouldCommit == true)
        #expect(commitVerticalPull.interactiveScale < 1.0)

        // 4. 1-finger vertical pull-down at 1.0x when isVerticalPullAllowed == false (SwipeMode default) does NOT activate
        let disallowedVerticalPull = CullingLayoutCalculator.resolveHeroGridTransition(
            rawScale: 1.0,
            dragTranslation: CGSize(width: 10.0, height: 140.0),
            predictedEndTranslation: CGSize(width: 15.0, height: 220.0),
            canvasRect: canvasRect,
            targetGridCellRect: targetCellRect,
            isVerticalPullAllowed: false
        )
        #expect(disallowedVerticalPull.isActive == false)
        #expect(disallowedVerticalPull.shouldCommit == false)
    }

    // MARK: - Slice 11: Immediate Selection on Page Turn & Rapid Consecutive Swipes (#74 / #77)

    @Test("Compensated page drag offset preserves seamless on-screen visual positions during immediate page turn commits")
    func compensatedPageDragOffsetMaintainsVisualPositions() {
        let containerWidth: CGFloat = 1000.0
        let pageStride = containerWidth + CullingLayoutCalculator.filmstripInterPageGutter // 1016.0

        // 1. Committing .next at mid-drag (-240pt):
        // Incoming item was at: pageStride + (-240) = 776pt
        // Compensated offset for .next becomes: -240 + pageStride = +776pt
        let dragOffsetNext: CGFloat = -240.0
        let visualPosNextBefore = pageStride + dragOffsetNext // 776.0
        let compensatedNext = CullingLayoutCalculator.compensatedPageDragOffset(
            currentOffset: dragOffsetNext,
            direction: .next,
            pageStride: pageStride
        )
        #expect(compensatedNext == visualPosNextBefore)
        #expect(compensatedNext == 776.0)

        // The outgoing item (now previous) is at: -pageStride + compensatedNext = -1016 + 776 = -240pt (identical to old position)
        let outgoingPosAfterNext = -pageStride + compensatedNext
        #expect(outgoingPosAfterNext == dragOffsetNext)

        // 2. Committing .previous at mid-drag (+240pt):
        // Incoming item was at: -pageStride + (+240) = -776pt
        // Compensated offset for .previous becomes: +240 - pageStride = -776pt
        let dragOffsetPrev: CGFloat = 240.0
        let visualPosPrevBefore = -pageStride + dragOffsetPrev // -776.0
        let compensatedPrev = CullingLayoutCalculator.compensatedPageDragOffset(
            currentOffset: dragOffsetPrev,
            direction: .previous,
            pageStride: pageStride
        )
        #expect(compensatedPrev == visualPosPrevBefore)
        #expect(compensatedPrev == -776.0)

        // The outgoing item (now next) is at: +pageStride + compensatedPrev = 1016 - 776 = +240pt (identical to old position)
        let outgoingPosAfterPrev = pageStride + compensatedPrev
        #expect(outgoingPosAfterPrev == dragOffsetPrev)
    }

    @Test("Rapid consecutive page turns immediately update selection and resolve next neighbors without wedging")
    func rapidConsecutivePageTurnsImmediatelyAdvanceSelection() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        for i in 1...5 {
            let url = root.appendingPathComponent("IMG00\(i).JPG")
            try createTestJPEG(at: url, width: 320, height: 240)
        }

        let storeRoot = root.appendingPathComponent(".test-store", isDirectory: true)
        let session = CullingSession(storageRootURL: storeRoot)
        try session.openFolder(at: root)

        #expect(session.items.count == 5)
        let item0 = session.items[0]
        let item1 = session.items[1]
        let item2 = session.items[2]
        let item3 = session.items[3]

        session.selectedItemID = item0.id

        // First rapid swipe right-to-left: commits .next
        var neighbors = session.adjacentItems(for: session.selectedItemID!)
        #expect(neighbors.current?.id == item0.id)
        #expect(neighbors.next?.id == item1.id)

        // Simulated immediate commit: advances selection instantly to item1
        session.selectedItemID = neighbors.next?.id
        #expect(session.selectedItemID == item1.id)

        // Second rapid swipe immediately commits .next again without waiting:
        neighbors = session.adjacentItems(for: session.selectedItemID!)
        #expect(neighbors.previous?.id == item0.id)
        #expect(neighbors.current?.id == item1.id)
        #expect(neighbors.next?.id == item2.id)

        session.selectedItemID = neighbors.next?.id
        #expect(session.selectedItemID == item2.id)

        // Third rapid swipe immediately commits .next again:
        neighbors = session.adjacentItems(for: session.selectedItemID!)
        #expect(neighbors.previous?.id == item1.id)
        #expect(neighbors.current?.id == item2.id)
        #expect(neighbors.next?.id == item3.id)

        session.selectedItemID = neighbors.next?.id
        #expect(session.selectedItemID == item3.id)
    }

    // MARK: - Slice 12: Scrubber Playhead Centering & Unidirectional Synchronization (#74 / #78)

    @Test("FilmstripScrubber playhead centering calculations accurately align active tile center across iPad dock orientations and aspect ratios")
    func filmstripScrubberPlayheadCenteringCalculationsAcrossDocksAndAspectRatios() {
        // Test various iPad viewports (iPad 11": 834pt, iPad 13": 1024pt, Split View: 504pt, 375pt)
        let ipadSpans: [CGFloat] = [375.0, 504.0, 834.0, 1024.0, 1366.0]
        let aspectRatios: [CGFloat] = [1.5, 1.777, 1.0, 0.667, 0.5625]

        for span in ipadSpans {
            for ratio in aspectRatios {
                // Bottom dock
                let activeSizeBottom = CullingLayoutCalculator.scrubberTileSize(
                    isSelected: true,
                    aspectRatio: ratio,
                    dockPosition: .bottom
                )
                let activeSlotSpanBottom = activeSizeBottom.width + CullingLayoutCalculator.scrubberActiveTileBreathingMargin * 2.0
                let insetBottom = CullingLayoutCalculator.scrubberHalfViewportInset(
                    scrubberSpan: span,
                    activeTileSpan: activeSlotSpanBottom
                )
                if span >= activeSlotSpanBottom {
                    let tileCenter = insetBottom + (activeSlotSpanBottom / 2.0)
                    let viewportCenter = span / 2.0
                    #expect(abs(tileCenter - viewportCenter) < 0.001)
                }

                // Right dock
                let activeSizeRight = CullingLayoutCalculator.scrubberTileSize(
                    isSelected: true,
                    aspectRatio: ratio,
                    dockPosition: .right
                )
                let activeSlotSpanRight = activeSizeRight.height + CullingLayoutCalculator.scrubberActiveTileBreathingMargin * 2.0
                let insetRight = CullingLayoutCalculator.scrubberHalfViewportInset(
                    scrubberSpan: span,
                    activeTileSpan: activeSlotSpanRight
                )
                if span >= activeSlotSpanRight {
                    let tileCenter = insetRight + (activeSlotSpanRight / 2.0)
                    let viewportCenter = span / 2.0
                    #expect(abs(tileCenter - viewportCenter) < 0.001)
                }
            }
        }
    }

    @Test("Scrubber selection synchronization only mutates session selection during active user interaction")
    func scrubberSelectionSynchronizationGatedOnUserInteraction() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        for i in 1...4 {
            let url = root.appendingPathComponent("IMG00\(i).JPG")
            try createTestJPEG(at: url, width: 320, height: 240)
        }

        let storeRoot = root.appendingPathComponent(".test-store", isDirectory: true)
        let session = CullingSession(storageRootURL: storeRoot)
        try session.openFolder(at: root)

        let item0 = session.items[0]
        let item1 = session.items[1]
        let item2 = session.items[2]
        session.selectedItemID = item0.id

        // 1. Programmatic jump or main-canvas swipe offset shifts ($scrubbedItemID changes while isUserScrolling == false):
        // Must NOT overwrite session.selectedItemID
        let nonUserChange = CullingLayoutCalculator.shouldApplyScrubberSelection(
            newID: item1.id,
            currentSelectedID: item0.id,
            isUserScrolling: false,
            isScrubbing: false,
            isProgrammaticJump: false
        )
        #expect(nonUserChange == false)

        // 2. Programmatic scroll in-flight:
        let programmaticChange = CullingLayoutCalculator.shouldApplyScrubberSelection(
            newID: item2.id,
            currentSelectedID: item0.id,
            isUserScrolling: false,
            isScrubbing: false,
            isProgrammaticJump: true
        )
        #expect(programmaticChange == false)

        // 3. Active user scrubbing on scrubber ribbon:
        let userScrubChange = CullingLayoutCalculator.shouldApplyScrubberSelection(
            newID: item1.id,
            currentSelectedID: item0.id,
            isUserScrolling: true,
            isScrubbing: true,
            isProgrammaticJump: false
        )
        #expect(userScrubChange == true)
    }

    @Test("Async aspect ratio loads keep inactive scrubber tiles stable while selected tile dynamically sizes")
    func asyncAspectRatioStabilityPreservesInactiveTileDimensions() {
        // Inactive tiles must always retain stable fixed dimensions (40x72 bottom dock, 112x44 right dock)
        // regardless of whether their aspect ratio is nil (unloaded), 1.0 (square), 1.5 (3:2), or 0.667 (portrait),
        // preventing neighbor tiles from sliding during background thumbnail hydration.
        let testAspectRatios: [CGFloat?] = [nil, 0.5625, 0.667, 1.0, 1.5, 1.777]

        for ratio in testAspectRatios {
            let inactiveSizeBottom = CullingLayoutCalculator.scrubberTileSize(
                isSelected: false,
                aspectRatio: ratio,
                dockPosition: .bottom
            )
            #expect(inactiveSizeBottom.width == 40.0)
            #expect(inactiveSizeBottom.height == 72.0)

            let inactiveSizeRight = CullingLayoutCalculator.scrubberTileSize(
                isSelected: false,
                aspectRatio: ratio,
                dockPosition: .right
            )
            #expect(inactiveSizeRight.width == 112.0)
            #expect(inactiveSizeRight.height == 44.0)
        }

        // When selected, the active tile dynamically sizes to true aspect ratio:
        let selectedLandscapeBottom = CullingLayoutCalculator.scrubberTileSize(
            isSelected: true,
            aspectRatio: 1.5,
            dockPosition: .bottom
        )
        #expect(selectedLandscapeBottom.width == 108.0)
        #expect(selectedLandscapeBottom.height == 72.0)

        let selectedPortraitBottom = CullingLayoutCalculator.scrubberTileSize(
            isSelected: true,
            aspectRatio: 0.667,
            dockPosition: .bottom
        )
        #expect(abs(selectedPortraitBottom.width - 48.0) < 0.1)
        #expect(selectedPortraitBottom.height == 72.0)
    }
}



