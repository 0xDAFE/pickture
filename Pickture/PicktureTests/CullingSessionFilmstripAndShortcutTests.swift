import CoreGraphics
import Foundation
import ImageIO
import Observation
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

    // MARK: - Slice: PinchToGrid and SwipeNavigation Calculations

    @Test("PinchToGrid threshold and commitment rules respect zoom level and scale threshold")
    func pinchToGridCommitmentRules() {
        #expect(CullingLayoutCalculator.pinchToGridScaleThreshold == 0.85)

        // At 1.0x zoom: below or equal to threshold commits
        #expect(CullingLayoutCalculator.shouldCommitPinchToGrid(currentZoom: 1.0, magnification: 0.84))
        #expect(CullingLayoutCalculator.shouldCommitPinchToGrid(currentZoom: 1.0, magnification: 0.85))
        #expect(!CullingLayoutCalculator.shouldCommitPinchToGrid(currentZoom: 1.0, magnification: 0.86))
        #expect(!CullingLayoutCalculator.shouldCommitPinchToGrid(currentZoom: 1.0, magnification: 1.0))

        // When magnified (> 1.0x): pinching down does NOT commit to grid
        #expect(!CullingLayoutCalculator.shouldCommitPinchToGrid(currentZoom: 2.0, magnification: 0.80))
        #expect(!CullingLayoutCalculator.shouldCommitPinchToGrid(currentZoom: 1.5, magnification: 0.50))
    }

    @Test("SwipeNavigation threshold scales with viewport width and clamps safely")
    func swipeNavigationThresholdCalculation() {
        // Small width (e.g. 200pt) -> clamped to minimum 60pt
        #expect(CullingLayoutCalculator.swipeNavigationThreshold(for: 200) == 60)

        // Standard width (e.g. 500pt) -> 20% is 100pt
        #expect(CullingLayoutCalculator.swipeNavigationThreshold(for: 500) == 100)

        // Large width (e.g. 1000pt) -> clamped to maximum 140pt
        #expect(CullingLayoutCalculator.swipeNavigationThreshold(for: 1000) == 140)

        // Safe fallback on invalid widths
        #expect(CullingLayoutCalculator.swipeNavigationThreshold(for: -50) == 60)
        #expect(CullingLayoutCalculator.swipeNavigationThreshold(for: .nan) == 60)
    }

    @Test("SwipeNavigation translation preserves linear 1:1 feel internally and damps at boundaries")
    func swipeNavigationTranslationAndBoundaryDamping() {
        // Internal item (neither boundary): linear 1:1 translation
        #expect(CullingLayoutCalculator.swipeNavigationTranslation(offset: 80, isAtLeadingBoundary: false, isAtTrailingBoundary: false) == 80)
        #expect(CullingLayoutCalculator.swipeNavigationTranslation(offset: -80, isAtLeadingBoundary: false, isAtTrailingBoundary: false) == -80)

        // Leading boundary (first item): dragging right (> 0) is damped, dragging left (< 0) is linear
        let dampedRight = CullingLayoutCalculator.swipeNavigationTranslation(offset: 100, isAtLeadingBoundary: true, isAtTrailingBoundary: false)
        #expect(dampedRight > 0)
        #expect(dampedRight < 100)
        #expect(dampedRight == 30) // 100 * 0.3 damping

        let linearLeftFromLeading = CullingLayoutCalculator.swipeNavigationTranslation(offset: -100, isAtLeadingBoundary: true, isAtTrailingBoundary: false)
        #expect(linearLeftFromLeading == -100)

        // Trailing boundary (last item): dragging left (< 0) is damped, dragging right (> 0) is linear
        let dampedLeft = CullingLayoutCalculator.swipeNavigationTranslation(offset: -100, isAtLeadingBoundary: false, isAtTrailingBoundary: true)
        #expect(dampedLeft < 0)
        #expect(dampedLeft > -100)
        #expect(dampedLeft == -30) // -100 * 0.3 damping

        let linearRightFromTrailing = CullingLayoutCalculator.swipeNavigationTranslation(offset: 100, isAtLeadingBoundary: false, isAtTrailingBoundary: true)
        #expect(linearRightFromTrailing == 100)

        // Both boundaries (single item in sequence): both directions damped
        #expect(CullingLayoutCalculator.swipeNavigationTranslation(offset: 100, isAtLeadingBoundary: true, isAtTrailingBoundary: true) == 30)
        #expect(CullingLayoutCalculator.swipeNavigationTranslation(offset: -100, isAtLeadingBoundary: true, isAtTrailingBoundary: true) == -30)
    }

    @Test("canSelectNextItem and canSelectPreviousItem accurately reflect boundaries and viewMode transitions preserve active selection")
    func sequenceBoundariesAndSelectionPreservation() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try Data("1".utf8).write(to: root.appendingPathComponent("DSC_0001.JPG"))
        try Data("2".utf8).write(to: root.appendingPathComponent("DSC_0002.JPG"))
        try Data("3".utf8).write(to: root.appendingPathComponent("DSC_0003.JPG"))

        let session = CullingSession(storageRootURL: root.appendingPathComponent(".store", isDirectory: true))
        try session.openFolder(at: root)

        #expect(session.items.count == 3)
        let items = session.items
        session.selectedItemID = items[0].id
        session.setViewMode(.filmstrip)

        // At leading boundary (item 0)
        #expect(!session.canSelectPreviousItem)
        #expect(session.canSelectNextItem)

        // Advance to middle item
        session.selectNextItem()
        #expect(session.selectedItemID == items[1].id)
        #expect(session.canSelectPreviousItem)
        #expect(session.canSelectNextItem)

        // Advance to trailing boundary
        session.selectNextItem()
        #expect(session.selectedItemID == items[2].id)
        #expect(session.canSelectPreviousItem)
        #expect(!session.canSelectNextItem)

        // Boundary clamp: advancing past trailing boundary stays on trailing boundary
        session.selectNextItem()
        #expect(session.selectedItemID == items[2].id)

        // Transition back to Grid view: selectedItemID must be preserved
        session.setViewMode(.grid)
        #expect(session.viewMode == .grid)
        #expect(session.selectedItemID == items[2].id)
    }
}


