import CoreGraphics
import Foundation
import ImageIO

enum ExifHeaderExtractor {
    /// Extracts ExifMetadata for a MediaItem by reading headers only (CGImageSourceCopyPropertiesAtIndex),
    /// preferring the smaller raster file in a MediaPair before falling back to RAW header bytes.
    nonisolated static func extractHeaderExif(for item: MediaItem) -> ExifMetadata {
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

    /// Asynchronously extracts ExifMetadata in batch off the caller's actor context.
    nonisolated static func extractBatch(for items: [MediaItem]) async -> [(String, ExifMetadata)] {
        var results: [(String, ExifMetadata)] = []
        for item in items {
            if Task.isCancelled { break }
            let exif = extractHeaderExif(for: item)
            results.append((item.id, exif))
        }
        return results
    }

    /// Header-only extraction from a single file URL using CGImageSourceCopyPropertiesAtIndex
    /// with caching disabled so full rasters are never decoded into memory.
    nonisolated static func extract(from fileURL: URL) -> ExifMetadata {
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

    private nonisolated static func parseDate(_ string: String) -> Date? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }

        // Standard ISO8601
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        if let d = isoFormatter.date(from: trimmed) {
            return d
        }
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds, .withDashSeparatorInDate, .withColonSeparatorInTime]
        if let d = isoFormatter.date(from: trimmed) {
            return d
        }

        // EXIF Date format yyyy:MM:dd HH:mm:ss
        let customFormatter = DateFormatter()
        customFormatter.locale = Locale(identifier: "en_US_POSIX")
        customFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        let formats = [
            "yyyy:MM:dd HH:mm:ss",
            "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy-MM-dd'T'HH:mm:ssZ",
            "yyyy-MM-dd'T'HH:mm:ssXXX",
            "yyyy-MM-dd HH:mm:ss",
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
