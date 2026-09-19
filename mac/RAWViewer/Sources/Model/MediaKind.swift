import Foundation

/// The three file classes the app can cull. Spec 03 §1.
public enum MediaKind: String, CaseIterable, Sendable, Hashable, Codable {
    case raw
    case jpeg
    case video

    /// 28 RAW extensions, spec 03 §1.
    public static let rawExtensions: Set<String> = [
        "cr2", "cr3", "nef", "arw", "raf", "orf",
        "rw2", "dng", "pef", "srw", "3fr", "ari",
        "bay", "crw", "dcr", "erf", "fff", "mef",
        "mrw", "nrw", "ptx", "pxn", "r3d", "rwl",
        "rwz", "sr2", "srf", "x3f",
    ]

    /// 2 JPEG extensions, spec 03 §1.
    public static let jpegExtensions: Set<String> = ["jpg", "jpeg"]

    /// 3 video extensions, spec 03 §1.
    public static let videoExtensions: Set<String> = ["mov", "mp4", "m4v"]

    public var extensions: Set<String> {
        switch self {
        case .raw: return MediaKind.rawExtensions
        case .jpeg: return MediaKind.jpegExtensions
        case .video: return MediaKind.videoExtensions
        }
    }

    /// Case-insensitive classification by file extension. `nil` for unsupported files.
    /// Files whose name starts with `._` (macOS resource forks) are never classified.
    public static func of(_ url: URL) -> MediaKind? {
        let name = url.lastPathComponent
        guard !name.hasPrefix("._") else { return nil }
        let ext = url.pathExtension.lowercased()
        guard !ext.isEmpty else { return nil }
        if rawExtensions.contains(ext) { return .raw }
        if jpegExtensions.contains(ext) { return .jpeg }
        if videoExtensions.contains(ext) { return .video }
        return nil
    }

    /// Window / mode-switcher label. Spec 01 §4.
    public var buttonLabel: String {
        switch self {
        case .raw: return "RAW"
        case .jpeg: return "JPG"
        case .video: return "MOV"
        }
    }

    /// Custom window title per mode. Spec 01 §1.
    public var windowTitle: String {
        switch self {
        case .raw: return "RAW Viewer"
        case .jpeg: return "JPEG Viewer"
        case .video: return "Video Viewer"
        }
    }
}
