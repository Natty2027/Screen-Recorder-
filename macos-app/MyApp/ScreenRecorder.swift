import AppKit
import AVFoundation
import Carbon.HIToolbox
import Observation
import ScreenCaptureKit

/// Drives a recording: picks sources, runs the ScreenCaptureKit stream, and handles
/// countdown, pause/resume (as file segments that get joined at the end), and saving.
@Observable
final class ScreenRecorder {
    enum State: Equatable {
        case idle
        case countingDown(Int)
        case recording
        case paused
        case finishing
    }

    private(set) var state: State = .idle
    var options = RecordingOptions.load() {
        didSet { options.save() }
    }

    private(set) var displays: [SCDisplay] = []
    private(set) var windows: [SCWindow] = []
    private(set) var microphones: [AVCaptureDevice] = []
    private(set) var cameras: [AVCaptureDevice] = []
    private(set) var hasScreenPermission = CGPreflightScreenCaptureAccess()

    private(set) var elapsed: TimeInterval = 0
    private(set) var micLevel: Float = 0
    var errorMessage: String?
    private(set) var lastRecording: URL?

    let library = RecordingLibrary()

    private let cameraBubble = CameraBubble()
    private let areaSelector = AreaSelector()
    private let areaOutline = AreaOutline()
    private let streamObserver = StreamObserver()
    private let micMeter = MicLevelMeter()

    private var stream: SCStream?
    private var currentOutput: SCRecordingOutput?
    private var currentObserver: RecordingOutputObserver?
    private var segments: [URL] = []
    private var segmentStart: Date?
    private var accumulated: TimeInterval = 0
    private var isTransitioning = false
    private var countdownTask: Task<Void, Never>?
    private var clockTask: Task<Void, Never>?

    var isActive: Bool { state == .recording || state == .paused }

    init() {
        streamObserver.onStop = { [weak self] _ in
            Task { @MainActor [weak self] in self?.streamStoppedBySystem() }
        }
        micMeter.onLevel = { [weak self] level in
            Task { @MainActor [weak self] in self?.micLevel = level }
        }
        registerHotKeys()
    }

    // MARK: - Sources

    func refreshSources() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            let ownPID = ProcessInfo.processInfo.processIdentifier
            displays = content.displays
            windows = content.windows
                .filter { window in
                    window.windowLayer == 0 && window.frame.width > 80 && window.frame.height > 60
                        && window.owningApplication?.processID != ownPID
                        && !(window.title ?? "").isEmpty
                }
                .sorted { ($0.owningApplication?.applicationName ?? "") < ($1.owningApplication?.applicationName ?? "") }
            hasScreenPermission = true

            if !displays.contains(where: { $0.displayID == options.displayID }) {
                options.displayID = displays.first?.displayID
            }
        } catch {
            hasScreenPermission = false
        }

        microphones = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external],
                                                       mediaType: .audio, position: .unspecified).devices
        cameras = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
                                                   mediaType: .video, position: .unspecified).devices
    }

    func displayName(_ display: SCDisplay) -> String {
        let name = NSScreen.screen(for: display.displayID)?.localizedName ?? "Display"
        return "\(name) (\(display.width) × \(display.height))"
    }

    func windowName(_ window: SCWindow) -> String {
        let app = window.owningApplication?.applicationName ?? "Unknown"
        return "\(app) — \(window.title ?? "Untitled")"
    }

    func requestScreenPermission() {
        if !CGRequestScreenCaptureAccess(),
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Camera & area

    /// Shows, hides, or updates the floating camera bubble to match the current options.
    func syncCameraBubble() async {
        if options.camera {
            await cameraBubble.show(deviceID: options.cameraID, size: options.cameraSize)
        } else {
            cameraBubble.hide()
        }
    }

    @discardableResult
    func selectArea() async -> Bool {
        guard let (displayID, rect) = await areaSelector.select() else { return false }
        options.displayID = displayID
        options.area = rect
        options.mode = .area
        return true
    }

    // MARK: - Recording control

    func toggleRecording() {
        switch state {
        case .idle: start()
        case .countingDown: cancelCountdown()
        case .recording, .paused: Task { await stop() }
        case .finishing: break
        }
    }

    func togglePause() {
        Task {
            if state == .recording { await pause() } else if state == .paused { await resume() }
        }
    }

    func start() {
        guard state == .idle else { return }
        errorMessage = nil
        countdownTask = Task {
            if options.mode == .area, options.area == nil {
                guard await selectArea() else { return }
            }
            if options.microphone {
                _ = await AVCaptureDevice.requestAccess(for: .audio)
            }

            if options.countdown > 0 {
                let hud = CountdownHUD()
                defer { hud.close() }
                for value in stride(from: options.countdown, to: 0, by: -1) {
                    state = .countingDown(value)
                    hud.show(value, displayID: options.mode == .window ? nil : options.displayID)
                    try? await Task.sleep(for: .seconds(1))
                    if Task.isCancelled {
                        state = .idle
                        return
                    }
                }
            }
            await beginCapture()
        }
    }

    func cancelCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
        state = .idle
    }

    private func beginCapture() async {
        state = .finishing // Busy until the stream is running.
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let (filter, configuration) = try makeFilterAndConfiguration(content: content)
            let stream = SCStream(filter: filter, configuration: configuration, delegate: streamObserver)
            if options.microphone {
                try stream.addStreamOutput(micMeter, type: .microphone, sampleHandlerQueue: micMeter.queue)
            }
            try await stream.startCapture()
            self.stream = stream

            segments = []
            accumulated = 0
            elapsed = 0
            try startSegment()
            state = .recording
            startClock()

            if options.mode == .area, let area = options.area {
                areaOutline.show(area: area, displayID: options.displayID)
            }
        } catch {
            errorMessage = error.localizedDescription
            await tearDown()
            state = .idle
        }
    }

    func pause() async {
        guard state == .recording, !isTransitioning else { return }
        isTransitioning = true
        defer { isTransitioning = false }

        closeSegmentClock()
        state = .paused
        await finishCurrentSegment()
    }

    func resume() async {
        guard state == .paused, !isTransitioning else { return }
        isTransitioning = true
        defer { isTransitioning = false }

        do {
            try startSegment()
            state = .recording
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stop() async {
        guard isActive, !isTransitioning else { return }
        isTransitioning = true
        defer { isTransitioning = false }

        closeSegmentClock()
        state = .finishing
        await finishCurrentSegment()
        try? await stream?.stopCapture()
        await tearDown()

        do {
            let destination = library.newRecordingURL(fileExtension: options.format.fileExtension)
            let url = try await RecordingExporter.finalize(segments: segments, to: destination,
                                                           fileType: options.format.avFileType)
            lastRecording = url
            library.reload()
            switch options.afterRecording {
            case .nothing: break
            case .open: NSWorkspace.shared.open(url)
            case .reveal: library.revealInFinder(url)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        segments = []
        state = .idle
    }

    // MARK: - Internals

    private func makeFilterAndConfiguration(content: SCShareableContent) throws -> (SCContentFilter, SCStreamConfiguration) {
        let configuration = SCStreamConfiguration()
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let filter: SCContentFilter
        let sourceSize: CGSize

        switch options.mode {
        case .display, .area:
            guard let display = content.displays.first(where: { $0.displayID == options.displayID })
                    ?? content.displays.first else { throw RecorderError.noDisplay }
            // Hide this app's windows, but keep the camera bubble so it ends up in the video.
            let ownApps = options.hideRecorderWindows ? content.applications.filter { $0.processID == ownPID } : []
            let bubble = content.windows.filter { $0.windowID == cameraBubble.windowID }
            filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: bubble)

            if options.mode == .area {
                guard let area = options.area else { throw RecorderError.noArea }
                let rect = area.intersection(CGRect(x: 0, y: 0, width: display.width, height: display.height)).integral
                guard !rect.isEmpty else { throw RecorderError.noArea }
                configuration.sourceRect = rect
                sourceSize = rect.size
            } else {
                sourceSize = CGSize(width: display.width, height: display.height)
            }

        case .window:
            guard let window = content.windows.first(where: { $0.windowID == options.windowID }) else {
                throw RecorderError.windowUnavailable
            }
            filter = SCContentFilter(desktopIndependentWindow: window)
            sourceSize = window.frame.size
        }

        // Video encoders need even dimensions.
        let scale = options.quality == .native ? CGFloat(filter.pointPixelScale) : 1
        configuration.width = Int(sourceSize.width * scale) & ~1
        configuration.height = Int(sourceSize.height * scale) & ~1
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(options.frameRate))
        configuration.queueDepth = 6
        configuration.showsCursor = options.showCursor
        configuration.showMouseClicks = options.highlightClicks

        configuration.capturesAudio = options.systemAudio
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.captureMicrophone = options.microphone
        configuration.microphoneCaptureDeviceID = options.microphoneID

        return (filter, configuration)
    }

    /// Starts writing a new segment file. Each resume after a pause creates a new segment.
    private func startSegment() throws {
        guard let stream else { return }
        let url = FileManager.default.temporaryDirectory
            .appending(path: "segment-\(UUID().uuidString).\(options.format.fileExtension)")

        let configuration = SCRecordingOutputConfiguration()
        configuration.outputURL = url
        configuration.outputFileType = options.format.avFileType
        configuration.videoCodecType = options.codec.avCodec

        let observer = RecordingOutputObserver()
        let output = SCRecordingOutput(configuration: configuration, delegate: observer)
        try stream.addRecordingOutput(output)

        currentOutput = output
        currentObserver = observer
        segments.append(url)
        segmentStart = .now
    }

    private func finishCurrentSegment() async {
        guard let output = currentOutput, let observer = currentObserver else { return }
        try? stream?.removeRecordingOutput(output)
        await observer.waitUntilFinished()
        if let error = observer.error {
            errorMessage = error.localizedDescription
        }
        currentOutput = nil
        currentObserver = nil
    }

    private func closeSegmentClock() {
        if let segmentStart {
            accumulated += Date.now.timeIntervalSince(segmentStart)
        }
        segmentStart = nil
        elapsed = accumulated
    }

    private func startClock() {
        clockTask?.cancel()
        clockTask = Task {
            while !Task.isCancelled {
                elapsed = accumulated + (segmentStart.map { Date.now.timeIntervalSince($0) } ?? 0)
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    private func tearDown() async {
        clockTask?.cancel()
        clockTask = nil
        areaOutline.hide()
        stream = nil
        micLevel = 0
    }

    /// The user stopped sharing from the system menu, or the recorded window went away.
    private func streamStoppedBySystem() {
        guard isActive else { return }
        Task { await stop() }
    }

    private func registerHotKeys() {
        let modifiers = cmdKey | optionKey
        HotKeyCenter.shared.register(keyCode: kVK_ANSI_R, modifiers: modifiers) { [weak self] in
            self?.toggleRecording()
        }
        HotKeyCenter.shared.register(keyCode: kVK_ANSI_P, modifiers: modifiers) { [weak self] in
            self?.togglePause()
        }
        HotKeyCenter.shared.register(keyCode: kVK_ANSI_A, modifiers: modifiers) { [weak self] in
            guard let self, self.state == .idle else { return }
            Task {
                if await self.selectArea() { self.start() }
            }
        }
    }
}
