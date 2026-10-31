import SwiftUI

/// `V`: two frames of the current scene side by side, at the same zoom. `←` / `→` keep one,
/// `↓` keeps both; the scene's next frame takes the free slot. Mac app addition, no
/// Python-app equivalent.
struct DuelPane: View {
    let model: AppModel
    @State private var zoomGroup = CanvasZoomGroup()
    private var library: Library { model.library }

    var body: some View {
        let scheduler = library.scheduler
        // Read so the tiles repaint as previews land.
        _ = scheduler.previewRevision &+ scheduler.thumbs80.count
        return GeometryReader { geometry in
            if let duel = library.duel {
                let grid = TileLayout.grid(count: 2, width: geometry.size.width,
                                           height: geometry.size.height, aspect: aspect(duel))
                let size = CGSize(width: geometry.size.width / CGFloat(grid.columns),
                                  height: geometry.size.height / CGFloat(grid.rows))
                let layout = grid.columns == 2 ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
                layout {
                    tile(duel.left).frame(width: size.width, height: size.height)
                    tile(duel.right).frame(width: size.width, height: size.height)
                }
                .overlay(alignment: .bottom) { hint }
            }
        }
    }

    /// One scene is usually shot with the camera held one way, so the left frame's shape
    /// stands for both.
    private func aspect(_ duel: Library.Duel) -> Double {
        guard let image = image(for: library.files[duel.left]), image.height > 0 else { return 1.5 }
        return Double(image.width) / Double(image.height)
    }

    private func image(for file: MediaFile) -> CGImage? {
        library.scheduler.preview(for: file.url) ?? library.scheduler.thumb80(for: file.url)
    }

    private func tile(_ index: Int) -> some View {
        let file = library.files[index]
        let rating = library.rating(for: file.url)
        return CanvasView(image: image(for: file), url: file.url,
                          rotationToken: model.rotationToken,
                          zoomToken: model.zoomToken,
                          onNavigate: { _ in },
                          onFocus: {},
                          zoomGroup: zoomGroup,
                          takesCommands: index == library.index)
            .id(file.url)
            .padding(3)
            .overlay(alignment: .top) {
                if rating != Rating.unrated {
                    Text(rating == Rating.rejected ? "✕" : String(repeating: "★", count: rating))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(rating == Rating.rejected ? Theme.rejectRed : Theme.ratingDot)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.black.opacity(0.55), in: Capsule())
                        .padding(.top, 64)
                        .allowsHitTesting(false)
                }
            }
    }

    /// Bottom centre is free of the floating chrome: corner buttons left, filter toolbar right.
    private var hint: some View {
        Text("←  keep left     ↓  keep both     keep right  →     ⌘Z  undo")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.panelText)
            .padding(.horizontal, 14).padding(.vertical, 6)
            .chromeSurface(.regularMaterial)
            .padding(.bottom, 14)
            .allowsHitTesting(false)
    }
}
