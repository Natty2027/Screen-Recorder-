import SwiftUI
import ScreenCaptureKit

struct ContentView: View {
    enum Section: String, CaseIterable, Identifiable {
        case record = "Record"
        case library = "Recordings"

        var id: String { rawValue }
        var symbol: String { self == .record ? "record.circle" : "film.stack" }
    }

    @State private var section: Section = .record

    var body: some View {
        NavigationSplitView {
            List(Section.allCases, selection: $section) { section in
                Label(section.rawValue, systemImage: section.symbol).tag(section)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180)
        } detail: {
            switch section {
            case .record: RecordView()
            case .library: LibraryView()
            }
        }
        .frame(minWidth: 760, minHeight: 620)
    }
}

// MARK: - Record

struct RecordView: View {
    @Environment(ScreenRecorder.self) private var recorder

    var body: some View {
        @Bindable var recorder = recorder

        Form {
            if !recorder.hasScreenPermission {
                PermissionBanner()
            }

            Section {
                RecordingControls()
            }

            Group {
                Section("What to Record") {
                    Picker("Mode", selection: $recorder.options.mode) {
                        ForEach(CaptureMode.allCases) { mode in
                            Label(mode.title, systemImage: mode.symbol).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    switch recorder.options.mode {
                    case .display:
                        DisplayPicker()
                    case .window:
                        Picker("Window", selection: $recorder.options.windowID) {
                            Text("Choose a window…").tag(CGWindowID?.none)
                            ForEach(recorder.windows, id: \.windowID) { window in
                                Text(recorder.windowName(window)).tag(Optional(window.windowID))
                            }
                        }
                        Text("Window recordings follow the window even when it's covered, but the camera bubble isn't included.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    case .area:
                        LabeledContent("Area") {
                            HStack {
                                if let area = recorder.options.area {
                                    Text("\(Int(area.width)) × \(Int(area.height)) at (\(Int(area.minX)), \(Int(area.minY)))")
                                        .monospacedDigit()
                                        .foregroundStyle(.secondary)
                                } else {
                                    Text("None selected").foregroundStyle(.secondary)
                                }
                                Button("Select Area…") {
                                    Task { await recorder.selectArea() }
                                }
                            }
                        }
                    }

                    Button("Refresh Screens & Windows", systemImage: "arrow.clockwise") {
                        Task { await recorder.refreshSources() }
                    }
                    .buttonStyle(.link)
                }

                Section("Audio") {
                    Toggle("Record computer audio", isOn: $recorder.options.systemAudio)
                    Toggle("Record microphone", isOn: $recorder.options.microphone)
                    if recorder.options.microphone {
                        Picker("Microphone", selection: $recorder.options.microphoneID) {
                            Text("System Default").tag(String?.none)
                            ForEach(recorder.microphones, id: \.uniqueID) { device in
                                Text(device.localizedName).tag(Optional(device.uniqueID))
                            }
                        }
                    }
                }

                Section("Camera") {
                    Toggle("Show camera bubble", isOn: $recorder.options.camera)
                    if recorder.options.camera {
                        Picker("Camera", selection: $recorder.options.cameraID) {
                            Text("System Default").tag(String?.none)
                            ForEach(recorder.cameras, id: \.uniqueID) { device in
                                Text(device.localizedName).tag(Optional(device.uniqueID))
                            }
                        }
                        Slider(value: $recorder.options.cameraSize, in: 120...360, step: 20) {
                            Text("Bubble size")
                        }
                        Text("Drag the bubble anywhere on screen. It appears in full-screen and area recordings.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Video") {
                    Picker("Frame rate", selection: $recorder.options.frameRate) {
                        Text("24 fps").tag(24)
                        Text("30 fps").tag(30)
                        Text("60 fps").tag(60)
                    }
                    Picker("Resolution", selection: $recorder.options.quality) {
                        ForEach(CaptureQuality.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Codec", selection: $recorder.options.codec) {
                        ForEach(VideoCodec.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("File format", selection: $recorder.options.format) {
                        ForEach(FileFormat.allCases) { Text($0.title).tag($0) }
                    }
                    Toggle("Show mouse pointer", isOn: $recorder.options.showCursor)
                    Toggle("Highlight mouse clicks", isOn: $recorder.options.highlightClicks)
                }

                Section("Behavior") {
                    Picker("Countdown", selection: $recorder.options.countdown) {
                        Text("Off").tag(0)
                        Text("3 seconds").tag(3)
                        Text("5 seconds").tag(5)
                        Text("10 seconds").tag(10)
                    }
                    Toggle("Hide this app's windows in recordings", isOn: $recorder.options.hideRecorderWindows)
                    Picker("When finished", selection: $recorder.options.afterRecording) {
                        ForEach(AfterRecordingAction.allCases) { Text($0.title).tag($0) }
                    }
                    LabeledContent("Save to") {
                        HStack {
                            Text(recorder.library.folderURL.path(percentEncoded: false))
                                .lineLimit(1)
                                .truncationMode(.head)
                                .foregroundStyle(.secondary)
                            Button("Change…") { recorder.library.chooseFolder() }
                            if recorder.library.usesCustomFolder {
                                Button("Reset") { recorder.library.useDefaultFolder() }
                            }
                        }
                    }
                }
            }
            .disabled(recorder.state != .idle)

            Section("Keyboard Shortcuts (work from any app)") {
                LabeledContent("Start / stop recording", value: "⌥⌘R")
                LabeledContent("Pause / resume", value: "⌥⌘P")
                LabeledContent("Select an area and record", value: "⌥⌘A")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Record")
        .task { await recorder.refreshSources() }
        .task(id: CameraKey(options: recorder.options)) {
            await recorder.syncCameraBubble()
        }
    }

    /// Re-syncs the camera bubble only when a camera-related option changes.
    private struct CameraKey: Hashable {
        let enabled: Bool
        let deviceID: String?
        let size: Double

        init(options: RecordingOptions) {
            enabled = options.camera
            deviceID = options.cameraID
            size = options.cameraSize
        }
    }
}

private struct DisplayPicker: View {
    @Environment(ScreenRecorder.self) private var recorder

    var body: some View {
        @Bindable var recorder = recorder
        Picker("Display", selection: $recorder.options.displayID) {
            ForEach(recorder.displays, id: \.displayID) { display in
                Text(recorder.displayName(display)).tag(Optional(display.displayID))
            }
        }
    }
}

private struct PermissionBanner: View {
    @Environment(ScreenRecorder.self) private var recorder

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text("Screen recording permission needed").bold()
                Text("Allow this app in System Settings › Privacy & Security › Screen & System Audio Recording, then reopen it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open Settings") { recorder.requestScreenPermission() }
        }
    }
}

/// The big record button, timer, mic level, and pause/stop controls.
struct RecordingControls: View {
    @Environment(ScreenRecorder.self) private var recorder

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 16) {
                Button(action: recorder.toggleRecording) {
                    ZStack {
                        Circle()
                            .fill(recorder.isActive ? Color.red.opacity(0.15) : Color.red)
                            .frame(width: 64, height: 64)
                        Image(systemName: recorder.isActive ? "stop.fill" : "record.circle")
                            .font(.system(size: 26, weight: .semibold))
                            .foregroundStyle(recorder.isActive ? Color.red : Color.white)
                    }
                }
                .buttonStyle(.plain)
                .disabled(recorder.state == .finishing)
                .help(recorder.isActive ? "Stop recording (⌥⌘R)" : "Start recording (⌥⌘R)")

                VStack(alignment: .leading, spacing: 4) {
                    Text(statusText).font(.headline)
                    Text(formatDuration(recorder.elapsed))
                        .font(.system(.title, design: .rounded, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(recorder.state == .recording ? .red : .primary)
                }

                Spacer()

                if recorder.isActive {
                    Button(recorder.state == .paused ? "Resume" : "Pause",
                           systemImage: recorder.state == .paused ? "play.fill" : "pause.fill",
                           action: recorder.togglePause)
                        .controlSize(.large)
                        .help("Pause or resume (⌥⌘P)")

                    Button("Stop", systemImage: "stop.fill") {
                        Task { await recorder.stop() }
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .help("Stop recording video and audio, and save to Downloads (⌥⌘R)")
                }
                if case .countingDown = recorder.state {
                    Button("Cancel", action: recorder.cancelCountdown).controlSize(.large)
                }
            }

            if recorder.isActive && recorder.options.microphone {
                HStack {
                    Image(systemName: "mic.fill").foregroundStyle(.secondary)
                    Gauge(value: Double(recorder.micLevel)) { EmptyView() }
                        .gaugeStyle(.accessoryLinearCapacity)
                        .tint(recorder.micLevel > 0.9 ? .red : .green)
                        .animation(.linear(duration: 0.1), value: recorder.micLevel)
                }
            }

            if let error = recorder.errorMessage {
                Label(error, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if let last = recorder.lastRecording, recorder.state == .idle {
                HStack {
                    Label("Saved \(last.lastPathComponent)", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .lineLimit(1)
                    Spacer()
                    Button("Show in Finder") { recorder.library.revealInFinder(last) }
                        .buttonStyle(.link)
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var statusText: String {
        switch recorder.state {
        case .idle: "Ready to record"
        case .countingDown(let value): "Starting in \(value)…"
        case .recording: "Recording"
        case .paused: "Paused"
        case .finishing: "Saving…"
        }
    }
}

func formatDuration(_ interval: TimeInterval) -> String {
    let total = Int(interval)
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let seconds = total % 60
    return hours > 0
        ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
        : String(format: "%02d:%02d", minutes, seconds)
}

#Preview {
    ContentView()
        .environment(ScreenRecorder())
}
