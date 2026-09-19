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
        ])
    }

    public enum Keys {
        public static let showInfo = "showInfo"
        public static let filmstripVisible = "filmstripVisible"
        public static let didImportLegacyCache = "didImportLegacyCache"
        public static let recentFolders = "recentFolders"
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
}
