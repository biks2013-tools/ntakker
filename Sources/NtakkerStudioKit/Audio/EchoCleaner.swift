// NtakkerStudioKit/Audio/EchoCleaner.swift — 2026-10-17.
//
// Writes a copy of a recording's microphone track with the echo of the
// system track removed: the same NLMS canceller the player's "Remove
// echo" switch uses (`SoftwareAECProcessor.processAligned`, playback
// tuning), with the system track delayed by the recording's measured
// echo delay (`EchoDelayEstimator`) so the echo falls inside the
// filter's window.
//
// Offline the filter can do better than live playback: a warm-up pass
// over the first minute learns the echo path, then the whole track is
// processed from the start with what was learnt, so the opening seconds
// are clean too.

import AVFoundation
import Foundation
import NtakkerCore

public enum EchoCleanerError: Error, LocalizedError {
    case notSplit
    case formatMismatch

    public var errorDescription: String? {
        switch self {
        case .notSplit: return "Removing echo needs a recording with separate microphone and system tracks."
        case .formatMismatch: return "The microphone and system tracks have different sample rates."
        }
    }
}

public enum EchoCleaner {
    static let blockFrames = 8_192
    /// Seconds of audio the warm-up pass learns from.
    public static let warmUpSeconds = 60.0

    /// Write `micURL` cleaned of the echo of `systemURL` to `destination`,
    /// in the mic file's own format.
    /// - Returns: the echo delay that was used, in seconds.
    @discardableResult
    public static func clean(
        micURL: URL,
        systemURL: URL,
        to destination: URL,
        settings: EchoFilterSettings = .standard,
        delayOverride: Double? = nil,
        progress: (Double) -> Void = { _ in }
    ) throws -> Double {
        let mic = try AVAudioFile(forReading: micURL)
        let sys = try AVAudioFile(forReading: systemURL)
        let rate = mic.processingFormat.sampleRate
        guard sys.processingFormat.sampleRate == rate else { throw EchoCleanerError.formatMismatch }
        let duration = Double(mic.length) / rate
        let lag = try delayOverride ?? EchoDelayEstimator.estimate(micURL: micURL, systemURL: systemURL, duration: duration) ?? 0
        let delay = AVAudioFramePosition(max(0, lag - EchoDelayEstimator.referenceMargin) * rate)

        let echo = EchoProcessor(sampleRate: rate, settings: settings)
        let warmUp = min(mic.length, AVAudioFramePosition(warmUpSeconds * rate))
        let total = Double(warmUp + mic.length)
        var done = 0.0

        // Warm-up: learn the echo path, discard the output.
        var pos: AVAudioFramePosition = 0
        while pos < warmUp {
            if Task.isCancelled { throw CancellationError() }
            let n = Int(min(AVAudioFramePosition(blockFrames), warmUp - pos))
            _ = echo.process(mic: mono(read(mic, at: pos, n)), reference: mono(read(sys, at: pos - delay, n)), produceOutput: false)
            pos += AVAudioFramePosition(n)
            done += Double(n)
            progress(done / total)
        }
        echo.resetTimeline()

        let out = try AVAudioFile(
            forWriting: destination,
            settings: mic.fileFormat.settings,
            commonFormat: mic.processingFormat.commonFormat,
            interleaved: mic.processingFormat.isInterleaved
        )
        let channels = Int(mic.processingFormat.channelCount)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: mic.processingFormat, frameCapacity: AVAudioFrameCount(blockFrames)) else {
            throw EchoCleanerError.formatMismatch
        }
        // The second stage delays the output by `latency` samples: skip that
        // many at the start and feed as many extra (silent) at the end, so
        // the cleaned track stays sample-aligned with the original.
        var skip = echo.latency
        pos = 0
        let end = mic.length + AVAudioFramePosition(echo.latency)
        while pos < end {
            if Task.isCancelled { throw CancellationError() }
            let n = Int(min(AVAudioFramePosition(blockFrames), end - pos))
            var cleaned = echo.process(mic: mono(read(mic, at: pos, n)), reference: mono(read(sys, at: pos - delay, n)))
            if skip > 0 {
                let drop = min(skip, cleaned.count)
                cleaned.removeFirst(drop)
                skip -= drop
            }
            let room = Int(mic.length - out.length)
            if cleaned.count > room { cleaned.removeLast(cleaned.count - room) }
            if !cleaned.isEmpty {
                buffer.frameLength = AVAudioFrameCount(cleaned.count)
                for c in 0..<channels {
                    cleaned.withUnsafeBufferPointer { src in
                        _ = memcpy(buffer.floatChannelData![c], src.baseAddress!, cleaned.count * MemoryLayout<Float>.size)
                    }
                }
                try out.write(from: buffer)
            }
            pos += AVAudioFramePosition(n)
            done += Double(n)
            progress(min(1, done / total))
        }
        return lag
    }

    /// `n` frames from `at`; frames before 0 or past the end are silence.
    static func read(_ file: AVAudioFile, at: AVAudioFramePosition, _ n: Int) -> [[Float]] {
        let chans = Int(file.processingFormat.channelCount)
        let lead = Int(max(0, min(AVAudioFramePosition(n), -at)))
        let from = max(0, at)
        let want = n - lead
        var result = Array(repeating: [Float](repeating: 0, count: n), count: chans)
        guard want > 0, from < file.length,
              let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(want))
        else { return result }
        file.framePosition = from
        try? file.read(into: buf, frameCount: AVAudioFrameCount(want))
        let got = Int(buf.frameLength)
        for c in 0..<chans {
            let src = buf.floatChannelData![c]
            for i in 0..<got { result[c][lead + i] = src[i] }
        }
        return result
    }

    static func mono(_ chans: [[Float]]) -> [Float] {
        guard chans.count > 1 else { return chans.first ?? [] }
        let k = 1 / Float(chans.count)
        var m = chans[0]
        for c in chans.dropFirst() { for i in m.indices { m[i] += c[i] } }
        for i in m.indices { m[i] *= k }
        return m
    }
}
