import Foundation

/// The mode switcher's segments: one per `MediaKind`, plus `all`, which shows every kind in
/// one timeline. `all` is a mac app addition — no Python-app equivalent.
public enum ViewMode: String, CaseIterable, Sendable, Hashable {
    case all
    case raw
    case jpeg
    case video

    /// The one kind this mode shows, or `nil` for `all`.
    public var kind: MediaKind? {
        switch self {
        case .all: return nil
        case .raw: return .raw
        case .jpeg: return .jpeg
        case .video: return .video
        }
    }

    public var buttonLabel: String { kind?.buttonLabel ?? "ALL" }

    public var windowTitle: String { kind?.windowTitle ?? "Media Viewer" }
}
