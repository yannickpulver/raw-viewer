import AppKit
import Foundation

/// Result of a DaVinci Resolve export. Strings are the exact user-facing
/// messages from spec 06 section 5.
public enum ResolveExportResult: Equatable, Sendable {
    case success(String)
    case failure(String)
}

/// Rating -> clip colour / keyword / Good Take mapping (spec 06 section 4).
///
/// This mirrors the `RATING_MAP` table in `resolve_export.lua`, which is what
/// actually talks to Resolve. It lives here so the contract is unit tested and
/// documented in Swift; keep the two in sync.
public struct ResolveRatingMapping: Equatable, Sendable {
    public let color: String
    public let keywords: String
    public let goodTake: Bool
    public let comments: String
    public let description: String
}

/// One line of the `fuscript` stdout protocol.
public enum ResolveScriptEvent: Equatable, Sendable {
    case status(String)
    case ok(clips: Int, rated: Int)
    case error(String)
    case notRunning
}

public enum ResolveExport {

    // MARK: - Installation

    /// Candidate `fuscript` interpreters, in preference order. More install
    /// locations can simply be appended.
    public static let fuscriptCandidates: [String] = [
        "/Applications/DaVinci Resolve/DaVinci Resolve.app/Contents/Libraries/Fusion/fuscript"
    ]

    /// Candidate native scripting libraries. Kept from the Python
    /// implementation's `is_resolve_installed()` check.
    public static let scriptingLibraryCandidates: [String] = [
        "/Applications/DaVinci Resolve/DaVinci Resolve.app/Contents/Libraries/Fusion/fusionscript.so"
    ]

    /// Candidate application bundles used to launch Resolve.
    public static let applicationCandidates: [String] = [
        "/Applications/DaVinci Resolve/DaVinci Resolve.app"
    ]

    /// First `fuscript` that exists and is executable.
    public static var fuscriptPath: String? {
        let fm = FileManager.default
        return fuscriptCandidates.first { fm.isExecutableFile(atPath: $0) }
    }

    /// First scripting library that exists.
    public static var scriptingLibraryPath: String? {
        let fm = FileManager.default
        return scriptingLibraryCandidates.first { fm.fileExists(atPath: $0) }
    }

    /// First Resolve application bundle that exists.
    public static var applicationURL: URL? {
        let fm = FileManager.default
        return applicationCandidates
            .first { fm.fileExists(atPath: $0) }
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    public static var isInstalled: Bool {
        fuscriptPath != nil && scriptingLibraryPath != nil
    }

    // MARK: - Messages (spec 06 section 5)

    public enum Message {
        public static let notInstalled =
            "DaVinci Resolve not found.\nRequires Resolve Studio (paid) for scripting."
        public static let connecting = "Connecting to DaVinci Resolve..."
        public static let launching = "Launching DaVinci Resolve..."
        public static let couldNotLaunch = "Could not launch DaVinci Resolve."
        public static let couldNotConnect =
            "Could not connect to DaVinci Resolve.\nMake sure Resolve Studio is running."
        public static let cleared = ""

        public static func waiting(seconds: Int) -> String {
            "Waiting for Resolve to start... (\(seconds)s)"
        }

        public static func success(projectName: String, clips: Int, rated: Int) -> String {
            "Exported to Resolve project '\(projectName)'\n\(clips) clips imported, \(rated) with ratings"
        }
    }

    /// Number of 1 second retries after launching Resolve.
    public static let startupRetryCount = 30

    // MARK: - Rating mapping

    public static func ratingMapping(for rating: Int) -> ResolveRatingMapping? {
        switch rating {
        case 1: return ResolveRatingMapping(color: "Blue", keywords: "1star", goodTake: false,
                                            comments: "Rating: 1/5", description: "★☆☆☆☆")
        case 2: return ResolveRatingMapping(color: "Teal", keywords: "2stars", goodTake: false,
                                            comments: "Rating: 2/5", description: "★★☆☆☆")
        case 3: return ResolveRatingMapping(color: "Yellow", keywords: "3stars", goodTake: false,
                                            comments: "Rating: 3/5", description: "★★★☆☆")
        case 4: return ResolveRatingMapping(color: "Orange", keywords: "4stars", goodTake: true,
                                            comments: "Rating: 4/5", description: "★★★★☆")
        case 5: return ResolveRatingMapping(color: "Green", keywords: "5stars,keeper", goodTake: true,
                                            comments: "Rating: 5/5", description: "★★★★★")
        default: return nil
        }
    }

    // MARK: - Job file

    /// One line per file: `rating<TAB>absolute path`, in the given order.
    /// A file missing from `ratings` counts as 0.
    public static func jobFileContents(files: [URL], ratings: [URL: Int]) -> String {
        files
            .map { "\(ratings[$0] ?? 0)\t\($0.path)" }
            .joined(separator: "\n") + "\n"
    }

    /// Writes the job file into a fresh temporary directory and returns its URL.
    public static func writeJobFile(files: [URL], ratings: [URL: Int]) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("rawviewer-resolve-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("job.tsv")
        try jobFileContents(files: files, ratings: ratings)
            .write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - stdout protocol

    /// Parses one line of the Lua script's stdout. Unknown lines (such as the
    /// `fuscript` banner) return `nil`.
    public static func parseLine(_ line: String) -> ResolveScriptEvent? {
        let trimmed = line.trimmingCharacters(in: CharacterSet(charactersIn: "\r\n"))
        if trimmed.isEmpty { return nil }
        if trimmed == "NOTRUNNING" { return .notRunning }

        let fields = trimmed.components(separatedBy: "\t")
        switch fields.first {
        case "STATUS":
            guard fields.count >= 2 else { return nil }
            return .status(fields[1...].joined(separator: "\t"))
        case "RESULT":
            guard fields.count >= 2 else { return nil }
            switch fields[1] {
            case "OK":
                guard fields.count >= 4,
                      let clips = Int(fields[2]),
                      let rated = Int(fields[3]) else { return nil }
                return .ok(clips: clips, rated: rated)
            case "ERR":
                guard fields.count >= 3 else { return nil }
                return .error(fields[2...].joined(separator: "\t"))
            default:
                return nil
            }
        default:
            return nil
        }
    }

    // MARK: - Export

    public static func projectName(folderName: String) -> String {
        "RV - \(folderName)"
    }

    /// Exports `files` (in order) with their `ratings` into a Resolve project
    /// named `RV - {folderName}`.
    public static func export(
        files: [URL],
        ratings: [URL: Int],
        folderName: String,
        onStatus: @escaping @Sendable (String) -> Void
    ) async -> ResolveExportResult {
        await export(
            files: files,
            ratings: ratings,
            folderName: folderName,
            fuscript: isInstalled ? fuscriptPath : nil,
            script: Bundle.main.url(forResource: "resolve_export", withExtension: "lua"),
            onStatus: onStatus)
    }

    /// Testable seam: `fuscript` / `script` are `nil` when Resolve or the
    /// bundled Lua script cannot be found.
    static func export(
        files: [URL],
        ratings: [URL: Int],
        folderName: String,
        fuscript: String?,
        script: URL?,
        onStatus: @escaping @Sendable (String) -> Void
    ) async -> ResolveExportResult {
        guard let fuscript, let script else {
            return .failure(Message.notInstalled)
        }

        let name = projectName(folderName: folderName)
        let jobFile: URL
        do {
            jobFile = try writeJobFile(files: files, ratings: ratings)
        } catch {
            return .failure("Could not write the export job file.")
        }
        defer { try? FileManager.default.removeItem(at: jobFile.deletingLastPathComponent()) }

        onStatus(Message.connecting)
        var outcome = await runScript(fuscript: fuscript, script: script,
                                      projectName: name, jobFile: jobFile, onStatus: onStatus)

        if case .notRunning = outcome {
            onStatus(Message.launching)
            guard await launchResolve() else {
                return .failure(Message.couldNotLaunch)
            }
            var connected = false
            for attempt in 1...startupRetryCount {
                onStatus(Message.waiting(seconds: attempt))
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                outcome = await runScript(fuscript: fuscript, script: script,
                                          projectName: name, jobFile: jobFile, onStatus: onStatus)
                if case .notRunning = outcome { continue }
                connected = true
                break
            }
            if !connected {
                return .failure(Message.couldNotConnect)
            }
        }

        switch outcome {
        case .ok(let clips, let rated):
            onStatus(Message.cleared)
            return .success(Message.success(projectName: name, clips: clips, rated: rated))
        case .error(let message):
            return .failure(message)
        case .notRunning:
            return .failure(Message.couldNotConnect)
        case .spawnFailure(let message):
            return .failure(message)
        }
    }

    // MARK: - Private

    enum ScriptOutcome: Sendable {
        case ok(clips: Int, rated: Int)
        case error(String)
        case notRunning
        case spawnFailure(String)
    }

    private static func launchResolve() async -> Bool {
        guard let appURL = applicationURL else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        do {
            _ = try await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
            return true
        } catch {
            return false
        }
    }

    private static func runScript(
        fuscript: String,
        script: URL,
        projectName: String,
        jobFile: URL,
        onStatus: @escaping @Sendable (String) -> Void
    ) async -> ScriptOutcome {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: runScriptBlocking(
                    fuscript: fuscript, script: script,
                    projectName: projectName, jobFile: jobFile, onStatus: onStatus))
            }
        }
    }

    private static func runScriptBlocking(
        fuscript: String,
        script: URL,
        projectName: String,
        jobFile: URL,
        onStatus: @escaping @Sendable (String) -> Void
    ) -> ScriptOutcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: fuscript)
        process.arguments = ["-l", "lua", script.path, projectName, jobFile.path]
        let stdout = Pipe()
        process.standardOutput = stdout
        // stderr must be drained, or a chatty child blocks forever on a full pipe buffer.
        let stderr = Pipe()
        process.standardError = stderr
        let stderrLock = NSLock()
        var stderrData = Data()
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            stderrLock.lock()
            // Cap it: the message only quotes the tail, and an endless stream must not grow here.
            if stderrData.count < 64_000 { stderrData.append(chunk) }
            stderrLock.unlock()
        }

        do {
            try process.run()
        } catch {
            stderr.fileHandleForReading.readabilityHandler = nil
            return .spawnFailure(Message.notInstalled)
        }

        var outcome: ScriptOutcome?
        var buffer = Data()
        let handle = stdout.fileHandleForReading
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                guard let line = String(data: lineData, encoding: .utf8),
                      let event = parseLine(line) else { continue }
                switch event {
                case .status(let text): onStatus(text)
                case .ok(let clips, let rated): outcome = .ok(clips: clips, rated: rated)
                case .error(let message): outcome = .error(message)
                case .notRunning: outcome = .notRunning
                }
            }
        }
        if !buffer.isEmpty, let line = String(data: buffer, encoding: .utf8),
           let event = parseLine(line) {
            switch event {
            case .status(let text): onStatus(text)
            case .ok(let clips, let rated): outcome = .ok(clips: clips, rated: rated)
            case .error(let message): outcome = .error(message)
            case .notRunning: outcome = .notRunning
            }
        }
        process.waitUntilExit()
        stderr.fileHandleForReading.readabilityHandler = nil

        if let outcome { return outcome }
        stderrLock.lock()
        let errorText = String(data: stderrData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        stderrLock.unlock()
        guard !errorText.isEmpty else { return .error(Message.couldNotConnect) }
        let tail = errorText.split(separator: "\n").suffix(1).joined()
        return .error("\(Message.couldNotConnect) (\(tail))")
    }
}
