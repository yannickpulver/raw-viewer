import Foundation

/// One scanned file. Identity is the URL (spec 03 §9 rewrite note: key everything by URL).
public struct MediaFile: Hashable, Sendable, Identifiable {
    public let url: URL
    public let kind: MediaKind
    public let captureDate: Date
    /// First-level subfolder name relative to the scan root. Spec 03 §7.
    public let subfolder: String

    public init(url: URL, kind: MediaKind, captureDate: Date, subfolder: String) {
        self.url = url
        self.kind = kind
        self.captureDate = captureDate
        self.subfolder = subfolder
    }

    public var id: URL { url }
    public var name: String { url.lastPathComponent }

    public static func == (lhs: MediaFile, rhs: MediaFile) -> Bool { lhs.url == rhs.url }
    public func hash(into hasher: inout Hasher) { hasher.combine(url) }
}
