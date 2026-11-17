import SwiftUI

/// Recording controls in the menu bar, so you can record without the main window open.
struct MenuBarView: View {
    @Environment(ScreenRecorder.self) private var recorder
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        switch recorder.state {
        case .idle:
            Button("Start Recording") { recorder.start() }
                .keyboardShortcut("r", modifiers: [.command, .option])
            Button("Record Area…") {
                Task { if await recorder.selectArea() { recorder.start() } }
            }
            .keyboardShortcut("a", modifiers: [.command, .option])
        case .countingDown(let value):
            Button("Cancel Countdown (\(value))") { recorder.cancelCountdown() }
        case .recording, .paused:
            Text("\(recorder.state == .paused ? "Paused" : "Recording") — \(formatDuration(recorder.elapsed))")
            Button(recorder.state == .paused ? "Resume" : "Pause") { recorder.togglePause() }
                .keyboardShortcut("p", modifiers: [.command, .option])
            Button("Stop Recording") { Task { await recorder.stop() } }
                .keyboardShortcut("r", modifiers: [.command, .option])
        case .finishing:
            Text("Saving…")
        }

        Divider()

        if let last = recorder.lastRecording {
            Button("Show Last Recording") { recorder.library.revealInFinder(last) }
        }
        Button("Open Recordings Folder") { recorder.library.openFolder() }
        Button("Open Screen Recorder") {
            openWindow(id: "main")
            NSApp.activate()
        }

        Divider()

        Button("Quit") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

struct MenuBarLabel: View {
    let recorder: ScreenRecorder

    var body: some View {
        switch recorder.state {
        case .recording:
            Label(formatDuration(recorder.elapsed), systemImage: "record.circle.fill")
                .labelStyle(.titleAndIcon)
        case .paused:
            Label(formatDuration(recorder.elapsed), systemImage: "pause.circle.fill")
                .labelStyle(.titleAndIcon)
        case .countingDown(let value):
            Label("\(value)", systemImage: "timer")
                .labelStyle(.titleAndIcon)
        default:
            Image(systemName: "record.circle")
        }
    }
}
