import Foundation

public actor SourceBuffer {

    public let source: SourceTag
    public let chunkSamples: Int
    public let minSamples: Int

    private var accumulator: [Float] = []
    public private(set) var bufferOverflowCount: Int = 0

    public init(
        source: SourceTag,
        chunkSeconds: Double = 2.5,
        sampleRate: Int = 16_000,
        minSamples: Int = 6_400
    ) {
        self.source = source
        self.chunkSamples = Int(chunkSeconds * Double(sampleRate))
        self.minSamples = minSamples
    }

    public func append(_ samples: [Float]) {
        accumulator.append(contentsOf: samples)
        let cap = 2 * chunkSamples
        if accumulator.count > cap {
            bufferOverflowCount += 1
            let drop = accumulator.count / 2
            accumulator.removeFirst(drop)
        }
    }

    public func drain(final: Bool) -> [Float]? {
        if accumulator.isEmpty { return nil }
        if !final && accumulator.count < minSamples { return nil }
        let out = accumulator
        accumulator.removeAll(keepingCapacity: true)
        return out
    }
}
