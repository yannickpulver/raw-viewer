import SwiftUI

/// Menu bar mirror of the key table in spec 02 §1-2. The key dispatcher in `AppDelegate`
/// consumes these keystrokes first; the menu is for discoverability and for mouse-driven use of
/// the same actions.
///
/// Deliberately, **no bare-letter / digit / arrow / space / escape key equivalent is registered
/// here**. The dispatcher refuses to run while `NSApp.modalWindow != nil`, but a menu key
/// equivalent is matched by AppKit before any of that, so a bare `x` or `3` typed into an
/// `NSOpenPanel`'s filename field or at an `NSAlert` could still rate or reject a file. Those
/// keys therefore appear as plain text in the item title and only the `Cmd`-modified shortcuts —
/// which cannot be typed as text — stay real key equivalents.
struct AppCommands: Commands {
    let model: AppModel
    private var library: Library { model.library }

    /// `"Go to Start"` + `"S"` → `"Go to Start  (S)"`.
    private static func title(_ text: String, _ key: String) -> String {
        "\(text)  (\(key))"
    }

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { model.checkForUpdates() }
        }

        CommandGroup(replacing: .newItem) {
            Button("Open Folder…") { model.openFolderPanel() }
                .keyboardShortcut("o", modifiers: .command)
            Menu("Open Recent") {
                ForEach(library.recentFolders, id: \.self) { folder in
                    Button(folder.lastPathComponent) { library.openFolder(folder) }
                }
            }
            Divider()
            Button(Self.title("Close Folder", "Esc")) { model.escape() }
            Divider()
            Button(Self.title("Reveal in Finder", "O")) { library.revealInFinder() }
                .disabled(!model.filesLoaded)
            Button("Open All in Lightroom") { library.openInLightroom() }
                .keyboardShortcut("l", modifiers: .command)
                .disabled(!model.filesLoaded)
            Button("Export to DaVinci Resolve") { Task { await library.exportToResolve() } }
                .keyboardShortcut("d", modifiers: .command)
            Divider()
            Button("Move Rejected to _rejected") { model.moveRejected() }
                .keyboardShortcut(.delete, modifiers: .command)
            // Mac app addition: no Python-app equivalent.
            Button("Move Shown Files to Folder…") { model.moveShownFiles() }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .disabled(!model.filesLoaded)
        }

        CommandMenu("Rate") {
            ForEach(0...5, id: \.self) { value in
                Button(Self.title(value == 0 ? "Clear Rating" : "\(value) Star\(value == 1 ? "" : "s")",
                                  "\(value)")) {
                    library.rate(value)
                }
            }
            Button(Self.title("Reject", "X")) { library.toggleReject() }
                .disabled(!model.filesLoaded)
            Divider()
            ForEach(0...5, id: \.self) { value in
                Button(value == 0 ? "Filter: All" : "Filter: \(value)+") {
                    Task { await library.setRatingFilter(value) }
                }
                .keyboardShortcut(KeyEquivalent(Character("\(value)")), modifiers: .command)
            }
            // Mac app addition: an "unrated only" bucket alongside the filter values above.
            Button("Filter: Unrated") {
                Task { await library.setRatingFilter(RatingFilter.unratedValue) }
            }
            .keyboardShortcut("0", modifiers: [.command, .option])
        }

        CommandMenu("Navigate") {
            Button(Self.title("Previous", "←")) { library.navigate(by: -1) }
            Button(Self.title("Next", "→")) { library.navigate(by: 1) }
            Divider()
            Button(Self.title("Go to Start", "S")) { library.jumpToFirst() }
                .disabled(!model.filesLoaded)
            Button(Self.title("Go to End", "E")) { library.jumpToLast() }
                .disabled(!model.filesLoaded)
            Button(Self.title("Go to Last Rated", "⇧R")) { Task { await library.jumpToLastRated() } }
                .disabled(!model.filesLoaded)
        }

        CommandGroup(replacing: .toolbar) {
            Button(Self.title("Toggle Grid View", "G")) { library.toggleGrid() }
            Button(Self.title("Toggle Compare", "C")) { library.toggleCompare() }
            Button("Toggle Filmstrip") { library.toggleFilmstrip() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!model.filesLoaded)
            Button(Self.title("Toggle Info Overlay", "I")) { library.toggleInfo() }
            // Mac app addition: no Python-app equivalent.
            Toggle(Self.title("Show Faces", "F"), isOn: Binding(get: { library.showFaces },
                                                                set: { _ in library.toggleFaces() }))
                .disabled(!library.faceDetection)
            // Mac app addition: no Python-app equivalent.
            Toggle("Newest First", isOn: Binding(get: { library.newestFirst },
                                                  set: { _ in library.toggleNewestFirst() }))
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Divider()
            Button(Self.title("Rotate 90°", "R")) { model.rotate() }
                .disabled(!model.filesLoaded || model.isVideoMode)
            Button(Self.title(model.isVideoMode ? "Play / Pause" : "Zoom 2x", "Space")) {
                model.toggleSpace()
            }
            Divider()
            Button(Self.title("Toggle RAW / JPEG Mode", "J")) { library.switchViewMode(.jpeg, toggle: true) }
            Button(Self.title("Toggle Video Mode", "M")) { library.switchViewMode(.video, toggle: true) }
        }

        CommandGroup(replacing: .help) {
            Button(Self.title("Keyboard Shortcuts", "H")) { model.showHelp.toggle() }
            Button(Self.title("Shoot Stats", "T")) { model.showStats.toggle() }
        }
    }
}
