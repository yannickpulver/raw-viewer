import Foundation

/// Adobe XMP sidecar read/write. Spec 05 §2–§5.
public enum XMPSidecar {
    /// Replaces the extension (does not append). Spec 05 §2.
    public static func path(for url: URL) -> URL {
        url.deletingPathExtension().appendingPathExtension("xmp")
    }

    /// Byte-for-byte template from spec 05 §3. No trailing newline, UTF-8, `\n` line endings.
    public static func template(rating: Int) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
          <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            <rdf:Description rdf:about=""
              xmlns:xmp="http://ns.adobe.com/xap/1.0/"
              xmp:Rating="\(rating)"/>
          </rdf:RDF>
        </x:xmpmeta>
        """
    }

    private static let readPattern = try! NSRegularExpression(pattern: #"xmp:Rating=["'](-?\d)["']"#)
    private static let updatePattern = try! NSRegularExpression(pattern: #"(xmp:Rating=["']?)(-?\d)(["']?)"#)

    /// `nil` when there is no sidecar or no rating attribute. Spec 05 §4.
    public static func read(_ url: URL) -> Int? {
        let sidecar = path(for: url)
        guard let text = try? String(contentsOf: sidecar, encoding: .utf8) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = readPattern.firstMatch(in: text, range: range),
              let digits = Range(match.range(at: 1), in: text) else { return nil }
        return Int(text[digits])
    }

    /// Clamps to -1...5 and writes with the three branches of spec 05 §5.
    /// Returns `false` on any I/O failure.
    @discardableResult
    public static func write(_ url: URL, rating: Int) -> Bool {
        let value = Rating.clamp(rating)
        let sidecar = path(for: url)

        // No sidecar yet → write the template. A sidecar that exists but cannot be read as
        // UTF-8 is someone else's data: refuse rather than clobber it. Spec 05 §5.
        guard FileManager.default.fileExists(atPath: sidecar.path) else {
            return writeText(template(rating: value), to: sidecar)
        }
        guard let existing = try? String(contentsOf: sidecar, encoding: .utf8) else {
            return false
        }

        let range = NSRange(existing.startIndex..<existing.endIndex, in: existing)

        // Branch 1: substitute every existing rating digit, preserving quoting.
        if updatePattern.firstMatch(in: existing, range: range) != nil {
            let updated = updatePattern.stringByReplacingMatches(
                in: existing, range: range, withTemplate: "$1\(value)$3")
            return writeText(updated, to: sidecar)
        }

        // Branch 2: insert the attribute after the first <rdf:Description opening tag.
        if let tag = existing.range(of: "<rdf:Description") {
            var updated = existing
            updated.insert(contentsOf: "\n      xmp:Rating=\"\(value)\"", at: tag.upperBound)
            return writeText(updated, to: sidecar)
        }

        // Branch 3: malformed — overwrite with the template.
        return writeText(template(rating: value), to: sidecar)
    }

    private static func writeText(_ text: String, to url: URL) -> Bool {
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }
}
