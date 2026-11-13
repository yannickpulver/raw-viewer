import SwiftUI

/// The right sidebar (`I`): the photo on screen first, then what the timeline shows. A
/// floating panel beside the image area; the filmstrip keeps the full window width underneath.
/// Single view shows the photo in full and the filters compact; the grid the other way round.
struct Sidebar: View {
    let model: AppModel
    var library: Library { model.library }

    /// Height of the window toolbar; `0` when there is none (full screen with a hidden bar).
    @State private var toolbarHeight: CGFloat = 0

    /// The Photo section's title sits in the toolbar row, on the line of the sidebar toggle.
    /// Without a toolbar row it falls back into the list.
    private var titleInToolbarRow: Bool { toolbarHeight >= 20 }

    private static let contentPadding: CGFloat = 14
    private static let photoTitle = "Photo"
    private static let photoSymbol = "photo"

    private var isGrid: Bool { library.displayMode == .grid }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let file = library.currentFile {
                    SidebarSection(title: titleInToolbarRow ? nil : Self.photoTitle, symbol: Self.photoSymbol) {
                        PhotoCard(library: library, file: file, style: isGrid ? .compact : .full)
                    }
                    if !isGrid, library.showsFaces {
                        SidebarSection(title: "Faces", symbol: "face.smiling") {
                            FacePanel(model: model, file: file)
                        }
                    }
                }
                SidebarSection(title: "Filter", symbol: "line.3.horizontal.decrease") {
                    FilterControls(library: library, expanded: isGrid)
                }
                SidebarSection(title: "Order", symbol: "arrow.up.arrow.down") {
                    OrderControls(library: library)
                }
                if library.dayList.count > 1 {
                    SidebarSection(title: "Days", symbol: "calendar") {
                        DayList(library: library)
                    }
                }
            }
            // Every control here shares the width it is given (`Segments`, lists, truncating
            // text), so the column follows the panel, a permanent scroll bar included.
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Self.contentPadding).padding(.bottom, 14).padding(.top, 10)
        }
        // The display switch stays put while the list scrolls under it. Its background
        // reaches up to the panel's top edge, so nothing shows through in the toolbar row.
        .safeAreaInset(edge: .top, spacing: 0) {
            DisplaySwitch(library: library)
                .padding(.horizontal, Self.contentPadding).padding(.top, 4).padding(.bottom, 10)
                .background {
                    UnevenRoundedRectangle(topLeadingRadius: 14, topTrailingRadius: 14, style: .continuous)
                        .fill(Theme.sidebarBackground)
                        // Inside the panel's stroke, which stays visible around it.
                        .padding([.top, .horizontal], Theme.chromeStrokeWidth)
                        .padding(.top, Theme.sidebarInset)
                        .ignoresSafeArea(edges: .top)
                }
        }
        // Scrolled content stops at the panel's top edge instead of showing in the gap above it.
        .mask {
            panelShape
                .padding(.top, Theme.sidebarInset)
                .ignoresSafeArea(edges: .top)
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
                SectionHeader(title: Self.photoTitle, symbol: Self.photoSymbol)
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
/// (the Photo section's lives in the toolbar row). As in Print Lab's inspector.
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

// MARK: - Filter

/// Everything that decides which files the timeline holds: kind, subfolder, rating, unviewed.
/// `expanded` (the grid) shows the ratings as a list with counts instead of segments.
private struct FilterControls: View {
    let library: Library
    let expanded: Bool

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
        if expanded {
            SidebarRow(label: "Rating") { RatingList(library: library) }
            ListRow(title: "Unviewed only", count: library.unviewedCount, selected: library.unviewedOnly) {
                library.toggleUnviewed()
            }
            .help(Self.unviewedHelp)
        } else {
            SidebarRow(label: "Rating") { ratingPicker }
            Toggle("Unviewed only (\(library.unviewedCount))",
                   isOn: Binding(get: { library.unviewedOnly }, set: { _ in library.toggleUnviewed() }))
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
                .help(Self.unviewedHelp)
        }
    }

    private static let unviewedHelp = "Only files no earlier session showed large. Files you view now stay. (U)"

    /// Each kind with its count underneath, so four kinds still fit the panel.
    private var modePicker: some View {
        // `switchViewMode(_:toggle: false)` is the mode-button semantics: a direct switch.
        Segments(values: visibleModes, selected: library.viewMode,
                 select: { library.switchViewMode($0, toggle: false) }, height: 30) { mode in
            VStack(spacing: 0) {
                Text(mode.buttonLabel)
                Text(library.modeFileCount(mode).formatted())
                    .font(.system(size: 9).monospacedDigit())
                    .opacity(0.75)
            }
        }
    }

    private var ratingPicker: some View {
        // `setRatingFilter` is async (it sweeps every rating off disk first).
        Segments(values: Library.ratingFilterValues, selected: library.ratingFilter.value,
                 select: { value in Task { await library.setRatingFilter(value) } }) { value in
            switch value {
            case 0: Text("All")
            case RatingFilter.unratedValue: Text("0")
            case -1: Image(systemName: "xmark")
            case 5: Text("5")
            default: Text("\(value)+")
            }
        }
    }
}

/// The rating filter as rows with counts, in the grid. A bar behind each row shows its share
/// of the files, so the list doubles as culling progress.
private struct RatingList: View {
    let library: Library

    var body: some View {
        let counts = library.ratingCounts
        // `All` hides rejected files (spec 01 §13), so the bars are shares of everything.
        let total = max(1, (counts[0] ?? 0) + (counts[-1] ?? 0))
        VStack(spacing: 1) {
            ForEach(Library.ratingFilterValues, id: \.self) { value in
                let count = counts[value] ?? 0
                ListRow(title: Self.title(value), count: count, selected: library.ratingFilter.value == value,
                        share: value == 0 ? nil : Double(count) / Double(total)) {
                    Task { await library.setRatingFilter(value) }
                }
            }
        }
    }

    static func title(_ value: Int) -> String {
        switch value {
        case 0: "All"
        case RatingFilter.unratedValue: "Unrated"
        case -1: "Rejected"
        case 5: "5★"
        default: "\(value)★ and up"
        }
    }
}

/// How the timeline is sorted and whether it is cut into scenes.
private struct OrderControls: View {
    let library: Library

    private var orders: [SortOrder] {
        library.faceDetection ? [.oldestFirst, .newestFirst, .bestFaces] : [.oldestFirst, .newestFirst]
    }

    var body: some View {
        Segments(values: orders, selected: library.sortOrder,
                 select: { library.setSortOrder($0) }, height: 22) { order in
            switch order {
            case .oldestFirst: Text(library.faceDetection ? "Oldest" : "Oldest first")
            case .newestFirst: Text(library.faceDetection ? "Newest" : "Newest first")
            case .bestFaces: Text("Best faces")
            }
        }
        Toggle("Group by scene", isOn: Binding(get: { library.groupScenes },
                                               set: { _ in library.toggleScenes() }))
            .toggleStyle(.checkbox)
            .font(.system(size: 12))
            .disabled(library.sortOrder == .bestFaces)
            .help("Group by scene (⇧S)")
    }
}

/// One selectable row with a count on the right, as in the Folder, Days and Rating lists.
/// `share` draws a faint bar behind the row, that fraction of its width.
private struct ListRow: View {
    let title: String
    let count: Int
    let selected: Bool
    var share: Double? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
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
            .background(alignment: .leading) {
                if let share, share > 0, !selected {
                    GeometryReader { geometry in
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                            .frame(width: max(2, geometry.size.width * min(1, share)))
                    }
                }
            }
            .background(selected ? Color.accentColor.opacity(0.35) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
        ListRow(title: title, count: count, selected: library.folderFilter == folder) {
            library.setFolderFilter(folder)
        }
        .opacity(excluded ? 0.5 : 1)
    }
}

// MARK: - Display

/// Single image or grid, at the top of the panel. `G` and `Return` still do the same.
private struct DisplaySwitch: View {
    let library: Library

    var body: some View {
        Segments(values: [false, true], selected: library.displayMode == .grid,
                 select: { library.showGrid($0) }, height: 24) { grid in
            Label(grid ? "Grid" : "Single", systemImage: grid ? "square.grid.2x2" : "photo")
        }
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
                ListRow(title: Self.format(entry.date), count: entry.count, selected: day == current) {
                    library.jumpToDay(day)
                }
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

// MARK: - Segments

/// A segmented control that always splits the width it is given. AppKit's segmented control
/// sometimes keeps its natural width instead of shrinking, which pushed the whole sidebar
/// column wider than the panel; these buttons share the width evenly and never ask for more.
private struct Segments<Value: Hashable, Content: View>: View {
    let values: [Value]
    let selected: Value
    let select: (Value) -> Void
    var height: CGFloat = 20
    @ViewBuilder let label: (Value) -> Content

    var body: some View {
        HStack(spacing: 2) {
            ForEach(values, id: \.self) { value in
                let isSelected = value == selected
                Button { select(value) } label: {
                    label(value)
                        .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                        .lineLimit(1)
                        .foregroundStyle(isSelected ? Color.white : Color.primary.opacity(0.85))
                        .frame(maxWidth: .infinity, minHeight: height)
                        .background(isSelected ? Color.accentColor : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}
