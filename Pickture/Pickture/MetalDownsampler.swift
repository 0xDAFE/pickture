import CoreGraphics
import CoreImage
import Foundation
import Metal

/// GPU-accelerated image downsampler utilizing Metal-backed CIContext and high-quality Lanczos scaling.
public enum MetalDownsampler {
    private static let metalDevice: MTLDevice? = MTLCreateSystemDefaultDevice()

    private static let ciContext: CIContext = {
        if let device = metalDevice {
            return CIContext(mtlDevice: device, options: [
                .useSoftwareRenderer: false,
                .priorityRequestLow: false
            ])
        } else {
            return CIContext(options: nil)
        }
    }()

    public static var isMetalAvailable: Bool {
        metalDevice != nil
    }

    /// Downsamples a CGImage to fit within `maxPixelSize` along its longest dimension using
    /// Metal GPU Lanczos filtering with CPU fallback.
    public static func downsample(cgImage: CGImage, maxPixelSize: Int) -> CGImage {
        let maxDim = max(cgImage.width, cgImage.height)
        guard maxDim > maxPixelSize, maxPixelSize > 0 else {
            return cgImage
        }
        let scale = Double(maxPixelSize) / Double(maxDim)
        let targetWidth = max(1, Int((Double(cgImage.width) * scale).rounded()))
        let targetHeight = max(1, Int((Double(cgImage.height) * scale).rounded()))

        let ciImage = CIImage(cgImage: cgImage)
        if let filter = CIFilter(name: "CILanczosScaleTransform") {
            filter.setValue(ciImage, forKey: kCIInputImageKey)
            filter.setValue(scale, forKey: kCIInputScaleKey)
            filter.setValue(1.0, forKey: kCIInputAspectRatioKey)
            if let output = filter.outputImage {
                let extent = CGRect(origin: output.extent.origin, size: CGSize(width: CGFloat(targetWidth), height: CGFloat(targetHeight)))
                if let rendered = ciContext.createCGImage(output, from: extent) {
                    return rendered
                }
            }
        }

        // Fallback: CPU CGContext
        return cpuDownsample(cgImage: cgImage, targetWidth: targetWidth, targetHeight: targetHeight)
    }

    private static func cpuDownsample(cgImage: CGImage, targetWidth: Int, targetHeight: Int) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return cgImage
        }
        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        return context.makeImage() ?? cgImage
    }
}
