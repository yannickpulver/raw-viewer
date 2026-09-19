import AVFoundation
import AVKit
import Observation
import SwiftUI

/// Owns the single `AVPlayer`. Spec 01 §18.
@MainActor
@Observable
final class VideoController {

    let player = AVPlayer()
    private(set) var currentURL: URL?
    var position: Double = 0
    var duration: Double = 0
    var isDragging = false

    private var observer: Any?

    init() {
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.2, preferredTimescale: 600),
                                                  queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, !self.isDragging else { return }
                self.position = time.seconds.isFinite ? time.seconds : 0
                if let item = self.player.currentItem {
                    let total = item.duration.seconds
                    if total.isFinite, total > 0 { self.duration = total }
                }
            }
        }
    }

    /// Spec 01 §18: selecting a clip stops, sets the source and plays immediately.
    func open(_ url: URL?) {
        guard currentURL != url else { return }
        player.pause()
        currentURL = url
        position = 0
        duration = 0
        guard let url else {
            player.replaceCurrentItem(with: nil)
            return
        }
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        player.play()
    }

    func togglePlay() {
        if player.timeControlStatus == .playing { player.pause() } else { player.play() }
    }

    func pause() { player.pause() }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        currentURL = nil
        position = 0
        duration = 0
    }

    func seek(to seconds: Double) {
        position = seconds
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    static func timeLabel(position: Double, duration: Double) -> String {
        func part(_ value: Double) -> String {
            let total = Int(value.isFinite && value > 0 ? value : 0)
            return "\(total / 60):\(String(format: "%02d", total % 60))"
        }
        return "\(part(position)) / \(part(duration))"
    }
}

private struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}

/// Custom timeline: 4 px groove `#333`, 12 px white handle, filled `#888`. Spec 01 §3.
private struct TimelineSlider: View {
    @Bindable var controller: VideoController

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let fraction = controller.duration > 0 ? min(1, max(0, controller.position / controller.duration)) : 0
            let handleX = width * fraction

            ZStack(alignment: .leading) {
                Capsule().fill(Color(.sRGB, white: 51.0 / 255.0, opacity: 1))
                    .frame(height: 4)
                Capsule().fill(Color(.sRGB, white: 136.0 / 255.0, opacity: 1))
                    .frame(width: handleX, height: 4)
                Circle().fill(Color.white)
                    .frame(width: 12, height: 12)
                    .offset(x: handleX - 6)
            }
            .frame(height: 12)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        controller.isDragging = true
                        guard controller.duration > 0, width > 0 else { return }
                        let f = min(1, max(0, value.location.x / width))
                        controller.position = f * controller.duration
                    }
                    .onEnded { _ in
                        controller.isDragging = false
                        controller.seek(to: controller.position)
                    }
            )
        }
        .frame(height: 20)
    }
}

struct VideoPane: View {
    @Bindable var controller: VideoController

    var body: some View {
        VStack(spacing: 0) {
            PlayerSurface(player: controller.player)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack(spacing: 0) {
                TimelineSlider(controller: controller)
                Text(VideoController.timeLabel(position: controller.position, duration: controller.duration))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .frame(width: 100, alignment: .leading)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color(.sRGB, white: 20.0 / 255.0, opacity: 220.0 / 255.0))
        }
        .background(Color.black)
    }
}
