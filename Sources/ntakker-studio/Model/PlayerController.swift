// ntakker-studio/Model/PlayerController.swift — plan-024 T9, echo filter
// added 2026-10-17.
//
// Plays a recording through AVAudioEngine. A reader on its own queue
// pulls blocks of ~170 ms from every track, and keeps about 0.7 s
// scheduled on an AVAudioPlayerNode:
//
//   mic file ─┐
//             ├─ [echo filter: mic − echo of system] ─ mix ─ player ─ time-pitch ─ out
//   system ───┘
//
// The echo filter is ntakker's NLMS echo canceller fed with the system
// track as the reference (`SoftwareAECProcessor.processAligned`). It
// only exists for a split recording (separate mic and system files);
// switching it takes effect from the next block, so within ~0.7 s.
// Seeking drops what is scheduled and restarts the reader; the filter
// keeps what it has learnt about the echo path.
//
// `currentTime` is published 20 times a second for the transcript
// follow and the waveform playhead. With `skipRanges` set (cut
// preview), playback jumps over them.

import AVFoundation
import Foundation
import NtakkerCore
import NtakkerStudioKit
import Observation

@MainActor @Observable
final class PlayerController {
    private(set) var duration: Double = 0
    private(set) var currentTime: Double = 0
    private(set) var isPlaying = false
    private(set) var loadError: String?
    /// Whether this recording has separate mic and system tracks, so the
    /// echo filter can run.
    private(set) var canFilterEcho = false
    var echoFilter = false {
        didSet { reader?.setEchoFilter(echoFilter) }
    }
    /// Strength, second-stage suppression and adaptation speed.
    var echoSettings = EchoFilterSettings.load() {
        didSet { if echoSettings != oldValue { reader?.setSettings(echoSettings) } }
    }
    /// The echo delay set by hand (seconds); `nil` = the measured one.
    var echoDelayOverride: Double? {
        didSet { if echoDelayOverride != oldValue { applyEchoDelay() } }
    }
    /// The delay in use: the override, else the measured one.
    var effectiveEchoDelay: Double? { echoDelayOverride ?? echoDelay }
    /// Measured delay of the echo behind the system track, once known.
    private(set) var echoDelay: Double?
    var rate: Float = 1 {
        didSet { timePitch.rate = rate }
    }
    /// Ranges playback skips (the cut preview).
    var skipRanges: [ClosedRange<Double>] = []

    static let availableRates: [Float] = [0.75, 1, 1.25, 1.5, 1.75, 2]

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private let node = AVAudioPlayerNode()
    @ObservationIgnored private let timePitch = AVAudioUnitTimePitch()
    @ObservationIgnored private var reader: BlockReader?
    @ObservationIgnored private var sampleRate: Double = 48_000
    /// File frame at which the current schedule started.
    @ObservationIgnored private var startFrame: AVAudioFramePosition = 0
    @ObservationIgnored private var timer: Timer?

    init() {
        engine.attach(node)
        engine.attach(timePitch)
    }

    func teardown() {
        timer?.invalidate()
        timer = nil
        reader?.cancel()
        node.stop()
        engine.stop()
    }

    func load(tracks: [AudioTrack]) async {
        do {
            let r = try BlockReader(tracks: tracks)
            reader = r
            sampleRate = r.format.sampleRate
            duration = Double(r.length) / r.format.sampleRate
            canFilterEcho = r.hasEchoReference
            engine.connect(node, to: timePitch, format: r.format)
            engine.connect(timePitch, to: engine.mainMixerNode, format: r.format)
            engine.prepare()
            r.onBlock = { [weak self] buffer, last, gen in
                self?.node.scheduleBuffer(buffer) {
                    guard r.blockConsumed(generation: gen), last else { return }
                    Task { @MainActor in self?.reachedEnd() }
                }
            }
            r.setEchoFilter(echoFilter)
            r.setSettings(echoSettings)
            applyEchoDelay()
            if r.hasEchoReference, let mic = tracks.first(where: { $0.role == .microphone }),
               let sys = tracks.first(where: { $0.role == .system }) {
                let length = duration
                Task.detached(priority: .utility) { [weak self] in
                    let lag = (try? EchoDelayEstimator.estimate(micURL: mic.url, systemURL: sys.url, duration: length)) ?? nil
                    guard let lag else { return }
                    await MainActor.run {
                        self?.echoDelay = lag
                        if self?.echoDelayOverride == nil { self?.applyEchoDelay() }
                    }
                }
            }
        } catch {
            loadError = error.localizedDescription
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func applyEchoDelay() {
        guard let d = effectiveEchoDelay else { return }
        reader?.setReferenceDelay(seconds: d - EchoDelayEstimator.referenceMargin)
    }

    func togglePlay() { isPlaying ? pause() : play() }

    func play() {
        guard let reader else { return }
        if currentTime >= duration - 0.05 { seek(to: 0) }
        do {
            if !engine.isRunning { try engine.start() }
        } catch {
            loadError = "Audio output: \(error.localizedDescription)"
            return
        }
        if !reader.isRunning {
            startFrame = AVAudioFramePosition(currentTime * sampleRate)
            reader.start(at: startFrame)
        }
        node.play()
        isPlaying = true
    }

    func pause() {
        node.pause()
        isPlaying = false
    }

    func seek(to seconds: Double) {
        let t = min(max(0, seconds), max(0, duration))
        currentTime = t
        guard let reader else { return }
        let wasPlaying = isPlaying
        reader.cancel()
        node.stop()
        startFrame = AVAudioFramePosition(t * sampleRate)
        if wasPlaying {
            reader.start(at: startFrame)
            node.play()
        }
    }

    func skip(by seconds: Double) { seek(to: currentTime + seconds) }

    private func reachedEnd() {
        isPlaying = false
        node.stop()
        reader?.cancel()
        currentTime = duration
    }

    private func tick() {
        guard isPlaying,
              let nodeTime = node.lastRenderTime,
              let playerTime = node.playerTime(forNodeTime: nodeTime)
        else { return }
        let t = Double(startFrame + playerTime.sampleTime) / sampleRate
        guard t.isFinite else { return }
        if let r = skipRanges.first(where: { $0.contains(t) && t < $0.upperBound - 0.05 }) {
            seek(to: r.upperBound)
            return
        }
        currentTime = min(t, duration)
    }
}

/// Reads, filters and mixes blocks on its own queue and hands them to
/// the player, keeping `targetQueued` blocks scheduled ahead.
final class BlockReader: @unchecked Sendable {
    static let blockFrames: AVAudioFrameCount = 8_192
    static let targetQueued = 4

    let format: AVAudioFormat
    let length: AVAudioFramePosition
    let hasEchoReference: Bool
    var isRunning: Bool { queue.sync { running } }
    /// Called on the reader queue with each block; `last` marks the end
    /// of the audio, `generation` the schedule the block belongs to.
    var onBlock: ((AVAudioPCMBuffer, _ last: Bool, _ generation: Int) -> Void)?

    private let queue = DispatchQueue(label: "ntakker-studio.player.reader", qos: .userInitiated)
    private let files: [(file: AVAudioFile, role: AudioTrackRole)]
    private let echo: EchoProcessor?
    /// A second reader of the system track for the echo reference, read
    /// `referenceDelay` frames behind the playback position.
    private let referenceFile: AVAudioFile?
    private var referenceDelay: AVAudioFramePosition = 0
    private var running = false
    private var generation = 0
    private var position: AVAudioFramePosition = 0
    private var queued = 0
    private var echoFilter = false
    private var filterPrimed = false

    init(tracks: [AudioTrack]) throws {
        let opened = try tracks.map { (file: try AVAudioFile(forReading: $0.url), role: $0.role) }
        guard let first = opened.first else { throw CocoaError(.fileReadNoSuchFile) }
        let rate = first.file.processingFormat.sampleRate
        let channels = opened.map { $0.file.processingFormat.channelCount }.max() ?? 1
        guard opened.allSatisfy({ $0.file.processingFormat.sampleRate == rate }),
              let fmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: max(1, min(2, channels)))
        else { throw CocoaError(.fileReadCorruptFile) }
        files = opened
        format = fmt
        length = opened.map(\.file.length).max() ?? 0
        hasEchoReference = opened.contains { $0.role == .microphone } && opened.contains { $0.role == .system }
        let echo = opened.contains { $0.role == .microphone } && opened.contains { $0.role == .system }

        self.echo = echo ? EchoProcessor(sampleRate: rate, settings: .standard) : nil
        referenceFile = echo ? try tracks.first { $0.role == .system }.map { try AVAudioFile(forReading: $0.url) } : nil
    }

    /// Delay the echo reference by `seconds` (the measured echo delay
    /// minus a margin). Clears what the filter learnt, which no longer
    /// lines up.
    func setReferenceDelay(seconds: Double) {
        queue.async {
            self.referenceDelay = AVAudioFramePosition(max(0, seconds) * self.format.sampleRate)
            self.echo?.resetEchoPath()
        }
    }

    func setSettings(_ settings: EchoFilterSettings) {
        queue.async { self.echo?.update(settings) }
    }

    func setEchoFilter(_ on: Bool) { queue.async { self.echoFilter = on } }

    func start(at frame: AVAudioFramePosition) {
        queue.sync {
            generation += 1
            running = true
            position = max(0, min(frame, length))
            queued = 0
            echo?.resetTimeline()
            for _ in 0..<Self.targetQueued { produce() }
        }
    }

    func cancel() {
        queue.sync {
            generation += 1
            running = false
            queued = 0
        }
    }

    /// A scheduled block finished playing or was dropped (called from
    /// the audio thread). Returns whether it belonged to the current
    /// schedule; a block from before a seek is ignored.
    @discardableResult
    func blockConsumed(generation gen: Int) -> Bool {
        let current = queue.sync { generation == gen && running }
        guard current else { return false }
        queue.async {
            guard gen == self.generation, self.running else { return }
            self.queued = max(0, self.queued - 1)
            self.produce()
        }
        return true
    }

    /// Read, filter and mix the next block. On the reader queue.
    private func produce() {
        guard running, queued < Self.targetQueued, position < length else { return }
        let n = AVAudioFrameCount(min(AVAudioFramePosition(Self.blockFrames), length - position))
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: n) else { return }
        out.frameLength = n
        let outCh = Int(format.channelCount)
        for c in 0..<outCh { memset(out.floatChannelData![c], 0, Int(n) * MemoryLayout<Float>.size) }

        var mic: [Float]?
        var system: [Float]?
        var micStereo: [[Float]] = []
        for (file, role) in files {
            let chans = read(file, frames: n)
            switch role {
            case .microphone:
                mic = mono(chans, n)
                micStereo = chans
            case .system:
                system = mono(chans, n)
                add(chans, to: out, n)
            case .mixed:
                add(chans, to: out, n)
            }
        }
        if let mic {
            // The reference is the system track `referenceDelay` frames
            // earlier, so the echo falls inside the filter's window.
            let reference = referenceFile.map { mono(read($0, frames: n, at: position - referenceDelay), n) } ?? system
            if let echo, let reference {
                // While the filter is off it keeps learning, so switching
                // it on is instant.
                let cleaned = echo.process(mic: mic, reference: reference, produceOutput: echoFilter)
                add(echoFilter ? [cleaned] : micStereo, to: out, n)
            } else {
                add(micStereo, to: out, n)
            }
        }
        position += AVAudioFramePosition(n)
        queued += 1
        onBlock?(out, position >= length, generation)
    }

    /// `n` frames of `file` from `at` (default: the playback position).
    /// Frames before 0 or past the end read as silence.
    private func read(_ file: AVAudioFile, frames n: AVAudioFrameCount, at: AVAudioFramePosition? = nil) -> [[Float]] {
        let chans = Int(file.processingFormat.channelCount)
        let from = at ?? position
        let lead = Int(max(0, min(AVAudioFramePosition(n), -from)))   // frames before 0
        let readFrom = max(0, from)
        let want = AVAudioFrameCount(Int(n) - lead)
        guard want > 0, readFrom < file.length,
              let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: want)
        else { return Array(repeating: [Float](repeating: 0, count: Int(n)), count: chans) }
        file.framePosition = readFrom
        try? file.read(into: buf, frameCount: want)
        let got = Int(buf.frameLength)
        return (0..<chans).map { c in
            var a = [Float](repeating: 0, count: lead)
            a += UnsafeBufferPointer(start: buf.floatChannelData![c], count: got)
            if a.count < Int(n) { a += [Float](repeating: 0, count: Int(n) - a.count) }
            return a
        }
    }

    private func mono(_ chans: [[Float]], _ n: AVAudioFrameCount) -> [Float] {
        guard chans.count > 1 else { return chans.first ?? [Float](repeating: 0, count: Int(n)) }
        var m = [Float](repeating: 0, count: Int(n))
        for c in chans { for i in 0..<Int(n) { m[i] += c[i] } }
        let k = 1 / Float(chans.count)
        for i in 0..<Int(n) { m[i] *= k }
        return m
    }

    /// Add `chans` into `out`; a mono source goes to every output channel.
    private func add(_ chans: [[Float]], to out: AVAudioPCMBuffer, _ n: AVAudioFrameCount) {
        let outCh = Int(out.format.channelCount)
        for c in 0..<outCh {
            let src = chans.isEmpty ? nil : chans[min(c, chans.count - 1)]
            guard let src else { continue }
            let dst = out.floatChannelData![c]
            for i in 0..<Int(n) { dst[i] += src[i] }
        }
    }
}
