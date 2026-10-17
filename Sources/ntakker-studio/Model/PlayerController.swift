// ntakker-studio/Model/PlayerController.swift — plan-024 T9.
//
// Plays a recording. All its tracks (mixed, or mic + system) go into one
// AVMutableComposition so a split recording plays both sides together.
// `currentTime` is published 20 times a second for the transcript
// follow and the waveform playhead. With `skipRanges` set (cut
// preview), playback jumps over them.

import AVFoundation
import Foundation
import Observation

@MainActor @Observable
final class PlayerController {
    private(set) var duration: Double = 0
    private(set) var currentTime: Double = 0
    private(set) var isPlaying = false
    private(set) var loadError: String?
    var rate: Float = 1 {
        didSet { if isPlaying { player.rate = rate } }
    }
    /// Ranges playback skips (the cut preview). Sorted.
    var skipRanges: [ClosedRange<Double>] = []

    @ObservationIgnored private let player = AVPlayer()
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?

    static let availableRates: [Float] = [0.75, 1, 1.25, 1.5, 1.75, 2]

    init() {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 20), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time.seconds) }
        }
    }

    func teardown() {
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        player.replaceCurrentItem(with: nil)
    }

    func load(tracks: [URL]) async {
        let composition = AVMutableComposition()
        var longest = CMTime.zero
        do {
            for url in tracks {
                let asset = AVURLAsset(url: url)
                let duration = try await asset.load(.duration)
                for source in try await asset.loadTracks(withMediaType: .audio) {
                    let range = try await source.load(.timeRange)
                    let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                    try track?.insertTimeRange(range, of: source, at: .zero)
                }
                longest = max(longest, duration)
            }
        } catch {
            loadError = error.localizedDescription
            return
        }
        let item = AVPlayerItem(asset: composition)
        // Keep pitch at faster rates.
        item.audioTimePitchAlgorithm = .timeDomain
        player.replaceCurrentItem(with: item)
        duration = longest.seconds.isFinite ? longest.seconds : 0
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.isPlaying = false }
        }
    }

    func togglePlay() { isPlaying ? pause() : play() }

    func play() {
        if currentTime >= duration - 0.05 { seek(to: 0) }
        player.rate = rate
        isPlaying = true
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func seek(to seconds: Double) {
        let t = min(max(0, seconds), max(0, duration))
        currentTime = t
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func skip(by seconds: Double) { seek(to: currentTime + seconds) }

    private func tick(_ seconds: Double) {
        guard seconds.isFinite else { return }
        if isPlaying, let r = skipRanges.first(where: { $0.contains(seconds) && seconds < $0.upperBound - 0.05 }) {
            seek(to: r.upperBound)
            return
        }
        currentTime = seconds
    }
}
