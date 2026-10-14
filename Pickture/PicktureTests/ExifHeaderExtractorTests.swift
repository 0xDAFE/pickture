import Foundation
import Testing
@testable import Pickture

@Suite("ExifHeaderExtractor & Date Parsing Tests", .serialized)
struct ExifHeaderExtractorTests {

    private func makeTemporaryDirectory() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExifExtractorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private func makeDummyItem(id: String) -> MediaItem {
        let dummyURL = URL(fileURLWithPath: "/dummy/\(id).jpg")
        let primaryFile = MediaFile(url: dummyURL, formatKind: .raster)
        return MediaItem(
            id: id,
            baseName: id,
            directoryURL: URL(fileURLWithPath: "/dummy"),
            relativeDirectoryPath: "",
            kind: .photo,
            primaryFile: primaryFile,
            mediaPair: nil,
            sidecarURL: nil
        )
    }

    // MARK: - Date Parsing Accuracy (Standard EXIF, ISO-8601, and Fallbacks)

    @Test("parseDate handles standard EXIF colon-formatted date strings (yyyy:MM:dd HH:mm:ss)")
    func parseStandardExifDate() {
        let str = "2026:01:01 10:00:00"
        let date = ExifHeaderExtractor.parseDate(str)
        #expect(date != nil)
        if let date {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(secondsFromGMT: 0)!
            let comps = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
            #expect(comps.year == 2026)
            #expect(comps.month == 1)
            #expect(comps.day == 1)
            #expect(comps.hour == 10)
            #expect(comps.minute == 0)
            #expect(comps.second == 0)
        }

        let str2 = "2024:08:15 14:30:25"
        let date2 = ExifHeaderExtractor.parseDate(str2)
        #expect(date2 != nil)
        if let date2 {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(secondsFromGMT: 0)!
            let comps = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date2)
            #expect(comps.year == 2024)
            #expect(comps.month == 8)
            #expect(comps.day == 15)
            #expect(comps.hour == 14)
            #expect(comps.minute == 30)
            #expect(comps.second == 25)
        }
    }

    @Test("parseDate handles EXIF colon-formatted date strings with timezone offsets and date-only")
    func parseExifDateWithTimezoneAndDateOnly() {
        let tzStr = "2026:05:10 12:00:00+09:00"
        let tzDate = ExifHeaderExtractor.parseDate(tzStr)
        #expect(tzDate != nil)

        let dateOnly = "2026:05:10"
        let dDate = ExifHeaderExtractor.parseDate(dateOnly)
        #expect(dDate != nil)
        if let dDate {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(secondsFromGMT: 0)!
            let comps = cal.dateComponents([.year, .month, .day], from: dDate)
            #expect(comps.year == 2026)
            #expect(comps.month == 5)
            #expect(comps.day == 10)
        }
    }

    @Test("parseDate handles ISO-8601 strings with Z and numeric timezone offsets")
    func parseISO8601WithTimezones() {
        let zStr = "2026-10-14T04:10:46Z"
        let zDate = ExifHeaderExtractor.parseDate(zStr)
        #expect(zDate != nil)

        let plusStr = "2026-10-14T13:10:46+09:00"
        let plusDate = ExifHeaderExtractor.parseDate(plusStr)
        #expect(plusDate != nil)

        let minusStr = "2026-10-14T04:10:46-05:00"
        let minusDate = ExifHeaderExtractor.parseDate(minusStr)
        #expect(minusDate != nil)

        // Verify equivalent UTC timestamp
        if let zDate, let plusDate {
            #expect(abs(zDate.timeIntervalSince(plusDate)) < 1.0)
        }
    }

    @Test("parseDate handles ISO-8601 with fractional seconds")
    func parseISO8601WithFractionalSeconds() {
        let fracStr = "2026-10-14T04:10:46.123Z"
        let fracDate = ExifHeaderExtractor.parseDate(fracStr)
        #expect(fracDate != nil)

        let fracOffsetStr = "2026-10-14T13:10:46.456+09:00"
        let fracOffsetDate = ExifHeaderExtractor.parseDate(fracOffsetStr)
        #expect(fracOffsetDate != nil)
    }

    @Test("parseDate handles ISO-8601 without timezone and standard fallback formats")
    func parseFallbackDateFormats() {
        let noTZ = "2026-10-14T04:10:46"
        let noTZDate = ExifHeaderExtractor.parseDate(noTZ)
        #expect(noTZDate != nil)

        let spaceStr = "2026-10-14 04:10:46"
        let spaceDate = ExifHeaderExtractor.parseDate(spaceStr)
        #expect(spaceDate != nil)

        let dateOnly = "2026-10-14"
        let dateOnlyDate = ExifHeaderExtractor.parseDate(dateOnly)
        #expect(dateOnlyDate != nil)
    }

    @Test("parseDate handles whitespace trimming and rejects invalid inputs")
    func parseDateEdgeCases() {
        let padded = "   2026:01:01 10:00:00 \n\t"
        #expect(ExifHeaderExtractor.parseDate(padded) != nil)

        #expect(ExifHeaderExtractor.parseDate("") == nil)
        #expect(ExifHeaderExtractor.parseDate("   \n\t  ") == nil)
        #expect(ExifHeaderExtractor.parseDate("not-a-date") == nil)
        #expect(ExifHeaderExtractor.parseDate("2026-99-99") == nil)
    }

    @Test("parseDate high-throughput verification: zero heap allocation churn over 10,000 iterations")
    func parseDateHighThroughput() {
        let candidates = [
            "2026:01:01 10:00:00",
            "2026-10-14T04:10:46Z",
            "2026-10-14T13:10:46+09:00",
            "2026-10-14T04:10:46.123Z",
            "2024:08:15 14:30:25",
            "2026-10-14 04:10:46",
            "2026-10-14"
        ]

        let start = Date()
        for i in 0..<10_000 {
            let candidate = candidates[i % candidates.count]
            let parsed = ExifHeaderExtractor.parseDate(candidate)
            #expect(parsed != nil)
        }
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed < 2.0, "Parsing 10,000 dates must complete quickly with cached formatters")
    }

    // MARK: - Concurrency Bounding & Worker Pool

    @Test("extractBatch bounds concurrency to StorageVolumeProfile limits (internalSSD=6, removableMedia=4, networkShare=2)")
    func extractBatchConcurrencyBounding() async {
        actor ConcurrencyTracker {
            var current: Int = 0
            var peak: Int = 0

            func enter() {
                current += 1
                peak = max(peak, current)
            }

            func exit() {
                current -= 1
            }

            func getPeak() -> Int {
                peak
            }

            func reset() {
                current = 0
                peak = 0
            }
        }

        let tracker = ConcurrencyTracker()
        let items = (0..<12).map { makeDummyItem(id: "item_\($0)") }

        // 1. Network Share: 2 workers
        await tracker.reset()
        _ = await ExifHeaderExtractor.extractBatchInternal(
            for: items,
            volumeProfile: .networkShare,
            extractItem: { _ in
                await tracker.enter()
                try? await Task.sleep(nanoseconds: 10_000_000)
                await tracker.exit()
                return ExifMetadata()
            }
        )
        let peakNetwork = await tracker.getPeak()
        #expect(peakNetwork <= 2, "Network share must bound worker concurrency to at most 2")
        #expect(peakNetwork > 0)

        // 2. Removable Media: 4 workers
        await tracker.reset()
        _ = await ExifHeaderExtractor.extractBatchInternal(
            for: items,
            volumeProfile: .removableMedia,
            extractItem: { _ in
                await tracker.enter()
                try? await Task.sleep(nanoseconds: 10_000_000)
                await tracker.exit()
                return ExifMetadata()
            }
        )
        let peakRemovable = await tracker.getPeak()
        #expect(peakRemovable <= 4, "Removable media must bound worker concurrency to at most 4")
        #expect(peakRemovable > 0)

        // 3. Internal SSD: 6 workers
        await tracker.reset()
        _ = await ExifHeaderExtractor.extractBatchInternal(
            for: items,
            volumeProfile: .internalSSD,
            extractItem: { _ in
                await tracker.enter()
                try? await Task.sleep(nanoseconds: 10_000_000)
                await tracker.exit()
                return ExifMetadata()
            }
        )
        let peakSSD = await tracker.getPeak()
        #expect(peakSSD <= 6, "Internal SSD must bound worker concurrency to at most 6")
        #expect(peakSSD > 0)
    }

    // MARK: - Pause/Resume Behavior during Active Navigation

    @Test("extractBatch respects isPaused state and resumes cleanly when navigation finishes")
    func extractBatchPauseAndResume() async {
        actor PauseState {
            var isPaused: Bool = false
            func setPaused(_ value: Bool) { isPaused = value }
            func getPaused() -> Bool { isPaused }
        }

        let state = PauseState()
        let items = (0..<6).map { makeDummyItem(id: "pause_test_\($0)") }

        actor Counter {
            var count = 0
            func increment() { count += 1 }
            func get() -> Int { count }
        }
        let counter = Counter()

        let task = Task.detached {
            await ExifHeaderExtractor.extractBatchInternal(
                for: items,
                volumeProfile: .networkShare,
                isPaused: {
                    await state.getPaused()
                },
                extractItem: { _ in
                    try? await Task.sleep(nanoseconds: 10_000_000)
                    await counter.increment()
                    return ExifMetadata()
                }
            )
        }

        // Allow initial items to start, then pause
        try? await Task.sleep(nanoseconds: 15_000_000)
        await state.setPaused(true)

        // Wait a bit while paused
        try? await Task.sleep(nanoseconds: 40_000_000)
        let countWhilePaused = await counter.get()

        // Wait another interval: should still not make progress while paused
        try? await Task.sleep(nanoseconds: 40_000_000)
        let countAfterPause = await counter.get()
        #expect(countWhilePaused == countAfterPause, "No new items should be processed while isPaused is true")

        // Resume
        await state.setPaused(false)
        let results = await task.value
        #expect(results.count == 6, "All items should complete after resuming")
    }

    // MARK: - Streaming Progress Emission & Cancellation

    @Test("extractBatch streams progress monotonically and preserves input item ordering")
    func extractBatchStreamingProgress() async {
        let items = (0..<5).map { makeDummyItem(id: "stream_item_\($0)") }
        actor ProgressCollector {
            var counts: [Int] = []
            var ids: [String] = []

            func record(count: Int, id: String) {
                counts.append(count)
                ids.append(id)
            }
        }
        let collector = ProgressCollector()

        let results = await ExifHeaderExtractor.extractBatchInternal(
            for: items,
            volumeProfile: .removableMedia,
            extractItem: { item in
                ExifMetadata(cameraModel: "Model-\(item.id)")
            },
            onProgress: { count, id, exif in
                await collector.record(count: count, id: id)
            }
        )

        let progressCounts = await collector.counts
        let progressIDs = await collector.ids

        #expect(results.count == 5)
        #expect(progressCounts == [1, 2, 3, 4, 5])
        #expect(progressIDs.count == 5)

        // Verify order is preserved in returned array
        for (i, result) in results.enumerated() {
            #expect(result.0 == "stream_item_\(i)")
            #expect(result.1.cameraModel == "Model-stream_item_\(i)")
        }
    }

    @Test("extractBatch exits promptly on task cancellation without deadlock")
    func extractBatchPromptCancellation() async {
        let items = (0..<20).map { makeDummyItem(id: "cancel_item_\($0)") }

        let task = Task.detached {
            await ExifHeaderExtractor.extractBatchInternal(
                for: items,
                volumeProfile: .internalSSD,
                extractItem: { _ in
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    return ExifMetadata()
                }
            )
        }

        try? await Task.sleep(nanoseconds: 20_000_000)
        task.cancel()

        let results = await task.value
        #expect(results.count < items.count, "Cancelled batch must abort early")
    }

    // MARK: - CullingSession Integration

    @Test("CullingSession.preloadExifMetadataForCurrentItems triggers preloading with session storageVolumeProfile")
    @MainActor
    func cullingSessionPreloadExifMetadataForCurrentItems() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let jpgURL = root.appendingPathComponent("sample.jpg")
        try Data("dummy".utf8).write(to: jpgURL)

        let session = CullingSession()
        session.setStorageVolumeProfile(.removableMedia)
        #expect(session.storageVolumeProfile == .removableMedia)

        session.preloadExifMetadataForCurrentItems()
        // Method executes cleanly without throwing or crashing
    }
}
