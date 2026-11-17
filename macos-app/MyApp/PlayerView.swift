import SwiftUI
import AVKit

/// Plays a recording and lets you trim it with the built-in AVKit trimming bar.
/// Trimming saves a new "(Trimmed)" copy and leaves the original untouched.
struct PlayerView: View {
    let url: URL

    @Environment(ScreenRecorder.self) private var recorder
    @State private var controller = PlayerController()
    @State private var status: String?

    var body: some View {
        PlayerViewRepresentable(controller: controller)
            .frame(minWidth: 640, minHeight: 400)
            .navigationTitle(url.deletingPathExtension().lastPathComponent)
            .toolbar {
                ToolbarItemGroup {
                    if let status {
                        Text(status).foregroundStyle(.secondary)
                    }
                    Button("Trim", systemImage: "scissors", action: trim)
                        .disabled(controller.isExporting)
                    Button("Show in Finder", systemImage: "folder") {
                        recorder.library.revealInFinder(url)
                    }
                }
            }
            .onAppear { controller.load(url) }
            .onDisappear { controller.player.pause() }
    }

    private func trim() {
        controller.beginTrimming { range in
            guard let range else { return }
            let destination = recorder.library.trimmedURL(for: url)
            status = "Saving trimmed copy…"
            Task {
                do {
                    try await RecordingExporter.trim(url, timeRange: range, to: destination)
                    recorder.library.reload()
                    status = "Saved \(destination.lastPathComponent)"
                } catch {
                    status = "Trim failed: \(error.localizedDescription)"
                }
                controller.isExporting = false
            }
        }
    }
}

@Observable
final class PlayerController {
    let player = AVPlayer()
    var isExporting = false
    @ObservationIgnored weak var playerView: AVPlayerView?

    func load(_ url: URL) {
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
    }

    /// Shows AVKit's trim bar. Calls back with the kept time range, or nil if cancelled.
    func beginTrimming(_ completion: @escaping (CMTimeRange?) -> Void) {
        guard let playerView, playerView.canBeginTrimming, let item = player.currentItem else { return }
        playerView.beginTrimming { [weak self] result in
            DispatchQueue.main.async {
                guard result == .okButton else { return completion(nil) }
                let start = item.reversePlaybackEndTime.isValid ? item.reversePlaybackEndTime : .zero
                let end = item.forwardPlaybackEndTime.isValid ? item.forwardPlaybackEndTime : item.duration
                self?.isExporting = true
                completion(CMTimeRange(start: start, end: end))
            }
        }
    }
}

private struct PlayerViewRepresentable: NSViewRepresentable {
    let controller: PlayerController

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = controller.player
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = true
        view.showsSharingServiceButton = true
        controller.playerView = view
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {}
}
