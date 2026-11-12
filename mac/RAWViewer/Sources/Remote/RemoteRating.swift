import Foundation
import ImageIO
import Observation
import UniformTypeIdentifiers

/// Rating on the phone: a web page served over Tailscale. The phone picks one of the recent
/// folders and rates its files. The folder open in the window is served from `Library`, so a
/// rating shows up there at once; any other folder is scanned here. Every sidecar write goes
/// through the Library's one write queue either way.
@MainActor
@Observable
public final class RemoteRating {
    public static let port: UInt16 = 8765
    static let thumbSize = 400
    static let previewSize = 2048

    public enum Status: Equatable {
        case off
        case starting
        case running(URL)
        case failed(String)
    }

    public private(set) var status: Status = .off
    public var isEnabled: Bool { preferences.remoteRating }

    private let library: Library
    private let preferences: Preferences
    @ObservationIgnored private var server: HTTPServer?
    @ObservationIgnored private var awake: NSObjectProtocol?
    /// The last file list the phone loaded per folder. Requests can only name files in here.
    @ObservationIgnored private var listed: [String: Listing] = [:]
    @ObservationIgnored private var scans: [String: Task<ScanResult, Error>] = [:]
    @ObservationIgnored private var summarySaves: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private let images = RemoteImages()

    struct Listing {
        var root: URL
        var files: [String: MediaFile]
        var ratings: [URL: Int]
    }

    init(library: Library, preferences: Preferences = .shared) {
        self.library = library
        self.preferences = preferences
    }

    // MARK: - On / off

    public func setEnabled(_ on: Bool) {
        preferences.remoteRating = on
        if on { start() } else { stop() }
    }

    public func startIfEnabled() {
        if isEnabled { start() }
    }

    /// Tests pass `127.0.0.1` and port 0.
    func start(host: String? = nil, port: UInt16 = RemoteRating.port) {
        stop()
        guard let host = host ?? TailscaleAddress.ipv4() else {
            status = .failed("Tailscale is not connected.")
            return
        }
        status = .starting
        do {
            let server = try HTTPServer(host: host, port: port) { [weak self] request in
                guard let self else { return .text(503, "stopped") }
                return await self.handle(request)
            }
            self.server = server
            server.start(
                onReady: { [weak self] in
                    Task { @MainActor in self?.didStart(server, host: host) }
                },
                onFailure: { [weak self] reason in
                    Task { @MainActor in
                        guard let self, self.server === server else { return }
                        self.server = nil
                        self.endAwake()
                        self.status = .failed(reason)
                    }
                })
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    public func stop() {
        server?.stop()
        server = nil
        endAwake()
        status = .off
    }

    private func didStart(_ server: HTTPServer, host: String) {
        guard self.server === server, let port = server.port,
              let url = URL(string: "http://\(host):\(port)") else { return }
        status = .running(url)
        // A sleeping Mac answers nothing, so it stays awake while the phone may need it.
        if awake == nil {
            awake = ProcessInfo.processInfo.beginActivity(options: .idleSystemSleepDisabled,
                                                          reason: "Rating on the phone")
        }
    }

    private func endAwake() {
        if let awake { ProcessInfo.processInfo.endActivity(awake) }
        awake = nil
    }

    // MARK: - Routes

    func handle(_ request: HTTPRequest) async -> HTTPResponse {
        switch (request.method, request.path) {
        case ("GET", "/"): return page()
        case ("GET", "/api/folders"): return .json(folderList())
        case ("GET", "/api/files"): return await fileList(folderID: request.query["folder"] ?? "")
        case ("GET", "/api/thumb"): return await image(request.query, size: Self.thumbSize, cached: true)
        case ("GET", "/api/preview"): return await image(request.query, size: Self.previewSize, cached: false)
        case ("POST", "/api/rate"): return rate(request.body)
        case (_, "/"), (_, "/api/folders"), (_, "/api/files"), (_, "/api/thumb"),
             (_, "/api/preview"), (_, "/api/rate"):
            return .text(405, "method not allowed")
        default: return .text(404, "not found")
        }
    }

    private func page() -> HTTPResponse {
        guard let url = Bundle.main.url(forResource: "remote", withExtension: "html"),
              let data = try? Data(contentsOf: url) else { return .text(500, "page missing") }
        return HTTPResponse(status: 200, headers: ["Content-Type": "text/html; charset=utf-8",
                                                   "Cache-Control": "no-cache"], body: data)
    }

    // MARK: Folders

    struct FolderInfo: Encodable {
        let id: String
        let name: String
        /// Open in the Mac window right now.
        let open: Bool
        /// From the folder's last summary; `nil` when it was never fully read.
        let total: Int?
        let rated: Int?
    }

    /// The recent folders, plus the open one should it be missing there.
    private var folders: [URL] {
        var result = library.recentFolders
        if let open = library.folder, library.hasLoadedFolder,
           !result.contains(where: { Self.id($0) == Self.id(open) }) {
            result.insert(open, at: 0)
        }
        return result
    }

    private func folderList() -> [FolderInfo] {
        folders.map { folder in
            let open = isOpen(folder)
            let summary = open ? library.currentFolderSummary() : library.folderSummary(for: folder)
            return FolderInfo(id: Self.id(folder), name: folder.lastPathComponent, open: open,
                              total: summary?.total,
                              rated: summary.map { s in (1...5).reduce(0) { $0 + s.rated(stars: $1) } })
        }
    }

    static func id(_ folder: URL) -> String { folder.standardizedFileURL.path }

    private func isOpen(_ folder: URL) -> Bool {
        guard let open = library.folder, !library.isScanning, library.hasLoadedFolder else { return false }
        return Self.id(open) == Self.id(folder)
    }

    // MARK: Files

    struct FileInfo: Encodable {
        /// The path relative to the folder.
        let id: String
        let name: String
        let kind: String
        let rating: Int
        /// Capture time, seconds since 1970.
        let date: Int
    }

    struct FileList: Encodable {
        let name: String
        let open: Bool
        let files: [FileInfo]
    }

    private func fileList(folderID: String) async -> HTTPResponse {
        guard let root = folders.first(where: { Self.id($0) == folderID }) else {
            return .text(404, "unknown folder")
        }
        var files: [MediaFile]
        var ratings: [URL: Int] = [:]
        var scanRoot = root
        let open = isOpen(root)
        if open, let openFolder = library.folder {
            await library.loadAllRatings()
            scanRoot = openFolder
            files = library.modeStates[.all]?.allFiles ?? []
            for file in files { ratings[file.url] = library.rating(for: file.url) }
        } else {
            // This phone's own last ratings for the folder may still be on their way to disk.
            await library.flushPendingWrites()
            guard let result = await scan(root) else { return .text(404, "folder unreadable") }
            files = result.files(for: .all)
            let urls = files.map(\.url)
            ratings = await Task.detached(priority: .userInitiated) {
                var read: [URL: Int] = [:]
                for url in urls { read[url] = XMPSidecar.read(url) ?? 0 }
                return read
            }.value
        }

        // The scanner may hand back paths with symlinks resolved (`/var` → `/private/var`).
        // Foundation's `resolvingSymlinksInPath` maps `/private/var` back to `/var`; `realpath` does not.
        let resolved = realpath(scanRoot.path, nil).map { pointer in
            defer { free(pointer) }
            return String(cString: pointer)
        }
        let prefixes = Set([scanRoot.path, resolved ?? scanRoot.path])
            .map { $0.hasSuffix("/") ? $0 : $0 + "/" }
        var byID: [String: MediaFile] = [:]
        var infos: [FileInfo] = []
        infos.reserveCapacity(files.count)
        for file in files {
            let path = file.url.path
            let id = prefixes.first(where: path.hasPrefix).map { String(path.dropFirst($0.count)) } ?? path
            byID[id] = file
            infos.append(FileInfo(id: id, name: file.name, kind: file.kind.rawValue,
                                  rating: ratings[file.url] ?? 0,
                                  date: Int(file.captureDate.timeIntervalSince1970)))
        }
        listed[folderID] = Listing(root: root, files: byID, ratings: ratings)
        return .json(FileList(name: root.lastPathComponent, open: open, files: infos))
    }

    /// One scan per folder at a time; a second request waits for the first.
    private func scan(_ root: URL) async -> ScanResult? {
        let key = Self.id(root)
        let task = scans[key] ?? Task { try await FolderScanner().scan(root: root) }
        scans[key] = task
        let result = try? await task.value
        if scans[key] == task { scans[key] = nil }
        return result
    }

    private func file(_ query: [String: String]) -> MediaFile? {
        guard let folder = query["folder"], let id = query["file"] else { return nil }
        return listed[folder]?.files[id]
    }

    private func image(_ query: [String: String], size: Int, cached: Bool) async -> HTTPResponse {
        guard let file = file(query) else { return .text(404, "unknown file") }
        guard let data = await images.jpeg(for: file, size: size, cached: cached) else {
            return .text(404, "no image")
        }
        return HTTPResponse(status: 200, headers: ["Content-Type": "image/jpeg",
                                                   "Cache-Control": "private, max-age=86400"], body: data)
    }

    // MARK: Rating

    struct RateBody: Decodable {
        let folder: String
        let file: String
        let rating: Int
    }

    private func rate(_ body: Data) -> HTTPResponse {
        guard let request = try? JSONDecoder().decode(RateBody.self, from: body) else {
            return .text(400, "bad body")
        }
        guard var listing = listed[request.folder], let file = listing.files[request.file] else {
            return .text(404, "unknown file")
        }
        let value = Rating.clamp(request.rating)
        library.setRating(value, for: file)
        listing.ratings[file.url] = value
        listed[request.folder] = listing
        if !isOpen(listing.root) { scheduleSummarySave(folderID: request.folder) }
        return .json(["rating": value])
    }

    /// Keeps the dashboard numbers of a folder that is not open in step with the phone.
    private func scheduleSummarySave(folderID: String) {
        summarySaves[folderID]?.cancel()
        summarySaves[folderID] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled, let self, let listing = self.listed[folderID] else { return }
            self.summarySaves[folderID] = nil
            let summary = Self.summary(of: listing)
            self.library.saveFolderSummary(summary, for: listing.root)
        }
    }

    static func summary(of listing: Listing) -> FolderSummary {
        var counts: [MediaKind: Int] = [:]
        var histogram: [Int: Int] = [:]
        for file in listing.files.values {
            counts[file.kind, default: 0] += 1
            histogram[listing.ratings[file.url] ?? 0, default: 0] += 1
        }
        return FolderSummary(raw: counts[.raw] ?? 0, jpeg: counts[.jpeg] ?? 0, video: counts[.video] ?? 0,
                             ratings: histogram)
    }
}

/// JPEGs for the phone, decoded off the main thread, four at a time.
struct RemoteImages: Sendable {
    private let gate = AsyncSemaphore(value: 4)

    func jpeg(for file: MediaFile, size: Int, cached: Bool) async -> Data? {
        await gate.withPermit {
            await Task.detached(priority: .userInitiated) {
                let cache = DiskThumbnailCache.shared
                if cached, let data = cache.data(file.url, size: size) { return data }
                guard let image = PreviewDecoder().thumbnail(url: file.url, kind: file.kind,
                                                             maxPixelSize: size) else { return nil }
                if cached { cache.set(image, for: file.url, size: size) }
                return Self.encode(image)
            }.value
        }
    }

    static func encode(_ image: CGImage, quality: Double = 0.8) -> Data? {
        let data = NSMutableData()
        guard let sink = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(sink, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(sink) ? data as Data : nil
    }
}
