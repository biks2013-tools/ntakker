// NtakkerCore/Devices/AudioInputDevice.swift
// Reference: project-design.md §3.2 (with Phase D Wave 2 instruction overrides)
//
// Deviation note (Phase D Wave 2 instructions):
// project-design.md §3.2 specifies fields `uid`, `name`, `sampleRateHz`,
// `channelCount`, `isDefault`. The Phase D Wave 2 instructions to this
// implementer instead specify `name`, `uid`, `sampleRateRange`,
// `channelCount` and conformance to `Hashable` (a strict superset of
// `Equatable`). We follow the implementer instructions verbatim.
// Rationale: `sampleRateRange` carries strictly more information than a
// scalar `sampleRateHz` (it's the *available* nominal rates derived from
// `kAudioDevicePropertyAvailableNominalSampleRates`), and `isDefault` can
// be recomputed by the consumer via
// `kAudioHardwarePropertyDefaultInputDevice` whenever needed.

import Foundation

public struct AudioInputDevice: Sendable, Hashable {
    public let name: String
    public let uid: String
    public let sampleRateRange: ClosedRange<Double>
    public let channelCount: Int

    public init(
        name: String,
        uid: String,
        sampleRateRange: ClosedRange<Double>,
        channelCount: Int
    ) {
        self.name = name
        self.uid = uid
        self.sampleRateRange = sampleRateRange
        self.channelCount = channelCount
    }
}
