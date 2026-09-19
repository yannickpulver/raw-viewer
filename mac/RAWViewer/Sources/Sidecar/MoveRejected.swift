import Foundation

/// Moving rejected files into `_rejected/`. Spec 05 §10.
public enum MoveRejected {
    public static let directoryName = "_rejected"

    /// Every other file in the same directory with the same case-insensitive stem.
    public static func findSiblings(of file: URL) -> [URL] {
        let directory = file.deletingLastPathComponent()
        let stem = file.deletingPathExtension().lastPathComponent.lowercased()
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: []) else { return [] }
        return entries.filter { candidate in
            guard candidate.lastPathComponent != file.lastPathComponent else { return false }
            let isDirectory = (try? candidate.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard !isDirectory else { return false }
            return candidate.deletingPathExtension().lastPathComponent.lowercased() == stem
        }
    }

    /// Each rejected file followed by its siblings, deduplicated, first-seen order preserved.
    public static func collectMoveSet(_ rejected: [URL]) -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []
        for file in rejected {
            for candidate in [file] + findSiblings(of: file) {
                let key = candidate.standardizedFileURL.path
                if seen.insert(key).inserted { result.append(candidate) }
            }
        }
        return result
    }

    /// Moves files into `root/_rejected/<relative path>`, preserving subpaths.
    /// Stops at the first error. Deliberate deviation from the Python app: an existing
    /// destination gets a ` 2`, ` 3`… suffix before the extension instead of being overwritten.
    public static func moveToRejected(_ files: [URL], root: URL) -> (moved: Int, error: String?) {
        let fm = FileManager.default
        let rootPath = root.standardizedFileURL.path
        let destinationRoot = root.appendingPathComponent(directoryName, isDirectory: true)
        var moved = 0

        for file in files {
            let source = file.standardizedFileURL
            let relative: String
            if source.path.hasPrefix(rootPath + "/") {
                relative = String(source.path.dropFirst(rootPath.count + 1))
            } else {
                relative = source.lastPathComponent
            }
            let destination = uniqueDestination(destinationRoot.appendingPathComponent(relative))
            do {
                try fm.createDirectory(at: destination.deletingLastPathComponent(),
                                       withIntermediateDirectories: true)
                try fm.moveItem(at: source, to: destination)
                moved += 1
            } catch {
                return (moved, "\(source.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return (moved, nil)
    }

    static func uniqueDestination(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let directory = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        var suffix = 2
        while true {
            let name = ext.isEmpty ? "\(stem) \(suffix)" : "\(stem) \(suffix).\(ext)"
            let candidate = directory.appendingPathComponent(name)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            suffix += 1
        }
    }
}
