import AppKit
import SwiftUI

// MARK: - Window toolbar (spec 01 §4)

/// The unified window toolbar: the mode switcher and the subfolder chips at the leading edge
/// (after the traffic lights, which now live in the same bar), the active rating filter at the
/// trailing edge. Toolbar items get Liquid Glass for free on macOS 26, so nothing here wraps
/// itself in `chromeSurface`.
struct MainToolbar: ToolbarContent {
    let model: AppModel
    var library: Library { model.library }

    private var anyModeHasFiles: Bool {
        MediaKind.allCases.contains { library.modeButtonVisible($0) }
    }

    var body: some ToolbarContent {
        if library.folder != nil {
            // Same ladder as `Esc`: grid → single, compare → single, otherwise back to the dashboard.
            ToolbarItem(placement: .navigation) {
                Button { model.escape() } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .help("Back (Esc)")
            }
            // Items of one placement share a glass group on macOS 26. Back is the only
            // `.navigation` item and the spacer closes its group, so it gets its own capsule.
            if #available(macOS 26, *) {
                ToolbarSpacer(.fixed)
            }
        }
        if anyModeHasFiles {
            ToolbarItem { modePicker }
        }
        if library.showsSubfolderChips {
            // One toolbar item per chip, so each is a native toolbar toggle with the system's
            // own backing instead of a bordered button nested inside another item. A group
            // splits its views into items; `ForEach` as toolbar content needs a newer SDK.
            ToolbarItemGroup {
                chip(title: "All (\(library.allChipCount))", folder: nil)
                ForEach(library.subfolderChips(), id: \.name) { chip in
                    self.chip(title: "\(chip.name) (\(chip.count))", folder: chip.name)
                        .opacity(chip.excluded ? 0.5 : 1)
                        .help(chip.excluded ? "Right-click to include in All"
                                            : "Right-click to exclude from All")
                        .contextMenu {
                            Button(chip.excluded ? "Include in All" : "Exclude from All") {
                                library.toggleExcluded(chip.name)
                            }
                        }
                }
            }
        }
        if let text = library.filterBadgeText {
            // Pushes the badge to the trailing edge; default items otherwise pack leading.
            if #available(macOS 26, *) {
                ToolbarSpacer(.flexible)
            } else {
                ToolbarItem { Spacer() }
            }
            ToolbarItem { FilterBadge(text: text) }
        }
    }

    private var modePicker: some View {
        // The setter routes through `switchViewMode(_:toggle: false)`, which is the
        // mode-button semantics: a direct switch that is ignored for an empty mode.
        // Modes with no files have no segment at all, so they cannot be picked.
        let mode = Binding<MediaKind>(
            get: { library.viewMode },
            set: { library.switchViewMode($0, toggle: false) })

        // Default control size: the toolbar styles a regular segmented picker as its own item;
        // a `.small` one ends up as a second bezel floating inside the item's backing.
        return Picker("View mode", selection: mode) {
            ForEach(MediaKind.allCases, id: \.self) { kind in
                if library.modeButtonVisible(kind) {
                    Text(library.modeButtonLabel(kind)).tag(kind)
                }
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    /// A subfolder chip: on while it is the active folder filter. Turning the active chip
    /// "off" just re-selects it, so the binding's setter ignores the new value.
    private func chip(title: String, folder: String?) -> some View {
        Toggle(title, isOn: Binding(
            get: { library.folderFilter == folder },
            set: { _ in library.setFolderFilter(folder) }))
        .toggleStyle(.button)
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

// MARK: - Banners

struct UpdateBanner: View {
    let info: UpdateInfo
    var body: some View {
        Button {
            NSWorkspace.shared.open(info.url)
        } label: {
            Text("Update available: \(info.version)")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Theme.updateGreen, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.2), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        // Sits in the bottom-left row, right of the corner buttons, which supply the gap.
        .padding(.vertical, 10)
    }
}

// MARK: - Top-right info block

struct InfoBlock: View {
    let model: AppModel
    var library: Library { model.library }

    var body: some View {
        let fraction = library.scheduler.progressFraction
        VStack(alignment: .trailing, spacing: 0) {
            if library.showInfo && !library.files.isEmpty {
                Text(library.positionText)
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white)
                    .chromeTextShadow()
                    .padding(.horizontal, 12).padding(.vertical, 6)
                Text(library.infoText)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.white)
                    .chromeTextShadow()
                    .padding(.horizontal, 12).padding(.vertical, 6)
            }
            // Spec 01 §4: deliberately not gated on showInfo.
            if !library.files.isEmpty && fraction < 1 {
                Text("Loading: \(Int(fraction * 100))%")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Theme.dimText)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .chromeSurface(.regularMaterial, cornerRadius: 6, scrim: 0.45)
            }
        }
        .padding(.top, 10).padding(.trailing, 10)
    }
}

// MARK: - Bottom toolbars

struct FilterToolbar: View {
    let model: AppModel
    var library: Library { model.library }

    var body: some View {
        // `setRatingFilter` is async (it sweeps every rating off disk first), so the setter
        // hands the work to a Task instead of mutating anything itself.
        let filter = Binding<Int>(
            get: { library.ratingFilter.value },
            set: { value in Task { await library.setRatingFilter(value) } })

        HStack(spacing: 10) {
            Button { model.openFolderPanel() } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Open folder…")

            Picker("Rating filter", selection: filter) {
                Text("All").tag(0)
                Text("0").tag(RatingFilter.unratedValue)
                Text("1+").tag(1)
                Text("2+").tag(2)
                Text("3+").tag(3)
                Text("4+").tag(4)
                Text("5").tag(5)
                Image(systemName: "xmark").tag(-1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
        }
        // The toolbar sits straight on the photo, so it gets its own material backing
        // rather than relying on the controls' own translucency.
        .padding(4)
        .chromeSurface(.regularMaterial, glass: false)
        .padding(10)
    }
}

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

    /// Verbatim from spec 01 §5, plus the two Mac app additions (⌥⌘0, ⇧⌘M).
    static let text = """
      ←/→         Navigate images
      0-5          Rate current image
      X            Reject (toggle)
      ⌘0-5        Filter by rating
      ⌥⌘0         Filter unrated
      ⌘⌫          Move rejected to _rejected/
      ⇧⌘M         Move shown files to folder…

      S            Go to start
      E            Go to end
      ⇧R          Go to last rated
      R            Rotate 90°

      J            Toggle RAW/JPEG mode
      M            Toggle Video mode
      Space        Play/Pause video
      I            Toggle info overlay
      ⌘S          Toggle filmstrip
      G            Toggle grid view
      H            Toggle this help
      T            Toggle shoot stats

      C            Compare with pinned image
      O            Show in Finder
      ⌘L          Open all in Lightroom
      ⌘D          Export to DaVinci Resolve
      Esc          Close folder
      ⌘Q          Quit
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

            VStack {
                Spacer()
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
