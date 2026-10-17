import AVFoundation
import Foundation
@testable import NtakkerStudioKit
import NtakkerCore

enum StudioFixtures {

    static func tempDir(_ name: String = "studio") -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ntakker-studio-tests-\(name)-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func touch(_ url: URL, _ text: String = "") {
        try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! Data(text.utf8).write(to: url)
    }

    /// A mono 16-bit WAV at `rate`, filled by `sample(i)` in -1…1.
    static func writeWAV(_ url: URL, seconds: Double, rate: Double = 16_000, channels: AVAudioChannelCount = 1,
                         sample: (Int) -> Float = { i in sinf(Float(i) * 0.05) * 0.5 }) {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try! AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let total = Int(seconds * rate)
        let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(total))!
        buf.frameLength = AVAudioFrameCount(total)
        for c in 0..<Int(channels) {
            for i in 0..<total { buf.floatChannelData![c][i] = sample(i) }
        }
        try! file.write(from: buf)
    }

    static func segment(_ text: String, at ts: Date, duration: Double? = 2, model: String? = "soniox",
                        source: SourceTag = .microphone, speaker: String? = nil) -> TranscriptSegment {
        TranscriptSegment(timestamp: ts, text: text, source: source, model: model, durationSec: duration, speaker: speaker)
    }
}
