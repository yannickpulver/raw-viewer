import Foundation

/// Moving the current filtered timeline into one user-chosen folder, flat. Mac app addition —
/// see `mac/README.md`, "Deliberate deviations". Modelled on `MoveRejected`.
public enum MoveFiles {
    /// Moves `files` into `destination`, flat (no subfolder structure; JPEG/RAW siblings that
    /// are not themselves in `files` are left behind). Each file's XMP sidecar (same directory,
    /// extension replaced — `XMPSidecar.path(for:)`) moves along with it, under the same
    /// (possibly renumbered) stem so the rating stays attached. A RAW/JPEG pair that shares one
    /// sidecar moves it once, with whichever of the pair is processed first. A file already
    /// sitting in `destination` is skipped. Stops at the first error, same convention as
    /// `MoveRejected.moveToRejected`.
    public static func moveToFolder(_ files: [URL], destination: URL) -> (moved: Int, error: String?) {
        let fm = FileManager.default
        let destinationPath = destination.standardizedFileURL.path
        var moved = 0
        var sidecarsHandled = Set<String>()

        try? fm.createDirectory(at: destination, withIntermediateDirectories: true)

        for file in files {
            let source = file.standardizedFileURL
            guard source.deletingLastPathComponent().standardizedFileURL.path != destinationPath else {
                continue
            }

            let sidecarSource = XMPSidecar.path(for: source).standardizedFileURL
            let sidecarKey = sidecarSource.path
            let movesSidecar = !sidecarsHandled.contains(sidecarKey) && fm.fileExists(atPath: sidecarSource.path)

            let stem = uniqueStem(for: source, reservingXMP: movesSidecar, in: destination)
            let mediaDestination = destination.appendingPathComponent(stem)
                .appendingPathExtension(source.pathExtension)

            do {
                try fm.moveItem(at: source, to: mediaDestination)
                moved += 1
            } catch {
                return (moved, "\(source.lastPathComponent): \(error.localizedDescription)")
            }

            if movesSidecar {
                let sidecarDestination = destination.appendingPathComponent(stem)
                    .appendingPathExtension("xmp")
                do {
                    try fm.moveItem(at: sidecarSource, to: sidecarDestination)
                } catch {
                    return (moved, "\(sidecarSource.lastPathComponent): \(error.localizedDescription)")
                }
            }
            sidecarsHandled.insert(sidecarKey)
        }
        return (moved, nil)
    }

    /// A stem for which `<stem>.<source's extension>` is free at `destination`, and — when
    /// `reservingXMP` is true — `<stem>.xmp` is free too, so the media file and its sidecar can
    /// share the same renumbered name. Same ` 2`, ` 3`… suffix style as
    /// `MoveRejected.uniqueDestination`.
    private static func uniqueStem(for source: URL, reservingXMP: Bool, in destination: URL) -> String {
        let fm = FileManager.default
        let baseStem = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension
        var suffix = 1
        while true {
            let stem = suffix == 1 ? baseStem : "\(baseStem) \(suffix)"
            let mediaCandidate = destination.appendingPathComponent(stem).appendingPathExtension(ext)
            let mediaFree = !fm.fileExists(atPath: mediaCandidate.path)
            let xmpFree = !reservingXMP
                || !fm.fileExists(atPath: destination.appendingPathComponent(stem)
                    .appendingPathExtension("xmp").path)
            if mediaFree && xmpFree { return stem }
            suffix += 1
        }
    }
}
