// NtakkerStudioKit/Audio/WaveformPeaks.swift — plan-024 T8.
//
// A coarse amplitude envelope of a recording for the waveform strip:
// `bucketCount` peak values in 0…1, one per equal slice of time, taken
// over all tracks (a split recording shows mic and system together).

import Accelerate
import AVFoundation
import Foundation

public struct WaveformPeaks: Sendable, Equatable {
    public let peaks: [Float]
    public let duration: Double

    public static let empty = WaveformPeaks(peaks: [], duration: 0)

    public init(peaks: [Float], duration: Double) {
        self.peaks = peaks
        self.duration = duration
    }

    /// Read every track and build the envelope. Reads the whole audio
    /// once, in 64k-frame blocks; cancellable between blocks.
    public static func load(tracks: [URL], bucketCount: Int) throws -> WaveformPeaks {
        precondition(bucketCount > 0)
        var peaks = [Float](repeating: 0, count: bucketCount)
        var duration = 0.0
        for url in tracks {
            let file = try AVAudioFile(forReading: url)
            duration = max(duration, Double(file.length) / file.fileFormat.sampleRate)
        }
        guard duration > 0 else { return WaveformPeaks(peaks: peaks, duration: 0) }

        for url in tracks {
            let file = try AVAudioFile(forReading: url)
            let rate = file.processingFormat.sampleRate
            guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 262_144) else { continue }
            let channels = Int(file.processingFormat.channelCount)
            var position: AVAudioFramePosition = 0
            while position < file.length {
                if Task.isCancelled { return .empty }
                try file.read(into: buf)
                let n = Int(buf.frameLength)
                if n == 0 { break }
                guard let data = buf.floatChannelData else { break }
                // Peak of each 1024-frame stride (vDSP), folded into its bucket.
                var i = 0
                while i < n {
                    let len = min(1024, n - i)
                    var peak: Float = 0
                    for c in 0..<channels {
                        var m: Float = 0
                        vDSP_maxmgv(data[c] + i, 1, &m, vDSP_Length(len))
                        peak = max(peak, m)
                    }
                    let t = Double(position + AVAudioFramePosition(i)) / rate
                    let b = min(bucketCount - 1, Int(t / duration * Double(bucketCount)))
                    peaks[b] = max(peaks[b], min(1, peak))
                    i += len
                }
                position += AVAudioFramePosition(n)
            }
        }
        return WaveformPeaks(peaks: peaks, duration: duration)
    }
}
