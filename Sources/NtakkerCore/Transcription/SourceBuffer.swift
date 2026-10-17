import Accelerate
import Foundation

/// How a `SourceBuffer` decides when its audio is ready to send.
///
/// EVAL-2026-10-16 TR-2 (plan-022 T6): cloud batch APIs bill and answer
/// per request, so short chunks keep the transcript close to live. The
/// on-device models are the opposite: Parakeet pads every call to a
/// 15 s encoder window and Whisper to 30 s, so a 2.5 s chunk wasted
/// 6–12× the encoder work, and a fixed cut split words at chunk edges.
public enum ChunkPolicy: Sendable, Equatable {
    /// Send everything accumulated (at least `minSamples`) on each
    /// process-loop tick. The cloud batch providers use this.
    case drainAll

    /// Wait for `targetSeconds` of audio, then cut at the first quiet
    /// 50 ms frame between `targetSeconds` and `maxSeconds`; with no
    /// quiet frame, cut at the quietest one once `maxSeconds` is
    /// buffered. The audio after the cut stays for the next chunk.
    case silenceCut(targetSeconds: Double, maxSeconds: Double)

    /// The policy the on-device batch models use: 10–14 s fits one
    /// Parakeet window and keeps the live transcript within ~15 s.
    public static let onDevice = ChunkPolicy.silenceCut(targetSeconds: 10, maxSeconds: 14)
}

public actor SourceBuffer {

    public let source: SourceTag
    public let chunkSamples: Int
    public let minSamples: Int
    public let policy: ChunkPolicy

    /// RMS below which a 50 ms frame counts as a pause to cut at
    /// (about −46 dBFS).
    public static let quietFrameRMS: Float = 0.005

    private let sampleRate: Int
    private var accumulator: [Float] = []
    public private(set) var bufferOverflowCount: Int = 0

    public init(
        source: SourceTag,
        chunkSeconds: Double = 2.5,
        sampleRate: Int = 16_000,
        minSamples: Int = 6_400,
        policy: ChunkPolicy = .drainAll
    ) {
        self.source = source
        self.chunkSamples = Int(chunkSeconds * Double(sampleRate))
        self.minSamples = minSamples
        self.policy = policy
        self.sampleRate = sampleRate
    }

    /// Samples kept before the oldest half is dropped.
    private var capSamples: Int {
        switch policy {
        case .drainAll:
            return 2 * chunkSamples
        case .silenceCut(_, let maxSeconds):
            return 2 * Int(maxSeconds * Double(sampleRate))
        }
    }

    public func append(_ samples: [Float]) {
        accumulator.append(contentsOf: samples)
        if accumulator.count > capSamples {
            bufferOverflowCount += 1
            let drop = accumulator.count / 2
            accumulator.removeFirst(drop)
        }
    }

    public func drain(final: Bool) -> [Float]? {
        if accumulator.isEmpty { return nil }
        if final { return takeAll() }
        switch policy {
        case .drainAll:
            if accumulator.count < minSamples { return nil }
            return takeAll()
        case .silenceCut(let targetSeconds, let maxSeconds):
            let target = Int(targetSeconds * Double(sampleRate))
            let maxSamples = Int(maxSeconds * Double(sampleRate))
            guard accumulator.count >= target else { return nil }
            guard let cut = cutPoint(from: target, to: min(accumulator.count, maxSamples),
                                     forced: accumulator.count >= maxSamples)
            else { return nil }
            let out = Array(accumulator[..<cut])
            accumulator.removeFirst(cut)
            return out
        }
    }

    private func takeAll() -> [Float] {
        let out = accumulator
        accumulator.removeAll(keepingCapacity: true)
        return out
    }

    /// Middle of the first quiet 50 ms frame in `lower..<upper`, or —
    /// when `forced` — of the quietest frame there. `nil` when there is
    /// no quiet frame and the cut is not forced yet.
    private func cutPoint(from lower: Int, to upper: Int, forced: Bool) -> Int? {
        let frame = sampleRate / 20
        var quietest: (rms: Float, start: Int)?
        accumulator.withUnsafeBufferPointer { buf in
            var start = lower
            while start + frame <= upper {
                var rms: Float = 0
                vDSP_rmsqv(buf.baseAddress! + start, 1, &rms, vDSP_Length(frame))
                if rms < Self.quietFrameRMS {
                    quietest = (rms, start)
                    return
                }
                // `<=`: on ties prefer the later frame, so the chunk runs long.
                if quietest == nil || rms <= quietest!.rms { quietest = (rms, start) }
                start += frame
            }
        }
        guard let quietest else { return forced ? upper : nil }
        if quietest.rms < Self.quietFrameRMS || forced {
            return quietest.start + frame / 2
        }
        return nil
    }
}
