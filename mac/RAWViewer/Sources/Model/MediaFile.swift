import Foundation

/// Shutter time and exposure compensation from EXIF: what tells a bracket's frames apart.
public struct Exposure: Hashable, Sendable {
    /// Seconds.
    public let time: Double
    /// EV.
    public let bias: Double

    public init(time: Double, bias: Double) {
        self.time = time
        self.bias = bias
    }
}

/// One scanned file. Identity is the URL (spec 03 §9 rewrite note: key everything by URL).
public struct MediaFile: Hashable, Sendable, Identifiable {
    public let url: URL
    public let kind: MediaKind
    public let captureDate: Date
    /// First-level subfolder name relative to the scan root. Spec 03 §7.
    public let subfolder: String
    /// `nil` for videos and files without EXIF exposure.
    public let exposure: Exposure?

    public init(url: URL, kind: MediaKind, captureDate: Date, subfolder: String, exposure: Exposure? = nil) {
        self.url = url
        self.kind = kind
        self.captureDate = captureDate
        self.subfolder = subfolder
        self.exposure = exposure
    }

    public var id: URL { url }
    public var name: String { url.lastPathComponent }

    public static func == (lhs: MediaFile, rhs: MediaFile) -> Bool { lhs.url == rhs.url }
    public func hash(into hasher: inout Hasher) { hasher.combine(url) }
}
