import CoreGraphics
import SwiftUI

/// The faces of the image on screen, cropped out of its preview, right under the info block:
/// at most four per row, then it wraps. A click zooms the canvas onto that face.
struct FacePanel: View {
    let model: AppModel
    let file: MediaFile
    var library: Library { model.library }

    static let perRow = 4

    var body: some View {
        let faces = library.faceIndex.faces(for: file.url)
        let image = library.scheduler.preview(for: file.url)
        let remaining = library.faceIndex.remaining
        VStack(alignment: .trailing, spacing: 6) {
            if let faces, !faces.isEmpty {
                let rows = Self.rows(faces)
                VStack(alignment: .trailing, spacing: 6) {
                    ForEach(rows.indices, id: \.self) { row in
                        HStack(spacing: 6) {
                            ForEach(rows[row].indices, id: \.self) { column in
                                let face = rows[row][column]
                                FaceCell(face: face, crop: image.flatMap { Self.crop($0, to: face.rect) })
                                    .onTapGesture { model.focusFace(face.rect) }
                                    .pointingHandCursor()
                            }
                        }
                    }
                }
            }
            if faces == nil || remaining > 0 {
                Text(status(faces: faces, remaining: remaining))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Theme.dimText)
                    .chromeTextShadow()
                    .allowsHitTesting(false)
            }
        }
        .padding(.horizontal, 12)
    }

    private func status(faces: [Face]?, remaining: Int) -> String {
        // An image without faces shows nothing of its own, only the sweep's progress.
        let state = faces == nil ? "Analysing faces…" : nil
        let left = remaining > 0 ? "\(remaining) left" : nil
        return [state, left].compactMap { $0 }.joined(separator: " · ")
    }

    /// Left to right across the photo, then chunked into rows of `perRow`.
    static func rows(_ faces: [Face]) -> [[Face]] {
        let sorted = faces.sorted { $0.rect.minX < $1.rect.minX }
        return stride(from: 0, to: sorted.count, by: perRow).map {
            Array(sorted[$0..<min($0 + perRow, sorted.count)])
        }
    }

    /// A square around the face with some room for hair and chin, clamped to the image.
    /// `rect` has a bottom-left origin; `CGImage.cropping` wants top-left.
    static func crop(_ image: CGImage, to rect: CGRect) -> CGImage? {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let side = max(rect.width * w, rect.height * h) * 1.6
        let centre = CGPoint(x: rect.midX * w, y: (1 - rect.midY) * h)
        let square = CGRect(x: centre.x - side / 2, y: centre.y - side / 2, width: side, height: side)
            .intersection(CGRect(x: 0, y: 0, width: w, height: h))
            .integral
        guard !square.isEmpty else { return nil }
        return image.cropping(to: square)
    }
}

private struct FaceCell: View {
    let face: Face
    let crop: CGImage?

    var body: some View {
        let size = Theme.faceThumbSize
        ZStack {
            Theme.stripBackground
            if let crop {
                Image(decorative: crop, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay(alignment: .topTrailing) {
            if face.eyesClosed {
                Image(systemName: "eye.slash.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(3)
                    .background(Circle().fill(Theme.rejectRed))
                    .padding(3)
                    .help("Eyes look closed")
            }
        }
        .overlay(alignment: .bottom) {
            if let quality = face.quality {
                // Vision's capture quality: a relative score, only meaningful between faces.
                GeometryReader { geometry in
                    Capsule()
                        .fill(Color.white.opacity(0.85))
                        .frame(width: max(4, geometry.size.width * CGFloat(quality)), height: 3)
                }
                .frame(height: 3)
                .padding(.horizontal, 5)
                .padding(.bottom, 4)
                .help("Face quality \(Int((quality * 100).rounded()))")
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(face.eyesClosed ? Theme.rejectRed : Color.white.opacity(0.25), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
    }
}
