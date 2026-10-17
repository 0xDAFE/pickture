import CoreGraphics
import Foundation
import ImageIO

nonisolated enum ExifHeaderExtractor {
    /// Extracts ExifMetadata for a MediaItem by reading headers only (CGImageSourceCopyPropertiesAtIndex),
    /// preferring the smaller raster file in a MediaPair before falling back to RAW header bytes.
    nonisolated static func extractHeaderExif(for item: MediaItem) -> ExifMetadata {
        guard item.kind != .video else {
            return ExifMetadata()
        }
        if let pair = item.mediaPair {
            let rasterExif = extract(from: pair.rasterFile.url)
            let isRasterComplete = rasterExif.cameraModel != nil
                && rasterExif.lensModel != nil
                && rasterExif.focalLength != nil
                && rasterExif.fNumber != nil
                && rasterExif.exposureTime != nil
                && !rasterExif.isoSpeedRatings.isEmpty
                && rasterExif.dateTimeOriginal != nil

            if isRasterComplete {
                return rasterExif
            }
            // Supplement from RAW header if raster was missing information
            let rawExif = extract(from: pair.rawFile.url)
            return rasterExif.supplementing(with: rawExif)
        } else {
            return extract(from: item.primaryFile.url)
        }
    }

    /// Asynchronously extracts ExifMetadata in batch off the caller's actor context,
    /// using a bounded TaskGroup worker pool that dynamically scales based on StorageVolumeProfile,
    /// while supporting pause/resume checks during active culling navigation and streaming progress.
    nonisolated static func extractBatch(
        for items: [MediaItem],
        volumeProfile: StorageVolumeProfile = .internalSSD,
        isPaused: @escaping @Sendable () async -> Bool = { false },
        onProgress: (@Sendable (Int, String, ExifMetadata) async -> Void)? = nil
    ) async -> [(String, ExifMetadata)] {
        await extractBatchInternal(
            for: items,
            volumeProfile: volumeProfile,
            isPaused: isPaused,
            extractItem: { extractHeaderExif(for: $0) },
            onProgress: onProgress
        )
    }

    internal nonisolated static func extractBatchInternal(
        for items: [MediaItem],
        volumeProfile: StorageVolumeProfile = .internalSSD,
        isPaused: @escaping @Sendable () async -> Bool = { false },
        extractItem: @escaping @Sendable (MediaItem) async -> ExifMetadata,
        onProgress: (@Sendable (Int, String, ExifMetadata) async -> Void)? = nil
    ) async -> [(String, ExifMetadata)] {
        guard !items.isEmpty else { return [] }

        var results: [(String, ExifMetadata)?] = Array(repeating: nil, count: items.count)
        let maxWorkers = max(1, volumeProfile.defaultExifPreloadWorkers)
        var nextIndex = 0
        var processed = 0

        await withTaskGroup(of: (Int, String, ExifMetadata)?.self) { group in
            func enqueueNextWorker(into group: inout TaskGroup<(Int, String, ExifMetadata)?>) {
                guard !Task.isCancelled, nextIndex < items.count else { return }
                let index = nextIndex
                let item = items[index]
                nextIndex += 1
                group.addTask {
                    while await isPaused() && !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 50_000_000)
                    }
                    if Task.isCancelled { return nil }
                    let exif = await extractItem(item)
                    return (index, item.id, exif)
                }
            }

            let initialCount = min(maxWorkers, items.count)
            while nextIndex < initialCount {
                enqueueNextWorker(into: &group)
            }

            for await taskResult in group {
                if Task.isCancelled {
                    group.cancelAll()
                    break
                }
                if let (index, itemID, exif) = taskResult {
                    results[index] = (itemID, exif)
                    processed += 1
                    await onProgress?(processed, itemID, exif)
                }
                enqueueNextWorker(into: &group)
            }
        }

        return results.compactMap { $0 }
    }

    /// Header-only extraction from a single file URL using CGImageSourceCopyPropertiesAtIndex
    /// with caching disabled so full rasters are never decoded into memory.
    nonisolated static func extract(from fileURL: URL) -> ExifMetadata {
        let ext = fileURL.pathExtension.lowercased()
        if MediaFormatKind.classify(fileExtension: ext) == .video {
            return ExifMetadata()
        }

        let options = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldCacheImmediately: false
        ] as CFDictionary

        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, options) else {
            return ExifMetadata()
        }

        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any] else {
            return ExifMetadata()
        }

        var cameraModel: String?
        var lensModel: String?
        var focalLength: Double?
        var fNumber: Double?
        var exposureTime: Double?
        var isoSpeedRatings: [Int] = []
        var dateTimeOriginal: Date?

        // 1. TIFF Dictionary (Camera Model, Date/Time)
        if let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            if let model = tiff[kCGImagePropertyTIFFModel] as? String {
                let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { cameraModel = trimmed }
            }
            if let dtStr = tiff[kCGImagePropertyTIFFDateTime] as? String {
                dateTimeOriginal = parseDate(dtStr)
            }
        }

        // 2. EXIF Dictionary (Lens, Focal Length, Aperture, Shutter Speed, ISO, Capture Date)
        if let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            if let lens = exif[kCGImagePropertyExifLensModel] as? String {
                let trimmed = lens.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { lensModel = trimmed }
            }

            if let fl = exif[kCGImagePropertyExifFocalLength] as? NSNumber {
                focalLength = fl.doubleValue
            } else if let fl = exif[kCGImagePropertyExifFocalLength] as? Double {
                focalLength = fl
            }

            if let fn = exif[kCGImagePropertyExifFNumber] as? NSNumber {
                fNumber = fn.doubleValue
            } else if let fn = exif[kCGImagePropertyExifFNumber] as? Double {
                fNumber = fn
            }

            if let et = exif[kCGImagePropertyExifExposureTime] as? NSNumber {
                exposureTime = et.doubleValue
            } else if let et = exif[kCGImagePropertyExifExposureTime] as? Double {
                exposureTime = et
            }

            if let isos = exif[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber] {
                isoSpeedRatings = isos.map { $0.intValue }
            } else if let isos = exif[kCGImagePropertyExifISOSpeedRatings] as? [Int] {
                isoSpeedRatings = isos
            } else if let single = exif[kCGImagePropertyExifISOSpeedRatings] as? NSNumber {
                isoSpeedRatings = [single.intValue]
            }

            if let dtStr = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
                if let parsed = parseDate(dtStr) {
                    dateTimeOriginal = parsed
                }
            } else if let dtStr = exif[kCGImagePropertyExifDateTimeDigitized] as? String {
                if dateTimeOriginal == nil, let parsed = parseDate(dtStr) {
                    dateTimeOriginal = parsed
                }
            }
        }

        // 3. ExifAux Dictionary (Auxiliary Lens Model fallback)
        if lensModel == nil, let aux = properties[kCGImagePropertyExifAuxDictionary] as? [CFString: Any] {
            if let lens = aux[kCGImagePropertyExifAuxLensModel] as? String {
                let trimmed = lens.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { lensModel = trimmed }
            }
        }

        return ExifMetadata(
            cameraModel: cameraModel,
            lensModel: lensModel,
            focalLength: focalLength,
            fNumber: fNumber,
            exposureTime: exposureTime,
            isoSpeedRatings: isoSpeedRatings,
            dateTimeOriginal: dateTimeOriginal
        )
    }

    nonisolated static func parseDate(_ string: String) -> Date? {
        ExifDateParser.parse(string)
    }
}

/// Thread-safe cached date parsers for EXIF and ISO-8601 metadata strings.
/// Eliminates per-call heap allocation of `DateFormatter` and `ISO8601DateFormatter`.
nonisolated enum ExifDateParser {
    private static let lock = NSLock()

    // 1. Thread-safe cached ISO8601DateFormatter instances.
    //
    // **Concurrency Safety Invariant**:
    // - Marked `nonisolated(unsafe)` because `ISO8601DateFormatter` is not yet marked `Sendable` in Foundation,
    //   even though Apple documentation guarantees that date parsing operations (`date(from:)`) are thread-safe
    //   when the formatter's configuration is not mutated after initialization.
    // - These instances are configured once during static initialization and their properties are never mutated.
    //
    // **Follow-Up Removal Plan**:
    // - Remove `nonisolated(unsafe)` once Foundation marks `ISO8601DateFormatter` as `Sendable` or once all
    //   call sites migrate exclusively to Swift's native `Date(string, strategy: .iso8601)` parsing.
    private nonisolated(unsafe) static let iso8601InternetFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        return f
    }()

    private nonisolated(unsafe) static let iso8601FractionalFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds, .withDashSeparatorInDate, .withColonSeparatorInTime]
        return f
    }()

    // 2. Pre-configured dedicated DateFormatter instances for EXIF and fallback patterns
    private static let exifDateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f
    }()

    private static let exifDateTimeTZFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy:MM:dd HH:mm:ssXXX"
        return f
    }()

    private static let exifDateOnlyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy:MM:dd"
        return f
    }()

    private static let isoNoTZFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f
    }()

    private static let isoZFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        return f
    }()

    private static let isoXXXFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXX"
        return f
    }()

    private static let spaceDateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    private static let dateOnlyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func parse(_ string: String) -> Date? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Fast path 1: Modern Swift Foundation ISO-8601 parse strategy
        if let date = try? Date(trimmed, strategy: .iso8601) {
            return date
        }
        if let date = try? Date(trimmed, strategy: .iso8601.year().month().day().time(includingFractionalSeconds: true)) {
            return date
        }

        // Fast path 2: Standard EXIF colon date format: "yyyy:MM:dd HH:mm:ss"
        if trimmed.count >= 10 {
            let fifthCharIndex = trimmed.index(trimmed.startIndex, offsetBy: 4)
            if trimmed[fifthCharIndex] == ":" {
                lock.lock()
                defer { lock.unlock() }
                if let d = exifDateTimeFormatter.date(from: trimmed) {
                    return d
                }
                if let d = exifDateTimeTZFormatter.date(from: trimmed) {
                    return d
                }
                if let d = exifDateOnlyFormatter.date(from: trimmed) {
                    return d
                }
            }
        }

        // Fast path 3: Cached ISO8601DateFormatter
        if let d = iso8601InternetFormatter.date(from: trimmed) {
            return d
        }
        if let d = iso8601FractionalFormatter.date(from: trimmed) {
            return d
        }

        // Fast path 4: Fallback ISO and standard formatters
        lock.lock()
        defer { lock.unlock() }
        if let d = isoNoTZFormatter.date(from: trimmed) {
            return d
        }
        if let d = isoZFormatter.date(from: trimmed) {
            return d
        }
        if let d = isoXXXFormatter.date(from: trimmed) {
            return d
        }
        if let d = spaceDateTimeFormatter.date(from: trimmed) {
            return d
        }
        if let d = dateOnlyFormatter.date(from: trimmed) {
            return d
        }

        return nil
    }
}
