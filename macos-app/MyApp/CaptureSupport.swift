import Foundation
import ScreenCaptureKit
import AVFoundation
import Accelerate

enum RecorderError: LocalizedError {
    case noDisplay
    case windowUnavailable
    case noArea
    case emptyRecording
    case exportUnavailable

    var errorDescription: String? {
        switch self {
        case .noDisplay: "No display is available to record."
        case .windowUnavailable: "The selected window is no longer available. Pick another window."
        case .noArea: "Select an area to record first."
        case .emptyRecording: "Nothing was recorded."
        case .exportUnavailable: "The recording couldn't be exported."
        }
    }
}

/// Tracks the lifecycle of one `SCRecordingOutput` (one segment of a recording).
/// ScreenCaptureKit calls these methods on its own queue, so state is guarded by a lock.
nonisolated final class RecordingOutputObserver: NSObject, SCRecordingOutputDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var failure: Error?

    var isFinished: Bool { lock.withLock { finished } }
    var error: Error? { lock.withLock { failure } }

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        lock.withLock { finished = true }
    }

    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        lock.withLock {
            failure = error
            finished = true
        }
    }

    /// Waits (up to `timeout`) for the output to finish writing its file.
    func waitUntilFinished(timeout: Duration = .seconds(5)) async {
        let deadline = ContinuousClock.now + timeout
        while !isFinished, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
}

/// Reports when the system stops the stream (e.g. "Stop Sharing" in the menu bar or the window closed).
nonisolated final class StreamObserver: NSObject, SCStreamDelegate, @unchecked Sendable {
    var onStop: (@Sendable (Error) -> Void)?

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStop?(error)
    }
}

/// Computes a 0...1 microphone level from the stream's microphone samples for the live meter.
nonisolated final class MicLevelMeter: NSObject, SCStreamOutput, @unchecked Sendable {
    let queue = DispatchQueue(label: "ScreenRecorder.MicLevel")
    var onLevel: (@Sendable (Float) -> Void)?

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .microphone, sampleBuffer.isValid,
              let format = sampleBuffer.formatDescription?.audioStreamBasicDescription,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mBitsPerChannel == 32 else { return }

        var rms: Float = 0
        try? sampleBuffer.withAudioBufferList { buffers, _ in
            for buffer in buffers {
                guard let data = buffer.mData else { continue }
                let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                guard count > 0 else { continue }
                var value: Float = 0
                vDSP_rmsqv(data.assumingMemoryBound(to: Float.self), 1, &value, vDSP_Length(count))
                rms = max(rms, value)
            }
        }

        // Map -50 dB...0 dB onto 0...1 so normal speech fills a good part of the meter.
        let decibels = 20 * log10(max(rms, 0.000_01))
        onLevel?(min(1, max(0, (decibels + 50) / 50)))
    }
}

/// Joins recording segments (created by pause/resume) and trims recordings.
nonisolated enum RecordingExporter {
    /// Produces the final file from one or more segments, then deletes the segments.
    static func finalize(segments: [URL], to destination: URL, fileType: AVFileType) async throws -> URL {
        let fileManager = FileManager.default
        let valid = segments.filter { url in
            let size = (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            return size > 0
        }
        defer { segments.forEach { try? fileManager.removeItem(at: $0) } }
        guard !valid.isEmpty else { throw RecorderError.emptyRecording }

        if valid.count == 1 {
            try fileManager.moveItem(at: valid[0], to: destination)
            return destination
        }

        // Append each segment's tracks back to back. Tracks are matched by media type and order,
        // so system audio and microphone tracks stay separate if both exist.
        let composition = AVMutableComposition()
        var compositionTracks: [String: AVMutableCompositionTrack] = [:]
        var cursor = CMTime.zero

        for url in valid {
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)
            var indexByType: [AVMediaType: Int] = [:]

            for track in try await asset.load(.tracks) {
                let index = indexByType[track.mediaType, default: 0]
                indexByType[track.mediaType] = index + 1
                let key = "\(track.mediaType.rawValue)-\(index)"

                let compositionTrack: AVMutableCompositionTrack
                if let existing = compositionTracks[key] {
                    compositionTrack = existing
                } else if let created = composition.addMutableTrack(withMediaType: track.mediaType,
                                                                    preferredTrackID: kCMPersistentTrackID_Invalid) {
                    compositionTracks[key] = created
                    compositionTrack = created
                } else {
                    continue
                }

                let trackRange = try await track.load(.timeRange)
                let range = trackRange.intersection(CMTimeRange(start: .zero, duration: duration))
                guard range.duration > .zero else { continue }
                try compositionTrack.insertTimeRange(range, of: track, at: cursor + range.start)
            }
            cursor = cursor + duration
        }

        try await export(composition, to: destination, fileType: fileType)
        return destination
    }

    /// Exports `timeRange` of the file at `source` into a new file without re-encoding.
    static func trim(_ source: URL, timeRange: CMTimeRange, to destination: URL) async throws {
        let fileType: AVFileType = source.pathExtension.lowercased() == "mov" ? .mov : .mp4
        try await export(AVURLAsset(url: source), to: destination, fileType: fileType, timeRange: timeRange)
    }

    private static func export(_ asset: AVAsset, to destination: URL, fileType: AVFileType,
                               timeRange: CMTimeRange? = nil) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw RecorderError.exportUnavailable
        }
        if let timeRange { session.timeRange = timeRange }
        try await session.export(to: destination, as: fileType)
    }
}
