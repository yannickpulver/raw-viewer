import AVFoundation
import CoreGraphics
import CoreImage
import Foundation
import ImageIO

/// ImageIO / CoreImage decoding. Every method is synchronous and must be called off the main
/// thread (the scheduler always does). Spec 04 §2–§5, with the colour handling of §6:
/// keep the CGImage's own colour space, never re-encode.
public struct PreviewDecoder: Sendable {
    /// Long-edge cap for the full preview. Spec 04 §1.
    public static let previewMaxPixelSize = 2560
    /// Filmstrip thumbnail size. Spec 04 §1.
    public static let filmstripThumbnailSize = 80
    /// Grid thumbnail size. Spec 04 §1.
    public static let gridThumbnailSize = 200
    /// Below this width an embedded RAW preview is considered too small to be the final image.
    public static let smallPreviewWidth = 1280

    public init() {}

    // MARK: - Previews

    /// Full-screen preview. `nil` for video (spec 01 §18: video has no still preview).
    public func preview(url: URL, kind: MediaKind) -> CGImage? {
        switch kind {
        case .video: return nil
        case .jpeg: return thumbnail(url: url, kind: .jpeg, maxPixelSize: Self.previewMaxPixelSize)
        case .raw: return thumbnail(url: url, kind: .raw, maxPixelSize: Self.previewMaxPixelSize)
        }
    }

    /// True when the decoded RAW preview is an embedded thumbnail far smaller than the source,
    /// which means a full develop is worth scheduling. Spec 04 §2 (the DJI DNG path).
    public func needsFullDevelop(image: CGImage, url: URL) -> Bool {
        guard image.width < Self.smallPreviewWidth else { return false }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let sourceWidth = properties[kCGImagePropertyPixelWidth] as? Int else { return false }
        return sourceWidth >= image.width * 2
    }

    /// Full RAW develop through `CIRAWFilter`, half size, capped at 2560 px, sRGB output.
    public func fullDevelop(url: URL) -> CGImage? {
        guard let filter = CIRAWFilter(imageURL: url) else { return nil }
        filter.isDraftModeEnabled = true
        guard let output = filter.outputImage else { return nil }

        let extent = output.extent
        guard extent.width > 0, extent.height > 0 else { return nil }
        let longEdge = max(extent.width, extent.height)
        let scale = longEdge > CGFloat(Self.previewMaxPixelSize)
            ? CGFloat(Self.previewMaxPixelSize) / longEdge
            : 1.0
        let scaled = scale < 1.0 ? output.transformed(by: .init(scaleX: scale, y: scale)) : output

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let context = CIContext(options: [.workingColorSpace: colorSpace])
        return context.createCGImage(scaled, from: scaled.extent, format: .RGBA8, colorSpace: colorSpace)
    }

    // MARK: - Thumbnails

    /// 80 px / 200 px thumbnails and previews share this one ImageIO call.
    /// RAW uses `FromImageIfAbsent` (the embedded preview, ~12–210 ms); JPEG must use
    /// `FromImageAlways` because `IfAbsent` returns the 192 px EXIF thumbnail. Spec 04 §5.
    public func thumbnail(url: URL, kind: MediaKind, maxPixelSize: Int) -> CGImage? {
        if kind == .video {
            return videoThumbnail(url: url, maxPixelSize: maxPixelSize)
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        var options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        if kind == .jpeg {
            options[kCGImageSourceCreateThumbnailFromImageAlways] = true
        } else {
            options[kCGImageSourceCreateThumbnailFromImageIfAbsent] = true
        }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Video poster frame at t=0 via `AVAssetImageGenerator`. Spec 04 §5 rewrite note.
    public func videoThumbnail(url: URL, maxPixelSize: Int) -> CGImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixelSize * 2, height: maxPixelSize * 2)
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity
        return try? generator.copyCGImage(at: .zero, actualTime: nil)
    }

    /// Downscales an already-decoded image, used to derive an 80 px thumb from a landed preview.
    public static func downscale(_ image: CGImage, maxPixelSize: Int) -> CGImage? {
        let longEdge = max(image.width, image.height)
        guard longEdge > maxPixelSize else { return image }
        let scale = Double(maxPixelSize) / Double(longEdge)
        let width = max(1, Int(Double(image.width) * scale))
        let height = max(1, Int(Double(image.height) * scale))
        let colorSpace = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
