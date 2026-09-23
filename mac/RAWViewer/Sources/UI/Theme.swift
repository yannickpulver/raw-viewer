import SwiftUI

/// The colours and metrics of the image areas (canvas, filmstrip, grid, rating dots),
/// straight out of spec 01. The floating chrome uses system materials and controls instead —
/// see `chromeSurface` below.
enum Theme {

    // MARK: Colours

    static let windowBackground = Color.black

    static let stripArea = Color(.sRGB, red: 0, green: 0, blue: 0, opacity: 200.0 / 255.0)
    static let stripBackground = Color(.sRGB, white: 20.0 / 255.0, opacity: 1)

    static let amber = Color(.sRGB, red: 1, green: 180.0 / 255.0, blue: 0, opacity: 200.0 / 255.0)
    static let amberBorder = Color(.sRGB, red: 1, green: 180.0 / 255.0, blue: 0, opacity: 1)
    /// `amberBorder`'s value as a `CGColor`, for the AppKit-drawn grid/filmstrip selection border.
    static let amberBorderCGColor = CGColor(red: 1, green: 180.0 / 255.0, blue: 0, alpha: 1)

    static let ratingDot = Color(.sRGB, red: 1, green: 200.0 / 255.0, blue: 50.0 / 255.0, opacity: 1)
    static let rejectRed = Color(.sRGB, red: 230.0 / 255.0, green: 70.0 / 255.0, blue: 70.0 / 255.0, opacity: 1)

    static let panelText = Color(.sRGB, white: 221.0 / 255.0, opacity: 1)     // #ddd
    static let dimText = Color(.sRGB, white: 170.0 / 255.0, opacity: 1)       // #aaa

    // MARK: Metrics

    static let filmstripHeight: CGFloat = 124
    static let thumbSize: CGFloat = 80
    static let thumbStride: CGFloat = 84
    static let faceThumbSize: CGFloat = 64
}

// MARK: - Native chrome surfaces

/// Metrics for the floating chrome. The chrome is system-material based; the image areas
/// (canvas, filmstrip, grid, rating dots) keep the colours from spec 01.
extension Theme {
    static let chromeCornerRadius: CGFloat = 8
    static let chromeStrokeWidth: CGFloat = 0.5
    static var chromeStroke: Color { Color(nsColor: .separatorColor) }
    /// A soft drop shadow so white chrome text stays legible over a blown-out sky.
    static let chromeTextShadow = Color.black.opacity(0.65)
}

/// `.ultraThinMaterial` / `.regularMaterial` in a rounded rect with a hairline separator
/// stroke — or Liquid Glass where the OS has it.
private struct ChromeSurface: ViewModifier {
    let material: Material
    let cornerRadius: CGFloat
    /// Chrome floats over arbitrary photographs, so a material alone is not enough contrast
    /// for white text on a blown-out sky. A dark scrim sits between the material and the
    /// content; the material (or glass) still supplies the blur and the live tint.
    let scrim: Double
    /// Liquid Glass is for text-only panels. A glass container also restyles the AppKit
    /// controls nested inside it (a bordered button turns into a white glass blob), so the
    /// panels that wrap a picker or a button opt out and take the plain material instead.
    let glass: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let scrimmed = content.background(shape.fill(Color.black.opacity(scrim)))
        if #available(macOS 26, *), glass {
            scrimmed
                .glassEffect(.regular, in: shape)
                .overlay(shape.strokeBorder(Theme.chromeStroke, lineWidth: Theme.chromeStrokeWidth))
        } else {
            scrimmed
                .background(material, in: shape)
                .overlay(shape.strokeBorder(Theme.chromeStroke, lineWidth: Theme.chromeStrokeWidth))
        }
    }
}

extension View {
    /// Use `.regularMaterial` wherever the panel has to stay legible on top of a photo.
    func chromeSurface(_ material: Material = .ultraThinMaterial,
                       cornerRadius: CGFloat = Theme.chromeCornerRadius,
                       scrim: Double = 0.55,
                       glass: Bool = true) -> some View {
        modifier(ChromeSurface(material: material, cornerRadius: cornerRadius, scrim: scrim, glass: glass))
    }

    func chromeTextShadow() -> some View {
        shadow(color: Theme.chromeTextShadow, radius: 3, x: 0, y: 0)
    }
}

/// A bordered icon button that reads as "on" while its overlay is open (`?`, `⏱`).
struct ChromeToggleButton: View {
    let symbol: String
    let isOn: Bool
    let helpText: String
    let action: () -> Void

    var body: some View {
        Group {
            if isOn {
                Button(action: action) { Image(systemName: symbol) }.buttonStyle(.borderedProminent)
            } else {
                Button(action: action) { Image(systemName: symbol) }.buttonStyle(.bordered)
            }
        }
        .controlSize(.small)
        .help(helpText)
    }
}
