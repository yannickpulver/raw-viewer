import SwiftUI

/// The photo on screen, at the top of the sidebar. `full` in single view: position, name,
/// date, histogram, exposure values, camera and lens, stack, stars. `compact` in the grid:
/// one line, the exposure values as text, stars.
struct PhotoCard: View {
    enum Style { case full, compact }

    let library: Library
    let file: MediaFile
    let style: Style

    /// The last details read, with the file they belong to. The previous photo's values stay
    /// until the next read lands (a few milliseconds), so the card does not jump per frame.
    @State private var details: (url: URL, value: PhotoDetails?)?
    @State private var histogram: (url: URL, bins: [Double])?

    private var isVideo: Bool { file.kind == .video }
    private var hasPreview: Bool { library.scheduler.preview(for: file.url) != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch style {
            case .full: fullHeader
            case .compact: compactHeader
            }
            if style == .full, let stack = library.currentStack {
                StackRow(library: library, frames: stack)
            }
            RatingPicker(rating: library.rating(for: file.url),
                         rate: { library.rate($0) },
                         reject: { library.toggleReject() })
                // The duel decides ratings itself and swallows the rating keys too.
                .disabled(library.displayMode == .duel)
        }
        .task(id: file.url) {
            guard !isVideo else { return }
            let url = file.url
            let value = await Task.detached(priority: .userInitiated) { PhotoDetails.read(url) }.value
            if !Task.isCancelled { details = (url, value) }
        }
        .task(id: HistogramKey(url: file.url, ready: hasPreview && style == .full)) {
            guard style == .full, !isVideo, let image = library.scheduler.preview(for: file.url) else { return }
            let url = file.url
            let bins = await Task.detached(priority: .utility) { LumaHistogram.compute(image) }.value
            if !Task.isCancelled, let bins { histogram = (url, LumaHistogram.normalized(bins)) }
        }
    }

    private struct HistogramKey: Equatable {
        let url: URL
        let ready: Bool
    }

    // MARK: - Full

    @ViewBuilder
    private var fullHeader: some View {
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
        if !isVideo, details?.value != nil || histogram != nil {
            VStack(alignment: .leading, spacing: 8) {
                // The previous photo's histogram would be wrong here; an empty box keeps the space.
                HistogramView(bins: histogram?.url == file.url ? histogram?.bins : nil)
                if let value = details?.value {
                    ExposureTiles(details: value)
                    if let gear = value.gearText {
                        Text(gear)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .help(gear)
                    }
                }
            }
        }
    }

    // MARK: - Compact

    @ViewBuilder
    private var compactHeader: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text("\(library.index + 1)/\(library.files.count)")
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                Text(file.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.9))
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            if !isVideo, let value = details?.value {
                let line = [value.shutterText, value.apertureText, value.isoText, value.focalText]
                    .compactMap { $0 }.joined(separator: " · ")
                if !line.isEmpty {
                    Text(line)
                        .font(.system(size: 11.5).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .lineLimit(1)
    }
}

/// Shutter, aperture, ISO and focal length as four equal tiles.
private struct ExposureTiles: View {
    let details: PhotoDetails

    var body: some View {
        HStack(spacing: 4) {
            tile(details.shutterText, "shutter")
            tile(details.apertureText, "aperture")
            tile(details.isoText, "iso")
            tile(details.focalText, "focal")
        }
    }

    private func tile(_ value: String?, _ caption: String) -> some View {
        VStack(spacing: 1) {
            Text(value ?? "–")
                .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(caption)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 5)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// The luminance histogram as a filled curve on a dark box.
private struct HistogramView: View {
    let bins: [Double]?

    var body: some View {
        Canvas { context, size in
            guard let bins, bins.count > 1 else { return }
            let step = size.width / CGFloat(bins.count - 1)
            let usable = size.height - 4
            var line = Path()
            for (index, value) in bins.enumerated() {
                let point = CGPoint(x: CGFloat(index) * step, y: size.height - CGFloat(value) * usable)
                index == 0 ? line.move(to: point) : line.addLine(to: point)
            }
            var fill = line
            fill.addLine(to: CGPoint(x: size.width, y: size.height))
            fill.addLine(to: CGPoint(x: 0, y: size.height))
            fill.closeSubpath()
            context.fill(fill, with: .color(.white.opacity(0.3)))
            context.stroke(line, with: .color(.white.opacity(0.65)), lineWidth: 1)
        }
        .frame(height: 56)
        .background(Color.black.opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
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

/// `⧉ Stack of 3 · 0, −0.7, +0.7 EV` and the button that opens or folds it (`K`).
private struct StackRow: View {
    let library: Library
    let frames: [MediaFile]

    private var evText: String {
        frames.map { frame -> String in
            let bias = frame.exposure?.bias ?? 0
            let rounded = (bias * 10).rounded() / 10
            if rounded == 0 { return "0" }
            return (rounded > 0 ? "+" : "\u{2212}") + String(format: "%g", abs(rounded))
        }.joined(separator: ", ") + " EV"
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "square.stack.fill")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("Stack of \(frames.count)")
                    .font(.system(size: 12, weight: .medium))
                Text(evText)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 6)
            Button(library.isCurrentStackExpanded ? "Collapse" : "Expand") { library.toggleStack() }
                .controlSize(.small)
                .help("Show every frame of the stack, or fold it into one (K)")
        }
    }
}
