import AppKit
import SwiftUI

// MARK: - Window toolbar (spec 01 §4)

/// The unified window toolbar: Back at the leading edge (after the traffic lights, which live
/// in the same bar), the sidebar toggle at the trailing edge. Everything else lives in the
/// sidebar; while it is closed, an active rating filter shows as a badge next to the toggle.
/// Toolbar items get Liquid Glass for free on macOS 26, so nothing here wraps itself in
/// `chromeSurface`.
struct MainToolbar: ToolbarContent {
    let model: AppModel
    var library: Library { model.library }

    var body: some ToolbarContent {
        if library.folder != nil {
            // Same ladder as `Esc`: duel / compare → single → grid → back to the dashboard.
            ToolbarItem(placement: .navigation) {
                Button { model.escape() } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .help("Back (Esc)")
            }
            // Pushes the rest to the trailing edge; default items otherwise pack leading.
            if #available(macOS 26, *) {
                ToolbarSpacer(.flexible)
            } else {
                ToolbarItem { Spacer() }
            }
            if !library.showSidebar, let text = library.filterBadgeText {
                ToolbarItem { FilterBadge(text: text) }
            }
            // While the sidebar is open, the toggle sits in the panel's top-right corner, so it
            // drops its own glass and reads as part of the panel.
            if #available(macOS 26, *) {
                ToolbarItem { sidebarToggle }
                    .sharedBackgroundVisibility(library.showSidebar ? .hidden : .visible)
            } else {
                ToolbarItem { sidebarToggle }
            }
        }
    }

    private var sidebarToggle: some View {
        Button { library.toggleSidebar() } label: {
            Label("Sidebar", systemImage: "sidebar.right")
        }
        .help(library.showSidebar ? "Hide sidebar (I)" : "Show sidebar (I)")
    }
}

/// The active rating filter, as a compact amber capsule (`≥3★ · 42/137`).
struct FilterBadge: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold).monospacedDigit())
            .foregroundStyle(.black)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Theme.amber, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.amberBorder.opacity(0.7), lineWidth: 0.5))
            // Room between the capsule and the toolbar item's glass pill.
            .padding(.horizontal, 4)
    }
}

// MARK: - Loading progress

/// `Loading: 42%` at the image area's top-right corner while the background sweep runs.
/// Spec 01 §4: shown whether or not the sidebar is open.
struct LoadingBadge: View {
    let library: Library
    /// Height of the window toolbar; `0` when there is none (full screen with a hidden bar).
    let toolbarHeight: CGFloat

    var body: some View {
        let fraction = library.scheduler.progressFraction
        if !library.files.isEmpty && fraction < 1 {
            Text("Loading: \(Int(fraction * 100))%")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(Theme.dimText)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .chromeSurface(.regularMaterial, cornerRadius: 6, scrim: 0.45)
                .allowsHitTesting(false)
                .padding(.top, toolbarHeight + 10).padding(.trailing, 10)
        }
    }
}

// MARK: - Bottom-left buttons

struct CornerButtons: View {
    let model: AppModel
    var body: some View {
        HStack(spacing: 6) {
            ChromeToggleButton(symbol: "questionmark", isOn: model.showHelp,
                               helpText: "Keyboard shortcuts (H)") {
                model.showHelp.toggle()
            }
            ChromeToggleButton(symbol: "stopwatch", isOn: model.showStats,
                               helpText: "Shoot stats (T)") {
                model.showStats.toggle()
            }
        }
        .padding(4)
        .chromeSurface(.regularMaterial, glass: false)
        // Keys go through the app's dispatcher, so no button here should show a focus ring.
        .focusEffectDisabled()
        .padding(10)
    }
}

// MARK: - Snackbar / Resolve status

struct SnackbarView: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(Theme.panelText)
            .padding(.horizontal, 16).padding(.vertical, 8)
            .chromeSurface(.regularMaterial)
            .padding(.bottom, 20)
    }
}

struct ResolveStatusView: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 12).monospacedDigit())
            .foregroundStyle(Theme.panelText)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16).padding(.vertical, 8)
            .chromeSurface(.regularMaterial)
    }
}

// MARK: - Help and stats overlays

private struct OverlayPanel<Content: View>: View {
    let title: String
    let onClose: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 20) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.panelText)
                Spacer(minLength: 0)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .foregroundStyle(Theme.dimText)
            }
            content
        }
        .padding(EdgeInsets(top: 16, leading: 20, bottom: 20, trailing: 16))
        .chromeSurface(.regularMaterial, cornerRadius: 12, scrim: 0.72)
        .shadow(color: .black.opacity(0.45), radius: 20, y: 6)
        .fixedSize()
    }
}

struct HelpOverlay: View {
    let onClose: () -> Void
    @State private var query = ""

    private struct Shortcut: Identifiable {
        let keys: String
        let label: String
        var id: String { keys + label }
    }

    private struct Section: Identifiable {
        let title: String
        let items: [Shortcut]
        var id: String { title }
    }

    /// Spec 01 §5, plus the Mac app additions (↑/↓, ⌥↑/⌥↓, ⌥⌘0, U, K, ⇧⌘M, ⇧⌘N, ⇧S, V, F).
    private static let sections: [Section] = [
        Section(title: "Navigate", items: [
            Shortcut(keys: "← →", label: "Previous / next image"),
            Shortcut(keys: "↑ ↓", label: "Previous / next scene"),
            Shortcut(keys: "⌥↑ ⌥↓  ⇞ ⇟", label: "Previous / next day"),
            Shortcut(keys: "S", label: "Go to start"),
            Shortcut(keys: "E", label: "Go to end"),
            Shortcut(keys: "⇧R", label: "Go to last rated"),
        ]),
        Section(title: "Rate & Filter", items: [
            Shortcut(keys: "0–5", label: "Rate current image"),
            Shortcut(keys: "X", label: "Reject (toggle)"),
            Shortcut(keys: "⌘0–5", label: "Filter by rating"),
            Shortcut(keys: "⌥⌘0", label: "Filter unrated"),
            Shortcut(keys: "U", label: "Unviewed only"),
            Shortcut(keys: "⇧⌘N", label: "Newest first"),
        ]),
        Section(title: "View", items: [
            Shortcut(keys: "G", label: "Grid view"),
            Shortcut(keys: "J", label: "RAW / JPEG mode"),
            Shortcut(keys: "M", label: "Video mode"),
            Shortcut(keys: "A", label: "All files mode"),
            Shortcut(keys: "⇧S", label: "Group by scene (and stacks)"),
            Shortcut(keys: "K", label: "Expand / collapse stack"),
            Shortcut(keys: "Space", label: "Play / pause video, zoom 2×"),
            Shortcut(keys: "R", label: "Rotate 90°"),
            Shortcut(keys: "C", label: "Compare with pinned image"),
            Shortcut(keys: "V", label: "Duel: ← → keep one, ↓ both"),
            Shortcut(keys: "⌘Z", label: "Undo duel choice"),
            Shortcut(keys: "F", label: "Faces"),
            Shortcut(keys: "I", label: "Sidebar"),
            Shortcut(keys: "⌘S", label: "Filmstrip"),
        ]),
        Section(title: "Files", items: [
            Shortcut(keys: "⌘⌫", label: "Move rejected to _rejected/"),
            Shortcut(keys: "⇧⌘M", label: "Move shown files to folder…"),
            Shortcut(keys: "O", label: "Show in Finder"),
            Shortcut(keys: "⌘L", label: "Open all in Lightroom"),
            Shortcut(keys: "⌘D", label: "Export to DaVinci Resolve"),
        ]),
        Section(title: "Selection", items: [
            Shortcut(keys: "⇧Click", label: "Select range"),
            Shortcut(keys: "⌘Click", label: "Toggle selection"),
            Shortcut(keys: "⌘A", label: "Select all"),
        ]),
        Section(title: "App", items: [
            Shortcut(keys: "H", label: "Keyboard shortcuts"),
            Shortcut(keys: "T", label: "Shoot stats"),
            Shortcut(keys: "Esc", label: "Up a level"),
            Shortcut(keys: "⌘Q", label: "Quit"),
        ]),
    ]

    /// Matches the label, the key ("x", "⌘d") or the section title ("files").
    private var filtered: [Section] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return Self.sections }
        return Self.sections.compactMap { section in
            if section.title.localizedCaseInsensitiveContains(q) { return section }
            let items = section.items.filter {
                $0.label.localizedCaseInsensitiveContains(q) || $0.keys.localizedCaseInsensitiveContains(q)
            }
            return items.isEmpty ? nil : Section(title: section.title, items: items)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Shortcuts")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.panelText)
                Spacer(minLength: 0)
                Button(action: onClose) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .foregroundStyle(.secondary)
                    .help("Close (Esc)")
            }
            .padding(.leading, 4)
            SearchField(text: $query, placeholder: "Search")
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(filtered) { section in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(section.title)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(.bottom, 2)
                            ForEach(section.items) { item in
                                HStack(spacing: 12) {
                                    Text(item.label)
                                        .foregroundStyle(Theme.panelText)
                                    Spacer(minLength: 0)
                                    Text(item.keys)
                                        .foregroundStyle(Theme.dimText)
                                }
                                .font(.system(size: 12))
                                .padding(.vertical, 2)
                            }
                        }
                    }
                    if filtered.isEmpty {
                        Text("No shortcuts")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                }
                .padding(.horizontal, 4)
            }
            .scrollIndicators(.automatic)
        }
        .padding(10)
        .frame(width: 320, height: 420)
        .chromeSurface(.regularMaterial, cornerRadius: 12, scrim: 0.72, glass: false)
        .shadow(color: .black.opacity(0.45), radius: 20, y: 6)
    }
}

/// AppKit's search field: magnifier, clear button, Esc clears. It takes focus when it appears,
/// so typing filters right away; the key monitor lets keys through while a text field edits.
private struct SearchField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        field.controlSize = .regular
        field.focusRingType = .none
        DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        if field.stringValue != text { field.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSSearchField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}

struct StatsOverlay: View {
    let lines: [String]
    let onClose: () -> Void

    var body: some View {
        OverlayPanel(title: "Shoot Stats", onClose: onClose) {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    // Space-padded columns: monospaced, like the help table.
                    Text(line)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Theme.panelText)
                }
            }
            .frame(minWidth: 280, alignment: .leading)
        }
    }
}

// MARK: - Empty state

struct EmptyStateView: View {
    let model: AppModel

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                Button {
                    model.openFolderPanel()
                } label: {
                    Label("Open Folder", systemImage: "folder")
                        .font(.system(size: 15, weight: .medium))
                        .padding(.horizontal, 14).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                VStack(spacing: 6) {
                    ForEach(model.library.recentFolders, id: \.self) { folder in
                        RecentFolderCard(folder: folder,
                                         summary: model.library.folderSummary(for: folder)) {
                            model.library.openFolder(folder)
                        }
                    }
                }
                .padding(.top, 25)
            }
            .offset(y: -40)
            .onAppear { model.library.reloadFolderSummaries() }

            VStack(spacing: 10) {
                Spacer()
                // Mac app addition: one switch for every folder. `F` then shows / hides them.
                Toggle(isOn: Binding(get: { model.library.faceDetection },
                                     set: { model.library.faceDetection = $0 })) {
                    Text("Detect faces")
                        .font(.system(size: 12))
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .help("Finds faces in every folder you open, on this Mac. Press F to show or hide them.")
                Text("v\(version)")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .padding(.bottom, 10)
            }
        }
    }
}

/// One recent folder on the dashboard: name, kind counts and the rating histogram exactly as
/// they were when the folder was last open. Nothing is rescanned — the numbers come from
/// `folder_summaries.json`.
struct RecentFolderCard: View {
    let folder: URL
    let summary: FolderSummary?
    let action: () -> Void

    @State private var hovering = false

    private static let kinds: [MediaKind] = [.raw, .jpeg, .video]

    private var kindLine: String? {
        guard let summary else { return nil }
        let parts = Self.kinds
            .filter { summary.count(for: $0) > 0 }
            .map { "\(summary.count(for: $0)) \($0.buttonLabel)" }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text(folder.lastPathComponent)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                if let kindLine {
                    Text(kindLine)
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if let summary, !summary.ratings.isEmpty {
                    RatingPills(summary: summary)
                }
            }
            .frame(width: 420, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(RoundedRectangle(cornerRadius: Theme.chromeCornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .background {
            let shape = RoundedRectangle(cornerRadius: Theme.chromeCornerRadius, style: .continuous)
            shape.fill(Color.white.opacity(hovering ? 0.12 : 0.06))
                .overlay(shape.strokeBorder(Theme.chromeStroke, lineWidth: Theme.chromeStrokeWidth))
        }
        .onHover { hovering = $0 }
        .pointingHandCursor()
        .help(folder.path)
    }
}

/// The rating histogram as compact pills, highest stars first, then rejected, then unrated.
private struct RatingPills: View {
    let summary: FolderSummary

    var body: some View {
        HStack(spacing: 5) {
            ForEach(Array(stride(from: 5, through: 1, by: -1)), id: \.self) { stars in
                if summary.rated(stars: stars) > 0 {
                    pill {
                        Text("★\(stars)").foregroundStyle(Theme.ratingDot)
                        Text("×\(summary.rated(stars: stars))").foregroundStyle(.secondary)
                    }
                }
            }
            if summary.rated(stars: Rating.rejected) > 0 {
                pill {
                    Text("✕").foregroundStyle(Theme.rejectRed)
                    Text("\(summary.rated(stars: Rating.rejected))").foregroundStyle(.secondary)
                }
            }
            if summary.rated(stars: Rating.unrated) > 0 {
                pill {
                    Text("unrated \(summary.rated(stars: Rating.unrated))")
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 10, weight: .medium).monospacedDigit())
    }

    private func pill<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 3, content: content)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.white.opacity(0.09), in: Capsule())
    }
}

struct ScanningLabel: View {
    let text: String
    var body: some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.small)
            Text(text)
                .font(.system(size: 13).monospacedDigit())
                .foregroundStyle(Theme.panelText)
        }
        .padding(.horizontal, 24).padding(.vertical, 14)
        .chromeSurface(.regularMaterial)
    }
}

// MARK: - Helpers

private struct PointingHandCursor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = CursorView()
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class CursorView: NSView {
        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .pointingHand)
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

extension View {
    func pointingHandCursor() -> some View {
        overlay(PointingHandCursor())
    }
}
