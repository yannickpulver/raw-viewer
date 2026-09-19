import Foundation

public enum UpdateCheck {

    public static let releasesURL = URL(
        string: "https://api.github.com/repos/yannickpulver/raw-viewer/releases/latest")!
    public static let userAgent = "RAW-Viewer"
    public static let timeout: TimeInterval = 5

    /// Injectable transport, so the parsing and comparison are testable.
    public typealias DataProvider = @Sendable (URLRequest) async throws -> Data

    public static func request() -> URLRequest {
        var request = URLRequest(url: releasesURL, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    /// Returns the newest published release when it differs from
    /// `currentVersion`. Skipped for "dev" / empty builds. All errors -> `nil`.
    public static func check(currentVersion: String) async -> (version: String, url: URL)? {
        await check(currentVersion: currentVersion) { request in
            try await URLSession.shared.data(for: request).0
        }
    }

    public static func check(
        currentVersion: String,
        fetch: DataProvider
    ) async -> (version: String, url: URL)? {
        guard !currentVersion.isEmpty, currentVersion != "dev" else { return nil }
        guard let data = try? await fetch(request()) else { return nil }
        guard let release = parse(data) else { return nil }
        // Plain string inequality, as shipped: a locally built newer version
        // also reports "update available" (spec 01 section 20).
        guard release.version != currentVersion else { return nil }
        return release
    }

    /// Parses the GitHub releases payload: `tag_name` with a leading `v`
    /// stripped, plus `html_url`.
    public static func parse(_ data: Data) -> (version: String, url: URL)? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = object["tag_name"] as? String,
              let link = object["html_url"] as? String,
              let url = URL(string: link) else { return nil }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard !version.isEmpty else { return nil }
        return (version, url)
    }
}
