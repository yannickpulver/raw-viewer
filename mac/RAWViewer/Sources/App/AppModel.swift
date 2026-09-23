import AppKit
import Observation
import Sparkle
import SwiftUI
import UniformTypeIdentifiers

/// UI-side state and every user action. Both the menu bar and the key dispatcher call in here,
/// so the two can never drift apart.
@MainActor
@Observable
public final class AppModel {

    public static let shared = AppModel()

    public let library = Library()
    let video = VideoController()

    /// Checks the appcast at launch and every 24h, and shows Sparkle's own dialog. Local builds
    /// carry `CFBundleVersion` 1, so the scheduled check stays off in Debug.
    @ObservationIgnored
    private let updater = SPUStandardUpdaterController(
        startingUpdater: !AppModel.isDebug, updaterDelegate: nil, userDriverDelegate: nil)

    #if DEBUG
    private static let isDebug = true
    #else
    private static let isDebug = false
    #endif

    var showHelp = false
    var showStats = false
    /// Bumped to ask the focused canvas to rotate / toggle 2x. Spec 01 §15-16.
    var rotationToken = 0
    var compareRotationToken = 0
    var zoomToken = 0
    var statsTick = 0

    private init() {}

    var filesLoaded: Bool { !library.files.isEmpty }
    var isVideoMode: Bool { library.viewMode == .video }
    var isGrid: Bool { library.displayMode == .grid }

    // MARK: - Folder opening

    func openFolderPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = library.recentFolders.first ?? FileManager.default.homeDirectoryForCurrentUser
        guard panel.runModal() == .OK, let url = panel.url else { return }
        library.openFolder(url)
    }

    /// Only directories are accepted; the first one wins. Spec 02 §6.
    @discardableResult
    func openFirstDirectory(in urls: [URL]) -> Bool {
        var isDirectory: ObjCBool = false
        for url in urls where FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            if isDirectory.boolValue {
                library.openFolder(url)
                return true
            }
        }
        return false
    }

    // MARK: - Actions

    func rotate() {
        guard filesLoaded, !isVideoMode else { return }
        if library.isCompareActive, library.focusedPane == .left {
            compareRotationToken += 1
        } else {
            rotationToken += 1
        }
    }

    /// Spec 02 §1: `Space` is play/pause in video mode, 2x zoom otherwise.
    func toggleSpace() {
        if isVideoMode { video.togglePlay() } else { zoomToken += 1 }
    }

    /// Spec 02 §1-2, plus the mac app's overlays and multi-selection: help → stats →
    /// multi-selection → grid → compare → close the folder.
    func escape() {
        if showHelp { showHelp = false; return }
        if showStats { showStats = false; return }
        if library.clearMultiSelection() { return }
        if isGrid { library.toggleGrid(); return }
        if library.isCompareActive { library.exitCompare(); return }
        library.closeFolder()
    }

    func moveRejected() {
        Task {
            guard let prompt = await library.moveRejected() else { return }
            let alert = NSAlert()
            alert.messageText = prompt
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Yes")
            alert.addButton(withTitle: "No")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            await library.performMoveRejected()
        }
    }

    /// Mac app addition, mirroring `moveRejected()`. Prompts for a destination folder, then
    /// confirms before moving every file of the current filtered timeline into it.
    func moveShownFiles() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Move Here"
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        Task {
            guard let prompt = await library.moveShownPrompt(to: destination) else { return }
            let alert = NSAlert()
            alert.messageText = prompt
            alert.informativeText = "XMP sidecars move with their files. This can't be undone in the app."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Yes")
            alert.addButton(withTitle: "No")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            await library.performMoveShown(to: destination)
        }
    }

    func quit() {
        NSApp.terminate(nil)
    }

    func checkForUpdates() {
        updater.checkForUpdates(nil)
    }

    // MARK: - Key dispatch (spec 02 §1-2)

    private enum KeyCode {
        static let left: UInt16 = 123
        static let right: UInt16 = 124
        static let down: UInt16 = 125
        static let up: UInt16 = 126
        static let ret: UInt16 = 36
        static let enter: UInt16 = 76
        static let escape: UInt16 = 53
        static let space: UInt16 = 49
        static let backspace: UInt16 = 51
        /// Top-row `0`-`5` on the physical keyboard, so non-US layouts rate correctly.
        static let digits: [UInt16: Int] = [29: 0, 18: 1, 19: 2, 20: 3, 21: 4, 23: 5]
    }

    /// Physical key first (layout-independent), then the produced character as a fallback
    /// (numeric keypad, layouts that move the digit row).
    private func digit(keyCode: UInt16, characters: String) -> Int? {
        if let value = KeyCode.digits[keyCode] { return value }
        if let value = Int(characters), (0...5).contains(value) { return value }
        return nil
    }

    /// Returns `true` when the event was consumed.
    func handleKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        // Spec 02 §0: Cmd and Ctrl are interchangeable, and the match is exact equality.
        let command = modifiers == .command || modifiers == .control
        let bare = modifiers.isEmpty
        let shift = modifiers == .shift
        let key = event.keyCode
        let characters = event.charactersIgnoringModifiers?.lowercased() ?? ""

        // Escape's overlay / multi-selection / grid / compare / folder ladder runs before the
        // grid-mode refusal below, which would otherwise swallow it via KeyCode.escape.
        if key == KeyCode.escape { escape(); return true }

        // Grid mode gets first refusal.
        if isGrid {
            switch key {
            case KeyCode.right: library.gridMove(dx: 1, dy: 0); return true
            case KeyCode.left: library.gridMove(dx: -1, dy: 0); return true
            case KeyCode.down: library.gridMove(dx: 0, dy: 1); return true
            case KeyCode.up: library.gridMove(dx: 0, dy: -1); return true
            case KeyCode.ret, KeyCode.enter: library.toggleGrid(); return true
            case KeyCode.space where bare: return true
            default: break
            }
            if characters == "c", bare { return true }
            if characters == "s", command { return true }
        }

        // Command-modified bindings first, so `O` / `S` / digits keep their bare meaning.
        if command {
            switch characters {
            case "o": openFolderPanel(); return true
            case "l": guard filesLoaded else { return true }; library.openInLightroom(); return true
            case "d": Task { await library.exportToResolve() }; return true
            case "s": guard filesLoaded else { return true }; library.toggleFilmstrip(); return true
            case "a": guard filesLoaded else { return true }; library.selectAll(); return true
            case "q", "w": quit(); return true
            default: break
            }
            if key == KeyCode.backspace { moveRejected(); return true }
            if let value = digit(keyCode: key, characters: characters) {
                Task { await library.setRatingFilter(value) }
                return true
            }
        }

        if shift, characters == "r" {
            guard filesLoaded else { return true }
            Task { await library.jumpToLastRated() }
            return true
        }

        if bare {
            if let value = digit(keyCode: key, characters: characters) {
                library.rate(value)
                return true
            }
            switch characters {
            case "x": if filesLoaded { library.toggleReject() }; return true
            case "s": if filesLoaded { library.jumpToFirst() }; return true
            case "r": rotate(); return true
            case "c": library.toggleCompare(); return true
            case "g": library.toggleGrid(); return true
            default: break
            }
        }

        // Bindings that deliberately ignore modifiers. Spec 02 §1.
        switch key {
        case KeyCode.right: library.navigate(by: 1); return true
        case KeyCode.left: library.navigate(by: -1); return true
        case KeyCode.space: toggleSpace(); return true
        default: break
        }
        // Deviation from spec 02 (H / M ignore modifiers): on macOS `Cmd+H` hides the app,
        // `Cmd+M` minimises and `Cmd+,` opens preferences. Those belong to the system.
        if modifiers.contains(.command), ["h", "m", ","].contains(characters) { return false }

        switch characters {
        case "i": library.toggleInfo(); return true
        case "e": if filesLoaded { library.jumpToLast() }; return true
        case "o": if filesLoaded { library.revealInFinder() }; return true
        case "j": library.switchViewMode(.jpeg, toggle: true); return true
        case "m": library.switchViewMode(.video, toggle: true); return true
        case "h": showHelp.toggle(); return true
        case "t": showStats.toggle(); return true
        default: return false
        }
    }
}
