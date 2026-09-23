import Foundation

/// UserDefaults-backed preferences. Deliberate addition over the Python app, which persisted
/// neither of these (spec 07 §1).
public final class Preferences {
    public static let shared = Preferences(defaults: .standard)

    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
        defaults.register(defaults: [
            Keys.showInfo: true,
            Keys.filmstripVisible: true,
            Keys.didImportLegacyCache: false,
            Keys.newestFirst: false,
            Keys.showFaces: true,
            Keys.faceDetection: false,
        ])
    }

    public enum Keys {
        public static let showInfo = "showInfo"
        public static let filmstripVisible = "filmstripVisible"
        public static let didImportLegacyCache = "didImportLegacyCache"
        public static let recentFolders = "recentFolders"
        public static let newestFirst = "newestFirst"
        public static let showFaces = "showFaces"
        public static let faceDetection = "faceDetection"
    }

    public var showInfo: Bool {
        get { defaults.bool(forKey: Keys.showInfo) }
        set { defaults.set(newValue, forKey: Keys.showInfo) }
    }

    public var filmstripVisible: Bool {
        get { defaults.bool(forKey: Keys.filmstripVisible) }
        set { defaults.set(newValue, forKey: Keys.filmstripVisible) }
    }

    public var didImportLegacyCache: Bool {
        get { defaults.bool(forKey: Keys.didImportLegacyCache) }
        set { defaults.set(newValue, forKey: Keys.didImportLegacyCache) }
    }

    public var newestFirst: Bool {
        get { defaults.bool(forKey: Keys.newestFirst) }
        set { defaults.set(newValue, forKey: Keys.newestFirst) }
    }

    public var showFaces: Bool {
        get { defaults.bool(forKey: Keys.showFaces) }
        set { defaults.set(newValue, forKey: Keys.showFaces) }
    }

    public var faceDetection: Bool {
        get { defaults.bool(forKey: Keys.faceDetection) }
        set { defaults.set(newValue, forKey: Keys.faceDetection) }
    }
}
