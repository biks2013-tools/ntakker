import Foundation
import Testing
@testable import MacrecCore

@Suite("AudioWAVEncoder")
struct AudioWAVEncoderTests {

    @Test("header is 44 bytes, body is 2 × samples (PCM16)")
    func encodeProducesExpectedLayout() {
        let samples: [Float] = Array(repeating: 0.5, count: 16_000)
        let bytes = AudioWAVEncoder.encode(samples: samples)
        #expect(bytes.count == 44 + 16_000 * 2)
        #expect(bytes[0..<4] == Data("RIFF".utf8))
        #expect(bytes[8..<12] == Data("WAVE".utf8))
        #expect(bytes[12..<16] == Data("fmt ".utf8))
        #expect(bytes[20] == 1 && bytes[21] == 0)
    }

    @Test("clamping handles values outside [-1, 1]")
    func encodeClampsOutOfRange() {
        let samples: [Float] = [2.0, -2.0, 0.0]
        let bytes = AudioWAVEncoder.encode(samples: samples)
        let body = bytes.suffix(6)
        let expected: [UInt8] = [0xFF, 0x7F, 0x01, 0x80, 0x00, 0x00]
        #expect(Array(body) == expected)
    }

    @Test("2.5 s @ 16 kHz produces 80 044 bytes")
    func encodeStandardChunkSize() {
        let samples: [Float] = Array(repeating: 0, count: 40_000)
        #expect(AudioWAVEncoder.encode(samples: samples).count == 80_044)
    }
}
