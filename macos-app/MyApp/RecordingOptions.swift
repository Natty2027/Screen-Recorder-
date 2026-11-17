import Foundation
import AVFoundation
import CoreGraphics

/// What part of the screen gets recorded.
enum CaptureMode: String, Codable, CaseIterable, Identifiable {
    case display, window, area

    var id: String { rawValue }

    var title: String {
        switch self {
        case .display: "Full Screen"
        case .window: "Window"
        case .area: "Area"
        }
    }

    var symbol: String {
        switch self {
        case .display: "display"
        case .window: "macwindow"
        case .area: "rectangle.dashed"
        }
    }
}

enum VideoCodec: String, Codable, CaseIterable, Identifiable {
    case h264, hevc

    var id: String { rawValue }
    var title: String { self == .h264 ? "H.264 (most compatible)" : "HEVC (smaller files)" }
    var avCodec: AVVideoCodecType { self == .h264 ? .h264 : .hevc }
}

enum FileFormat: String, Codable, CaseIterable, Identifiable {
    case mp4, mov

    var id: String { rawValue }
    var title: String { self == .mp4 ? "MP4" : "QuickTime (MOV)" }
    var avFileType: AVFileType { self == .mp4 ? .mp4 : .mov }
    var fileExtension: String { rawValue }
}

enum CaptureQuality: String, Codable, CaseIterable, Identifiable {
    case native, standard

    var id: String { rawValue }
    var title: String { self == .native ? "Retina (full resolution)" : "Standard (smaller files)" }
}

enum AfterRecordingAction: String, Codable, CaseIterable, Identifiable {
    case nothing, open, reveal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .nothing: "Do nothing"
        case .open: "Open the recording"
        case .reveal: "Show in Finder"
        }
    }
}

/// All user-adjustable recording settings. Persisted to UserDefaults as JSON.
struct RecordingOptions: Codable, Equatable {
    var mode: CaptureMode = .display
    var displayID: CGDirectDisplayID?
    var windowID: CGWindowID?
    /// Selected area in display-local points, top-left origin (what ScreenCaptureKit's `sourceRect` expects).
    var area: CGRect?

    var systemAudio = true
    var microphone = true
    var microphoneID: String?

    var camera = false
    var cameraID: String?
    var cameraSize: Double = 180

    var showCursor = true
    var highlightClicks = false
    var frameRate = 60
    var quality: CaptureQuality = .native
    var codec: VideoCodec = .h264
    var format: FileFormat = .mp4

    var countdown = 3
    var hideRecorderWindows = true
    var afterRecording: AfterRecordingAction = .nothing

    private static let defaultsKey = "RecordingOptions"

    static func load() -> RecordingOptions {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let options = try? JSONDecoder().decode(RecordingOptions.self, from: data) else {
            return RecordingOptions()
        }
        return options
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}
