import CoreGraphics
import Foundation
import ImageIO

/// What the sidebar's photo card shows about one image: exposure values, camera and lens.
/// Read on demand for the photo on screen, never during the scan.
public struct PhotoDetails: Equatable, Sendable {
    /// Seconds.
    public var exposureTime: Double?
    public var fNumber: Double?
    public var iso: Int?
    /// Millimetres, as recorded (not the 35 mm equivalent).
    public var focalLength: Double?
    public var camera: String?
    public var lens: String?

    public init(exposureTime: Double? = nil, fNumber: Double? = nil, iso: Int? = nil,
                focalLength: Double? = nil, camera: String? = nil, lens: String? = nil) {
        self.exposureTime = exposureTime
        self.fNumber = fNumber
        self.iso = iso
        self.focalLength = focalLength
        self.camera = camera
        self.lens = lens
    }

    public var isEmpty: Bool {
        exposureTime == nil && fNumber == nil && iso == nil && focalLength == nil && camera == nil && lens == nil
    }

    /// EXIF and TIFF properties via ImageIO. `nil` when the file has none.
    public static func read(_ url: URL) -> PhotoDetails? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return nil }
        let details = PhotoDetails(properties: properties)
        return details.isEmpty ? nil : details
    }

    init(properties: [CFString: Any]) {
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        exposureTime = (exif[kCGImagePropertyExifExposureTime] as? Double).flatMap { $0 > 0 ? $0 : nil }
        fNumber = (exif[kCGImagePropertyExifFNumber] as? Double).flatMap { $0 > 0 ? $0 : nil }
        iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first
        focalLength = (exif[kCGImagePropertyExifFocalLength] as? Double).flatMap { $0 > 0 ? $0 : nil }
        camera = Self.camera(make: tiff[kCGImagePropertyTIFFMake] as? String,
                             model: tiff[kCGImagePropertyTIFFModel] as? String)
        lens = Self.trimmed(exif[kCGImagePropertyExifLensModel] as? String)
    }

    /// `Fujifilm X-T5`. Most makers repeat the make in the model (`Canon EOS R5`); then the
    /// model alone. All-caps makes (`FUJIFILM`, `NIKON CORPORATION`) read better capitalised.
    static func camera(make: String?, model: String?) -> String? {
        let model = trimmed(model)
        guard var make = trimmed(make) else { return model }
        make = make.replacingOccurrences(of: " CORPORATION", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: " Corporation", with: "")
        if make == make.uppercased(), make.count > 3 { make = make.capitalized }
        guard let model else { return make }
        if model.lowercased().hasPrefix(make.lowercased()) { return model }
        return "\(make) \(model)"
    }

    private static func trimmed(_ value: String?) -> String? {
        let text = value?.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters)) ?? ""
        return text.isEmpty ? nil : text
    }

    // MARK: - Formatting

    /// `1/500`, `1/4`, `0.8 s`, `2 s`, `30 s`.
    public var shutterText: String? {
        guard let time = exposureTime else { return nil }
        if time >= 0.3 {
            let rounded = (time * 10).rounded() / 10
            return String(format: "%g s", rounded)
        }
        return "1/\(Int((1 / time).rounded()))"
    }

    /// `f/8`, `f/2.8`.
    public var apertureText: String? {
        fNumber.map { String(format: "f/%g", ($0 * 10).rounded() / 10) }
    }

    public var isoText: String? { iso.map { "ISO \($0)" } }

    /// `23 mm`.
    public var focalText: String? { focalLength.map { "\(Int($0.rounded())) mm" } }

    /// `Fujifilm X-T5 · XF16-55mmF2.8 R LM WR`.
    public var gearText: String? {
        let parts = [camera, lens].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// Brightness distribution of a decoded image, for the photo card. Computed from the preview
/// the canvas already shows (the camera's embedded JPEG for RAW files), never from raw data.
public enum LumaHistogram {
    public static let binCount = 64
    /// The longer edge the image is drawn at before counting. Plenty for 64 bins.
    static let sampleEdge = 256

    /// One count per bin, darkest first. `nil` when the image cannot be drawn.
    public static func compute(_ image: CGImage) -> [Int]? {
        let scale = Double(sampleEdge) / Double(max(image.width, image.height, 1))
        let width = max(1, Int((Double(image.width) * min(1, scale)).rounded()))
        let height = max(1, Int((Double(image.height) * min(1, scale)).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let data = context.data else { return nil }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height)
        var bins = [Int](repeating: 0, count: binCount)
        for index in 0..<(width * height) {
            bins[Int(pixels[index]) * binCount / 256] += 1
        }
        return bins
    }

    /// Bar heights in `0...1`. Scaled to the tallest inner bin, so a clipped black or white
    /// spike at either end does not flatten everything else (the spike just hits the top).
    public static func normalized(_ bins: [Int]) -> [Double] {
        guard bins.count > 2 else { return bins.map { _ in 0 } }
        let peak = bins[1..<(bins.count - 1)].max() ?? 0
        guard peak > 0 else { return bins.map { $0 > 0 ? 1 : 0 } }
        return bins.map { min(1, Double($0) / Double(peak)) }
    }
}
