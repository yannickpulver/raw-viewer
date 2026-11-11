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
            // Same ladder as `Esc`: grid → single, compare → single, otherwise back to the dashboard.
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

    /// Verbatim from spec 01 §5, plus the Mac app additions (↑/↓, ⌥↑/⌥↓, ⌥⌘0, U, K, ⇧⌘M, ⇧⌘N, ⇧S, V, F).
    static let text = """
      ←/→         Navigate images
      ↑/↓         Previous/next scene
      ⌥↑/⌥↓     Previous/next day (also Page Up/Down)
      0-5          Rate current image
      X            Reject (toggle)
      ⌘0-5        Filter by rating
      ⌥⌘0         Filter unrated
      U            Unviewed only (not seen before)
      ⌘⌫          Move rejected to _rejected/
      ⇧⌘M         Move shown files to folder…
      ⇧⌘N         Toggle newest first

      S            Go to start
      E            Go to end
      ⇧R          Go to last rated
      R            Rotate 90°

      J            Toggle RAW/JPEG mode
      M            Toggle Video mode
      A            Toggle All files mode
      Space        Play/Pause video
      I            Toggle sidebar
      ⌘S          Toggle filmstrip
      G            Toggle grid view
      ⇧S          Group by scene (and stacks)
      K            Expand/collapse stack
      V            Duel: ← / → keeps one, ↓ both
      ⌘Z          Undo duel choice
      F            Toggle faces
      H            Toggle this help
      T            Toggle shoot stats

      C            Compare with pinned image
      O            Show in Finder
      ⌘L          Open all in Lightroom
      ⌘D          Export to DaVinci Resolve
      Esc          Close overlay, selection, grid, then folder
      ⌘Q          Quit

      ⇧Click       Select range (grid/filmstrip)
      ⌘Click      Toggle selection (grid/filmstrip)
      ⌘A          Select all
    """

    var body: some View {
        OverlayPanel(title: "Keyboard Shortcuts", onClose: onClose) {
            // A column-aligned key table: it stays monospaced.
            Text(Self.text)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.panelText)
                .lineSpacing(12 * 0.6)
                .fixedSize()
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
