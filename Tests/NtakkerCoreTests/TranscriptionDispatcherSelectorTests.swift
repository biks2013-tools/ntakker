import Testing
import Foundation
@testable import NtakkerCore

@Suite("TranscriptionDispatcherSelector.chooseKind (Phase C4)")
struct TranscriptionDispatcherSelectorTests {

    private func opts(
        provider: String? = "apple",
        source: TranscriptionSource = .mixed
    ) -> RecordingOptions {
        RecordingOptions(
            output: URL(fileURLWithPath: "/tmp/r.m4a"),
            transcriptionProviderId: provider,
            transcriptionSource: source
        )
    }

    @Test("nil / empty / 'none' / 'noop' provider id → .none")
    func disabledProviders() {
        #expect(TranscriptionDispatcherSelector.chooseKind(for: opts(provider: nil)) == .none)
        #expect(TranscriptionDispatcherSelector.chooseKind(for: opts(provider: "")) == .none)
        #expect(TranscriptionDispatcherSelector.chooseKind(for: opts(provider: "none")) == .none)
        #expect(TranscriptionDispatcherSelector.chooseKind(for: opts(provider: "noop")) == .none)
    }

    @Test("provider set + source != .both → .single")
    func single() {
        #expect(TranscriptionDispatcherSelector.chooseKind(for: opts(provider: "apple", source: .mixed)) == .single)
        #expect(TranscriptionDispatcherSelector.chooseKind(for: opts(provider: "soniox", source: .system)) == .single)
        #expect(TranscriptionDispatcherSelector.chooseKind(for: opts(provider: "parakeet", source: .mic)) == .single)
    }

    @Test("provider set + source == .both → .sourceSplit")
    func sourceSplit() {
        #expect(TranscriptionDispatcherSelector.chooseKind(for: opts(provider: "apple", source: .both)) == .sourceSplit)
        #expect(TranscriptionDispatcherSelector.chooseKind(for: opts(provider: "elevenlabs", source: .both)) == .sourceSplit)
    }

    @Test("provider id is case-insensitive for 'NONE' / 'NoOp'")
    func caseInsensitiveProviders() {
        #expect(TranscriptionDispatcherSelector.chooseKind(for: opts(provider: "NONE")) == .none)
        #expect(TranscriptionDispatcherSelector.chooseKind(for: opts(provider: "NoOp")) == .none)
    }
}
