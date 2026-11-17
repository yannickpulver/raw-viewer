import AppKit
import SwiftUI

// MARK: - Recent folders

/// The launch screen's left side: the recent folders as cards, each with its best photos, how
/// far it is rated and the drive it lives on. A folder on an unplugged drive keeps its place
/// and shows as offline. Nothing is rescanned: the numbers come from `folder_summaries.json`
/// and `shoot_stats.json`, the pictures from `FolderPicks`.
struct LaunchRecents: View {
    let model: AppModel
    var library: Library { model.library }

    /// Recents live in `UserDefaults`, which SwiftUI does not observe: bumped when a drive
    /// comes or goes and when a folder is removed, so the cards follow.
    @State private var revision = 0

    /// Mount, unmount and rename arrive on the workspace's own notification center.
    private var workspace: NotificationCenter { NSWorkspace.shared.notificationCenter }

    var body: some View {
        let _ = revision
        let folders = library.recentFolders

        VStack(alignment: .leading, spacing: 0) {
            if folders.isEmpty {
                firstLaunch
            } else {
                HStack {
                    Text("Recent")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 4)
                    Spacer()
                    Button {
                        model.openFolderPanel()
                    } label: {
                        Label("Open Folder…", systemImage: "folder")
                    }
                    .help("Open Folder (⌘O)")
                }
                .padding(.bottom, 12)

                VStack(spacing: 6) {
                    ForEach(folders, id: \.self) { folder in
                        RecentFolderCard(folder: folder,
                                         summary: library.folderSummary(for: folder),
                                         elapsed: ShootStats.load(folder: folder)?.elapsed,
                                         picks: library.folderPicks(for: folder),
                                         reachable: RecentFolders.isReachable(folder),
                                         open: { open(folder) },
                                         remove: {
                                             library.removeRecent(folder)
                                             revision &+= 1
                                         })
                    }
                }
            }
        }
        .frame(maxWidth: 520)
        .padding(.horizontal, 24)
        .padding(.bottom, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { library.reloadFolderSummaries() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            revision &+= 1
        }
        .onReceive(workspace.publisher(for: NSWorkspace.didMountNotification)) { _ in revision &+= 1 }
        .onReceive(workspace.publisher(for: NSWorkspace.didUnmountNotification)) { _ in revision &+= 1 }
        .onReceive(workspace.publisher(for: NSWorkspace.didRenameVolumeNotification)) { _ in revision &+= 1 }
    }

    private var firstLaunch: some View {
        VStack(spacing: 12) {
            Button {
                model.openFolderPanel()
            } label: {
                Label("Open Folder", systemImage: "folder")
                    .font(.system(size: 15, weight: .medium))
                    .padding(.horizontal, 14).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Text("or drop a folder anywhere in this window")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func open(_ folder: URL) {
        guard RecentFolders.isReachable(folder) else {
            library.post(SnackbarEvent(text: "Connect \(RecentFolders.driveName(folder)) to open this folder",
                                       durationMs: 2500))
            revision &+= 1
            return
        }
        library.openFolder(folder)
    }
}

/// One recent folder: its best photos, name and drive, progress line and rating bar.
struct RecentFolderCard: View {
    let folder: URL
    let summary: FolderSummary?
    let elapsed: Double?
    let picks: [CGImage]
    let reachable: Bool
    let open: () -> Void
    let remove: () -> Void

    @State private var hovering = false

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    var body: some View {
        Button(action: open) {
            HStack(spacing: 11) {
                PicksStrip(picks: picks)
                    .opacity(reachable ? 1 : 0.35)
                    .saturation(reachable ? 1 : 0.2)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(folder.lastPathComponent)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(reachable ? .primary : .secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                        DriveLabel(name: RecentFolders.driveName(folder), reachable: reachable)
                    }
                    progressLine
                        .opacity(reachable ? 1 : 0.6)
                    if let summary, summary.total > 0 {
                        RatingBar(summary: summary)
                            .frame(width: 160, height: 4)
                            .opacity(reachable ? 1 : 0.35)
                            .padding(.top, 2)
                    }
                }
            }
            .padding(.vertical, 7)
            .padding(.leading, 7)
            .padding(.trailing, 10)
            .contentShape(RoundedRectangle(cornerRadius: Theme.chromeCornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .background {
            let shape = RoundedRectangle(cornerRadius: Theme.chromeCornerRadius, style: .continuous)
            if reachable {
                shape.fill(Color.white.opacity(hovering ? 0.12 : 0.06))
                    .overlay(shape.strokeBorder(Theme.chromeStroke, lineWidth: Theme.chromeStrokeWidth))
            } else {
                shape.fill(Color.white.opacity(hovering ? 0.05 : 0.025))
                    .overlay(shape.strokeBorder(Color.white.opacity(0.18),
                                                style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            }
        }
        .onHover { hovering = $0 }
        .pointingHandCursor()
        .help(reachable ? folder.path : "Connect \(RecentFolders.driveName(folder)) to open \(folder.path)")
        .contextMenu {
            Button("Remove from Recents", action: remove)
        }
    }

    @ViewBuilder
    private var progressLine: some View {
        HStack(spacing: 5) {
            if let summary, summary.total > 0 {
                let unrated = summary.rated(stars: Rating.unrated)
                if unrated == 0 {
                    Label("Done", systemImage: "checkmark.circle")
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(Color(nsColor: .systemGreen))
                } else {
                    Text("\(summary.total - unrated) / \(summary.total) rated")
                }
                if let elapsed, elapsed >= 60 {
                    Text("·")
                    Text(Self.duration(elapsed))
                }
                Text("·")
                Text(Self.relative.localizedString(for: summary.updatedAt, relativeTo: Date()))
            } else {
                Text(folder.deletingLastPathComponent().path)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
        .font(.system(size: 11).monospacedDigit())
        .foregroundStyle(.secondary)
    }

    /// "2h 41m", "38m".
    static func duration(_ seconds: Double) -> String {
        let minutes = Int(seconds) / 60
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }
}

/// Up to three pictures: one wide, two narrow. Grey placeholders until the folder has picks.
private struct PicksStrip: View {
    let picks: [CGImage]
    private static let widths: [CGFloat] = [40, 26, 26]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<Self.widths.count, id: \.self) { index in
                let shape = RoundedRectangle(cornerRadius: 3, style: .continuous)
                Group {
                    if index < picks.count {
                        Image(decorative: picks[index], scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Color.white.opacity(0.06)
                    }
                }
                .frame(width: Self.widths[index], height: 40)
                .clipShape(shape)
            }
        }
    }
}

private struct DriveLabel: View {
    let name: String
    let reachable: Bool

    var body: some View {
        Label(reachable ? name : "\(name) · offline",
              systemImage: !reachable ? "externaldrive.badge.xmark"
                  : name == "This Mac" ? "laptopcomputer" : "externaldrive")
            .labelStyle(.titleAndIcon)
            .font(.system(size: 10.5))
            .foregroundStyle(reachable ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Theme.amberBorder))
            .lineLimit(1)
            .fixedSize()
    }
}

/// The rating histogram as one bar: stars in gold (brighter for more), rejected in red,
/// unrated as the empty track.
private struct RatingBar: View {
    let summary: FolderSummary

    var body: some View {
        GeometryReader { geometry in
            let total = CGFloat(max(summary.total, 1))
            let segments: [(Int, Color)] = (1...5).reversed().map { stars in
                (summary.rated(stars: stars), Theme.ratingDot.opacity(0.4 + 0.15 * Double(stars - 1)))
            } + [(summary.rated(stars: Rating.rejected), Theme.rejectRed)]
            HStack(spacing: 0) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    if segment.0 > 0 {
                        segment.1.frame(width: geometry.size.width * CGFloat(segment.0) / total)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .background(Color.white.opacity(0.1))
        .clipShape(Capsule())
    }
}

// MARK: - Session panel

/// The launch screen's right side, in the photo sidebar's place and look: what you set
/// before opening a folder.
struct SessionPanel: View {
    let model: AppModel
    var library: Library { model.library }
    var remote: RemoteRating { model.remote }

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    private static let shortcuts: [(keys: String, label: String)] = [
        ("0–5", "Rate"),
        ("X", "Reject"),
        ("G", "Grid / Single"),
        ("V", "Duel"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SidebarSection(title: "Analysis", symbol: "face.smiling") {
                VStack(alignment: .leading, spacing: 6) {
                    switchRow("Detect faces", isOn: Binding(get: { library.faceDetection },
                                                            set: { library.faceDetection = $0 }))
                    caption("On this Mac, for every folder you open. F shows or hides them.")
                }
            }
            SidebarSection(title: "Rate on Phone", symbol: "iphone") {
                phone
            }
            SidebarSection(title: "Shortcuts", symbol: "keyboard") {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                    ForEach(Self.shortcuts, id: \.keys) { shortcut in
                        GridRow {
                            KeyCap(text: shortcut.keys)
                            Text(shortcut.label).foregroundStyle(.secondary)
                        }
                    }
                    GridRow {
                        KeyCap(text: "H")
                        Button("All shortcuts") { model.showHelp = true }
                            .buttonStyle(.link)
                    }
                }
                .font(.system(size: 12))
            }
            Spacer(minLength: 0)
            Text("v\(version)")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.tertiary)
                .padding(.leading, 4)
        }
        .padding(.horizontal, 14).padding(.top, 24).padding(.bottom, 14)
        .focusEffectDisabled()
        .frame(width: Theme.sidebarWidth)
        .floatingPanel()
    }

    @ViewBuilder
    private var phone: some View {
        switch remote.status {
        case .running(let url):
            HStack(spacing: 12) {
                if let qr = QRCode.image(for: url.absoluteString) {
                    Image(decorative: qr, scale: 1)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 66, height: 66)
                        .padding(4)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 4))
                }
                VStack(alignment: .leading, spacing: 4) {
                    caption("Scan to rate your recent folders from your phone, over Tailscale.")
                    Text(url.host ?? url.absoluteString)
                        .font(.system(size: 11).monospaced())
                        .foregroundStyle(Theme.panelText)
                        .textSelection(.enabled)
                }
            }
        default:
            VStack(alignment: .leading, spacing: 6) {
                switchRow("Rate on phone", isOn: Binding(get: { remote.isEnabled },
                                                         set: { remote.setEnabled($0) }))
                if case .failed(let reason) = remote.status {
                    caption(reason)
                } else if case .starting = remote.status {
                    caption("Starting…")
                } else {
                    caption("Rate your recent folders from a phone in your Tailscale network.")
                }
            }
        }
    }

    /// Label left, switch right, as in the sidebar's cards.
    private func switchRow(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(title).font(.system(size: 13))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch)
        .controlSize(.small)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct KeyCap: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .medium).monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4).padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.white.opacity(0.2), lineWidth: 0.5))
    }
}
