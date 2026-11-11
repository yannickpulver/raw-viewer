import SwiftUI

/// The right sidebar (`I`): what the timeline shows, what is on screen, and the faces. A
/// floating panel beside the image area; the filmstrip keeps the full window width underneath.
struct Sidebar: View {
    let model: AppModel
    var library: Library { model.library }

    /// Height of the window toolbar; `0` when there is none (full screen with a hidden bar).
    @State private var toolbarHeight: CGFloat = 0

    /// The Filter section's title sits in the toolbar row, on the line of the sidebar toggle.
    /// Without a toolbar row it falls back into the list.
    private var titleInToolbarRow: Bool { toolbarHeight >= 20 }

    private static let contentPadding: CGFloat = 14
    private static let filterTitle = "Filter"
    private static let filterSymbol = "line.3.horizontal.decrease"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                DisplaySwitch(library: library)
                SidebarSection(title: titleInToolbarRow ? nil : Self.filterTitle, symbol: Self.filterSymbol) {
                    FilterControls(library: library)
                }
                if library.dayList.count > 1 {
                    SidebarSection(title: "Days", symbol: "calendar") {
                        DayList(library: library)
                    }
                }
                if let file = library.currentFile {
                    SidebarSection(title: "Photo", symbol: "photo") {
                        PhotoInfo(library: library, file: file)
                    }
                }
                if library.showsFaces, let file = library.currentFile {
                    SidebarSection(title: "Faces", symbol: "face.smiling") {
                        FacePanel(model: model, file: file)
                    }
                }
            }
            // A fixed column: a scroll view sizes its content by the content's ideal width,
            // so one wide control (a segmented picker cannot shrink) would widen every section
            // past the panel's edges.
            .frame(width: Theme.sidebarWidth - 2 * Self.contentPadding)
            .padding(.horizontal, Self.contentPadding).padding(.bottom, 14).padding(.top, 4)
        }
        // Keys go through the app's dispatcher, so no control here should show a focus ring.
        .focusEffectDisabled()
        .frame(width: Theme.sidebarWidth)
        // Inside the safe area this reader reports the toolbar's height.
        .background {
            GeometryReader { geometry in
                Color.clear
                    .onAppear { toolbarHeight = geometry.safeAreaInsets.top }
                    .onChange(of: geometry.safeAreaInsets.top) { _, new in toolbarHeight = new }
            }
        }
        // Text only, drawn above the list in the toolbar row: clicks and window drags there
        // still reach the toolbar.
        .overlay(alignment: .topLeading) {
            if titleInToolbarRow {
                SectionHeader(title: Self.filterTitle, symbol: Self.filterSymbol)
                    .padding(.horizontal, 14)
                    .frame(height: toolbarHeight)
                    .offset(y: -toolbarHeight)
                    .allowsHitTesting(false)
            }
        }
        // A floating panel: rounded and inset from the window edges. It still takes its own
        // column, so the image area ends to its left instead of running underneath. The panel
        // reaches up into the toolbar row, where the toolbar's sidebar toggle sits in its
        // top-right corner; the controls stay below the toolbar, where they get the clicks.
        .background {
            panelShape
                .fill(Theme.sidebarBackground)
                .overlay(panelShape.strokeBorder(Theme.chromeStroke, lineWidth: Theme.chromeStrokeWidth))
                .shadow(color: .black.opacity(0.5), radius: 12, y: 4)
                .padding(.top, Theme.sidebarInset)
                .ignoresSafeArea(edges: .top)
        }
        .padding([.horizontal, .bottom], Theme.sidebarInset)
    }

    private var panelShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
    }
}

private struct SectionHeader: View {
    let title: String
    let symbol: String

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
    }
}

/// A rounded panel, with its symbol and title above it unless the title sits elsewhere
/// (the Filter section's lives in the toolbar row). As in Print Lab's inspector.
private struct SidebarSection<Content: View>: View {
    var title: String? = nil
    var symbol: String = ""
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                SectionHeader(title: title, symbol: symbol)
            }
            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}

/// A caption above its control, full width.
private struct SidebarRow<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            content
        }
    }
}

// MARK: - Photo

private struct PhotoInfo: View {
    let library: Library
    let file: MediaFile

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(library.positionText)
                .font(.system(size: 15, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
            Text(file.name)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.9))
                .truncationMode(.middle)
                .textSelection(.enabled)
            Text(library.captureDateText)
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
        RatingPicker(rating: library.rating(for: file.url),
                     rate: { library.rate($0) },
                     reject: { library.toggleReject() })
            // The duel decides ratings itself and swallows the rating keys too.
            .disabled(library.displayMode == .duel)
    }
}

/// Five clickable stars and a reject toggle. Clicking the current star clears the rating.
/// Like the keys, a click advances to the next frame.
private struct RatingPicker: View {
    let rating: Int
    let rate: (Int) -> Void
    let reject: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { stars in
                Button { rate(stars == rating ? 0 : stars) } label: {
                    Image(systemName: stars <= rating ? "star.fill" : "star")
                        .foregroundStyle(stars <= rating ? Theme.ratingDot : Color.white.opacity(0.45))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .help("\(stars) star\(stars == 1 ? "" : "s") (\(stars))")
            }
            Spacer(minLength: 0)
            let rejected = rating == Rating.rejected
            Button(action: reject) {
                Image(systemName: rejected ? "xmark.circle.fill" : "xmark.circle")
                    .foregroundStyle(rejected ? Theme.rejectRed : Color.white.opacity(0.45))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .help("Reject (X)")
        }
        .buttonStyle(.plain)
        .font(.system(size: 14))
    }
}

// MARK: - Filter

/// Everything that decides which files the timeline holds: kind, subfolder, rating, order.
private struct FilterControls: View {
    let library: Library

    private var visibleModes: [ViewMode] {
        ViewMode.allCases.filter { library.modeButtonVisible($0) }
    }

    var body: some View {
        if visibleModes.count > 1 {
            SidebarRow(label: "Files") { modePicker }
        }
        if library.showsSubfolderChips {
            SidebarRow(label: "Folder") { FolderList(library: library) }
        }
        SidebarRow(label: "Rating") { ratingPicker }
        Toggle("Unviewed only (\(library.unviewedCount))",
               isOn: Binding(get: { library.unviewedOnly }, set: { _ in library.toggleUnviewed() }))
            .toggleStyle(.checkbox)
            .font(.system(size: 12))
            .help("Only files no earlier session showed large. Files you view now stay. (U)")
        SidebarRow(label: "Order") { orderControls }
    }

    /// With counts while they fit the panel. A segmented control never shrinks, so a folder
    /// with all four kinds (`ALL (2682) | RAW (2302) | …`) would push the whole column wider;
    /// then the bare labels show and the counts move to the tooltip.
    private var modePicker: some View {
        ViewThatFits(in: .horizontal) {
            modeSegments(label: library.modeButtonLabel)
            modeSegments(label: \.buttonLabel)
                .help(visibleModes.map { library.modeButtonLabel($0) }.joined(separator: " · "))
        }
    }

    private func modeSegments(label: @escaping (ViewMode) -> String) -> some View {
        // `switchViewMode(_:toggle: false)` is the mode-button semantics: a direct switch.
        Picker("Files", selection: Binding(get: { library.viewMode },
                                           set: { library.switchViewMode($0, toggle: false) })) {
            ForEach(visibleModes, id: \.self) { mode in
                Text(label(mode)).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
    }

    private var ratingPicker: some View {
        // `setRatingFilter` is async (it sweeps every rating off disk first).
        Picker("Rating filter", selection: Binding(
            get: { library.ratingFilter.value },
            set: { value in Task { await library.setRatingFilter(value) } })) {
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
    }

    @ViewBuilder
    private var orderControls: some View {
        Picker("Order", selection: Binding(get: { library.sortOrder },
                                           set: { library.setSortOrder($0) })) {
            Text("Oldest first").tag(SortOrder.oldestFirst)
            Text("Newest first").tag(SortOrder.newestFirst)
            if library.faceDetection {
                Text("Best faces").tag(SortOrder.bestFaces)
            }
        }
        .labelsHidden()
        .controlSize(.small)
        Toggle("Group by scene", isOn: Binding(get: { library.groupScenes },
                                               set: { _ in library.toggleScenes() }))
            .toggleStyle(.checkbox)
            .font(.system(size: 12))
            .disabled(library.sortOrder == .bestFaces)
            .help("Group by scene (⇧S)")
    }
}

/// The subfolders as a list: `All`, then one row per subfolder. Right-click a subfolder to
/// leave it out of `All`.
private struct FolderList: View {
    let library: Library

    var body: some View {
        VStack(spacing: 1) {
            row(title: "All", count: library.allChipCount, folder: nil, excluded: false)
            ForEach(library.subfolderChips(), id: \.name) { chip in
                row(title: chip.name, count: chip.count, folder: chip.name, excluded: chip.excluded)
                    .help(chip.excluded ? "Right-click to include in All" : "Right-click to exclude from All")
                    .contextMenu {
                        Button(chip.excluded ? "Include in All" : "Exclude from All") {
                            library.toggleExcluded(chip.name)
                        }
                    }
            }
        }
    }

    private func row(title: String, count: Int, folder: String?, excluded: Bool) -> some View {
        let selected = library.folderFilter == folder
        return Button { library.setFolderFilter(folder) } label: {
            HStack {
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Text("\(count)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 12))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(selected ? Color.accentColor.opacity(0.35) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(excluded ? 0.5 : 1)
    }
}

// MARK: - Display

/// Single image or grid, at the top of the panel. `G` and `Return` still do the same.
private struct DisplaySwitch: View {
    let library: Library

    var body: some View {
        Picker("Display", selection: Binding(get: { library.displayMode == .grid },
                                             set: { library.showGrid($0) })) {
            Label("Single", systemImage: "photo").tag(false)
            Label("Grid", systemImage: "square.grid.2x2").tag(true)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .help("Single image or grid (G)")
    }
}

// MARK: - Days

/// One row per day of the timeline; a click jumps to its first frame. The current day is
/// highlighted. `⌥↑` / `⌥↓` walk the same list.
private struct DayList: View {
    let library: Library

    var body: some View {
        let current = library.currentDay
        VStack(spacing: 1) {
            ForEach(Array(library.dayList.enumerated()), id: \.offset) { day, entry in
                Button { library.jumpToDay(day) } label: {
                    HStack {
                        Text(Self.format(entry.date))
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text("\(entry.count)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .font(.system(size: 12))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(day == current ? Color.accentColor.opacity(0.35) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// `Wed, 4 Nov`, with the year when it is not this year.
    static func format(_ date: Date, now: Date = Date()) -> String {
        var style = Date.FormatStyle().weekday(.abbreviated).day().month(.abbreviated)
        if !Calendar.current.isDate(date, equalTo: now, toGranularity: .year) { style = style.year() }
        return date.formatted(style)
    }
}
