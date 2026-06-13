import Foundation

public enum AudioWAVEncoder {

    public static func encode(samples: [Float], sampleRate: Int = 16_000) -> Data {
        let bitsPerSample: UInt16 = 16
        let channels: UInt16 = 1
        let byteRate = UInt32(sampleRate) * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        let dataSize = UInt32(samples.count * 2)
        let chunkSize = 36 + dataSize

        var out = Data()
        out.reserveCapacity(44 + Int(dataSize))

        out.append(contentsOf: "RIFF".utf8)
        out.appendLE(chunkSize)
        out.append(contentsOf: "WAVE".utf8)

        out.append(contentsOf: "fmt ".utf8)
        out.appendLE(UInt32(16))
        out.appendLE(UInt16(1))
        out.appendLE(channels)
        out.appendLE(UInt32(sampleRate))
        out.appendLE(byteRate)
        out.appendLE(blockAlign)
        out.appendLE(bitsPerSample)

        out.append(contentsOf: "data".utf8)
        out.appendLE(dataSize)

        // F7 + F32 (EVAL 2026-06-12): one vDSP-vectorised conversion +
        // one bulk append — replaces the previous per-sample
        // `withUnsafeBytes` + `append` loop (~40k calls per 2.5 s
        // chunk).
        out.append(PCMConvert.floatToInt16LE(samples))

        return out
    }
}

private extension Data {
    mutating func appendLE(_ value: UInt16) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
    mutating func appendLE(_ value: UInt32) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
}
