import AppKit
import AVFoundation
import SwiftUI

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    static func screen(for displayID: CGDirectDisplayID?) -> NSScreen? {
        screens.first { $0.displayID == displayID } ?? main
    }

    /// Converts a display-local, top-left-origin rect (ScreenCaptureKit) into AppKit global coordinates.
    func globalRect(fromDisplayRect rect: CGRect) -> CGRect {
        CGRect(x: frame.minX + rect.minX, y: frame.maxY - rect.maxY, width: rect.width, height: rect.height)
    }
}

// MARK: - Camera bubble

/// A round, draggable, always-on-top webcam preview. Because it's a real on-screen window,
/// it's captured as part of full-screen and area recordings.
final class CameraBubble {
    private var panel: NSPanel?
    private var session: AVCaptureSession?
    private var deviceID: String?

    var windowID: CGWindowID? { panel.map { CGWindowID($0.windowNumber) } }

    func show(deviceID: String?, size: CGFloat) async {
        guard await AVCaptureDevice.requestAccess(for: .video) else { return }

        if let panel, self.deviceID == deviceID {
            var frame = panel.frame
            frame.origin.y += frame.height - size
            frame.size = CGSize(width: size, height: size)
            panel.setFrame(frame, display: true, animate: true)
            (panel.contentView as? CameraPreviewView)?.updateShape()
            return
        }
        hide()

        guard let device = deviceID.flatMap(AVCaptureDevice.init(uniqueID:)) ?? AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else { return }

        let session = AVCaptureSession()
        session.sessionPreset = .high
        guard session.canAddInput(input) else { return }
        session.addInput(input)

        let visible = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1280, height: 800)
        let frame = CGRect(x: visible.maxX - size - 32, y: visible.minY + 32, width: size, height: size)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = CameraPreviewView(session: session)
        panel.orderFrontRegardless()

        self.panel = panel
        self.session = session
        self.deviceID = deviceID

        nonisolated(unsafe) let runningSession = session
        DispatchQueue.global(qos: .userInitiated).async { runningSession.startRunning() }
    }

    func hide() {
        if let session {
            nonisolated(unsafe) let stoppingSession = session
            DispatchQueue.global(qos: .userInitiated).async { stoppingSession.stopRunning() }
        }
        panel?.orderOut(nil)
        panel = nil
        session = nil
        deviceID = nil
    }
}

private final class CameraPreviewView: NSView {
    private let previewLayer: AVCaptureVideoPreviewLayer

    init(session: AVCaptureSession) {
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        super.init(frame: .zero)
        wantsLayer = true
        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.borderColor = NSColor.white.cgColor
        previewLayer.borderWidth = 3
        previewLayer.masksToBounds = true
        if let connection = previewLayer.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }
        layer = previewLayer
        autoresizingMask = [.width, .height]
    }

    required init?(coder: NSCoder) { nil }

    override var mouseDownCanMoveWindow: Bool { true }

    override func layout() {
        super.layout()
        updateShape()
    }

    func updateShape() {
        previewLayer.cornerRadius = min(bounds.width, bounds.height) / 2
    }
}

// MARK: - Area selection

/// Shows a dimmed overlay on every screen and lets the user drag out the area to record.
final class AreaSelector {
    private var windows: [NSWindow] = []
    private var continuation: CheckedContinuation<(CGDirectDisplayID, CGRect)?, Never>?

    /// Returns the display and the selected rect (display-local points, top-left origin), or nil if cancelled.
    func select() async -> (CGDirectDisplayID, CGRect)? {
        finish(nil)
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            for screen in NSScreen.screens {
                guard let displayID = screen.displayID else { continue }
                let window = OverlayWindow(contentRect: screen.frame, styleMask: .borderless,
                                           backing: .buffered, defer: false)
                window.level = .screenSaver
                window.isOpaque = false
                window.backgroundColor = .clear
                window.setFrame(screen.frame, display: true)
                window.contentView = AreaSelectionView { [weak self] rect in
                    self?.finish(rect.map { (displayID, $0) })
                }
                window.makeKeyAndOrderFront(nil)
                windows.append(window)
            }
            NSApp.activate()
            NSCursor.crosshair.push()
        }
    }

    private func finish(_ result: (CGDirectDisplayID, CGRect)?) {
        guard let continuation else { return }
        self.continuation = nil
        NSCursor.pop()
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        continuation.resume(returning: result)
    }
}

private final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

private final class AreaSelectionView: NSView {
    private let onComplete: (CGRect?) -> Void
    private var start: CGPoint?
    private var selection: CGRect?

    init(onComplete: @escaping (CGRect?) -> Void) {
        self.onComplete = onComplete
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        window?.makeFirstResponder(self)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onComplete(nil) } // Esc
    }

    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, from: nil)
        selection = nil
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        let point = convert(event.locationInWindow, from: nil)
        selection = CGRect(x: min(start.x, point.x), y: min(start.y, point.y),
                           width: abs(point.x - start.x), height: abs(point.y - start.y)).integral
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let selection, selection.width >= 20, selection.height >= 20 else {
            self.selection = nil
            needsDisplay = true
            return
        }
        // Flip to top-left origin, which ScreenCaptureKit's sourceRect uses.
        onComplete(CGRect(x: selection.minX, y: bounds.height - selection.maxY,
                          width: selection.width, height: selection.height))
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.4).setFill()
        bounds.fill()

        if let selection {
            NSColor.clear.setFill()
            selection.fill(using: .copy)

            let border = NSBezierPath(rect: selection.insetBy(dx: -1, dy: -1))
            border.lineWidth = 2
            border.setLineDash([6, 4], count: 2, phase: 0)
            NSColor.white.setStroke()
            border.stroke()

            drawLabel("\(Int(selection.width)) × \(Int(selection.height))",
                      at: CGPoint(x: selection.minX, y: max(selection.minY - 26, 4)))
        }

        let hint = "Drag to select the area to record  ·  Esc to cancel"
        let hintSize = (hint as NSString).size(withAttributes: labelAttributes)
        drawLabel(hint, at: CGPoint(x: bounds.midX - hintSize.width / 2, y: bounds.maxY - 80))
    }

    private var labelAttributes: [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.white]
    }

    private func drawLabel(_ text: String, at point: CGPoint) {
        let size = (text as NSString).size(withAttributes: labelAttributes)
        let background = CGRect(x: point.x, y: point.y, width: size.width + 16, height: size.height + 8)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: background, xRadius: 6, yRadius: 6).fill()
        (text as NSString).draw(at: CGPoint(x: point.x + 8, y: point.y + 4), withAttributes: labelAttributes)
    }
}

// MARK: - Area outline while recording

/// Draws a click-through border just outside the recorded area so you can see what's being captured.
final class AreaOutline {
    private var panel: NSPanel?

    func show(area: CGRect, displayID: CGDirectDisplayID?) {
        hide()
        guard let screen = NSScreen.screen(for: displayID) else { return }
        let inset: CGFloat = 4
        let frame = screen.globalRect(fromDisplayRect: area).insetBy(dx: -inset, dy: -inset)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView:
            Rectangle()
                .strokeBorder(Color.red.opacity(0.85), style: StrokeStyle(lineWidth: 2, dash: [8, 5]))
        )
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }
}

// MARK: - Countdown HUD

final class CountdownHUD {
    private var panel: NSPanel?
    private let model = Model()

    @Observable final class Model {
        var value = 3
    }

    func show(_ value: Int, displayID: CGDirectDisplayID?) {
        model.value = value
        guard panel == nil, let screen = NSScreen.screen(for: displayID) else { return }
        let size: CGFloat = 180
        let frame = CGRect(x: screen.frame.midX - size / 2, y: screen.frame.midY - size / 2, width: size, height: size)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.contentView = NSHostingView(rootView: CountdownView(model: model))
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
    }

    private struct CountdownView: View {
        let model: Model

        var body: some View {
            Text("\(model.value)")
                .font(.system(size: 96, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .contentTransition(.numericText(countsDown: true))
                .animation(.snappy, value: model.value)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.black.opacity(0.65), in: .rect(cornerRadius: 32))
        }
    }
}
