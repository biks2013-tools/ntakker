// MacrecCore/Devices/AudioDeviceEnumerator.swift
// Reference: project-design.md §2.7
//
// Lists input audio devices via the Core Audio HAL (NOT via
// `AVCaptureDevice.devices(for:)`, per §2.7 — AVCapture only sees devices
// authorized for AV capture, while the HAL sees every input device on the
// system regardless of auth state, which is what `list-devices` needs).
//
// Deviation note (Phase D Wave 2 instructions):
// project-design.md §2.7 names the methods `listInputDevices()` and
// `resolve(_:)`. The Phase D Wave 2 instructions to this implementer name
// them `listInputs()` and `find(byNameOrUID:)`. We follow the implementer
// instructions verbatim. Phase K (CLI) consumes only the public surface
// of this file, and the rename is mechanical.
//
// HAL property addresses used:
//   - kAudioHardwarePropertyDevices                  → all device IDs
//   - kAudioDevicePropertyStreamConfiguration        → input channel count
//   - kAudioDevicePropertyDeviceNameCFString         → human-readable name
//   - kAudioDevicePropertyDeviceUID                  → stable UID
//   - kAudioDevicePropertyAvailableNominalSampleRates→ sample-rate range

import CoreAudio
import Foundation
import Logging

public enum AudioDeviceEnumerator {
    /// Lists every input-capable audio device the HAL knows about. Devices
    /// with zero input channels (output-only devices, e.g. a pair of plain
    /// stereo speakers) are skipped.
    ///
    /// The result is sorted by ascending `AudioObjectID` so output is
    /// deterministic across calls.
    public static func listInputs() throws -> [AudioInputDevice] {
        let ids = try fetchAllDeviceIDs()
        var inputs: [(id: AudioObjectID, device: AudioInputDevice)] = []
        for id in ids {
            let channelCount = try inputChannelCount(for: id)
            guard channelCount > 0 else { continue }
            let name = try deviceName(for: id)
            let uid = try deviceUID(for: id)
            let range = try availableSampleRateRange(for: id)
            let device = AudioInputDevice(
                name: name,
                uid: uid,
                sampleRateRange: range,
                channelCount: channelCount
            )
            inputs.append((id: id, device: device))
        }
        // Sort by AudioObjectID for deterministic ordering.
        inputs.sort { $0.id < $1.id }
        return inputs.map { $0.device }
    }

    /// Resolves a `--mic-device` argument. Algorithm (FR-3, OQ-8 default):
    ///   1. UID match (exact, case-sensitive). UID always wins.
    ///   2. Name match (case-insensitive). On multiple matches, log a warning
    ///      naming all matches if a logger is provided, and pick the first
    ///      device by ascending `AudioObjectID`.
    ///   3. None → return `nil` (caller decides whether that's an error).
    public static func find(
        byNameOrUID query: String,
        logger: Logger? = nil
    ) throws -> AudioInputDevice? {
        let ids = try fetchAllDeviceIDs()
        var nameMatches: [(id: AudioObjectID, device: AudioInputDevice)] = []

        for id in ids {
            let channelCount = try inputChannelCount(for: id)
            guard channelCount > 0 else { continue }
            let name = try deviceName(for: id)
            let uid = try deviceUID(for: id)

            // UID match short-circuits.
            if uid == query {
                let range = try availableSampleRateRange(for: id)
                return AudioInputDevice(
                    name: name,
                    uid: uid,
                    sampleRateRange: range,
                    channelCount: channelCount
                )
            }

            if name.caseInsensitiveCompare(query) == .orderedSame {
                let range = try availableSampleRateRange(for: id)
                let device = AudioInputDevice(
                    name: name,
                    uid: uid,
                    sampleRateRange: range,
                    channelCount: channelCount
                )
                nameMatches.append((id: id, device: device))
            }
        }

        guard !nameMatches.isEmpty else {
            return nil
        }

        if nameMatches.count > 1 {
            let allUIDs = nameMatches.map { $0.device.uid }.joined(separator: ", ")
            logger?.warning(
                "multiple input devices match name; picking lowest AudioObjectID",
                metadata: [
                    "query": .string(query),
                    "matchCount": .stringConvertible(nameMatches.count),
                    "uids": .string(allUIDs),
                ]
            )
        }

        nameMatches.sort { $0.id < $1.id }
        return nameMatches.first?.device
    }

    // MARK: - HAL helpers

    /// Returns every `AudioObjectID` advertised by `kAudioHardwarePropertyDevices`.
    private static func fetchAllDeviceIDs() throws -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        try check(
            AudioObjectGetPropertyDataSize(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &dataSize
            ),
            label: "kAudioHardwarePropertyDevices size"
        )

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return [] }

        var ids = [AudioObjectID](repeating: 0, count: count)
        try ids.withUnsafeMutableBufferPointer { buffer in
            try check(
                AudioObjectGetPropertyData(
                    AudioObjectID(kAudioObjectSystemObject),
                    &address,
                    0,
                    nil,
                    &dataSize,
                    buffer.baseAddress!
                ),
                label: "kAudioHardwarePropertyDevices data"
            )
        }
        return ids
    }

    /// Sums the input-scope channel counts from
    /// `kAudioDevicePropertyStreamConfiguration` so we can decide whether the
    /// device is input-capable. Returns 0 for output-only devices.
    private static func inputChannelCount(for deviceID: AudioObjectID) throws -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        try check(
            AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize),
            label: "kAudioDevicePropertyStreamConfiguration size"
        )
        guard dataSize > 0 else { return 0 }

        let bufferList = UnsafeMutablePointer<UInt8>.allocate(capacity: Int(dataSize))
        defer { bufferList.deallocate() }
        try check(
            AudioObjectGetPropertyData(
                deviceID,
                &address,
                0,
                nil,
                &dataSize,
                bufferList
            ),
            label: "kAudioDevicePropertyStreamConfiguration data"
        )

        let abl = UnsafeMutableAudioBufferListPointer(
            bufferList.withMemoryRebound(to: AudioBufferList.self, capacity: 1) { $0 }
        )
        var total = 0
        for buf in abl {
            total += Int(buf.mNumberChannels)
        }
        return total
    }

    /// Reads `kAudioDevicePropertyDeviceNameCFString` as a Swift `String`.
    private static func deviceName(for deviceID: AudioObjectID) throws -> String {
        try fetchCFStringProperty(
            deviceID,
            selector: kAudioDevicePropertyDeviceNameCFString,
            label: "kAudioDevicePropertyDeviceNameCFString"
        )
    }

    /// Reads `kAudioDevicePropertyDeviceUID` as a Swift `String`.
    private static func deviceUID(for deviceID: AudioObjectID) throws -> String {
        try fetchCFStringProperty(
            deviceID,
            selector: kAudioDevicePropertyDeviceUID,
            label: "kAudioDevicePropertyDeviceUID"
        )
    }

    private static func fetchCFStringProperty(
        _ deviceID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        label: String
    ) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfString: CFString = "" as CFString
        var dataSize: UInt32 = UInt32(MemoryLayout<CFString>.size)
        try withUnsafeMutablePointer(to: &cfString) { ptr in
            try check(
                AudioObjectGetPropertyData(
                    deviceID,
                    &address,
                    0,
                    nil,
                    &dataSize,
                    ptr
                ),
                label: label
            )
        }
        return cfString as String
    }

    /// Reads `kAudioDevicePropertyAvailableNominalSampleRates` and returns the
    /// (lowest, highest) pair as a `ClosedRange<Double>`. If only a single
    /// rate is reported, the range collapses to `rate...rate`.
    private static func availableSampleRateRange(
        for deviceID: AudioObjectID
    ) throws -> ClosedRange<Double> {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyAvailableNominalSampleRates,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        try check(
            AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize),
            label: "kAudioDevicePropertyAvailableNominalSampleRates size"
        )
        let count = Int(dataSize) / MemoryLayout<AudioValueRange>.size
        guard count > 0 else {
            // Fallback: query the current nominal sample rate only.
            return try currentNominalSampleRateAsRange(for: deviceID)
        }

        var ranges = [AudioValueRange](
            repeating: AudioValueRange(mMinimum: 0, mMaximum: 0),
            count: count
        )
        try ranges.withUnsafeMutableBufferPointer { buffer in
            try check(
                AudioObjectGetPropertyData(
                    deviceID,
                    &address,
                    0,
                    nil,
                    &dataSize,
                    buffer.baseAddress!
                ),
                label: "kAudioDevicePropertyAvailableNominalSampleRates data"
            )
        }

        var minRate = Double.greatestFiniteMagnitude
        var maxRate = -Double.greatestFiniteMagnitude
        for range in ranges {
            if range.mMinimum < minRate { minRate = range.mMinimum }
            if range.mMaximum > maxRate { maxRate = range.mMaximum }
        }
        if minRate == .greatestFiniteMagnitude || maxRate == -.greatestFiniteMagnitude {
            return try currentNominalSampleRateAsRange(for: deviceID)
        }
        // Guard against a malformed HAL response where min > max.
        if minRate > maxRate {
            return maxRate...minRate
        }
        return minRate...maxRate
    }

    private static func currentNominalSampleRateAsRange(
        for deviceID: AudioObjectID
    ) throws -> ClosedRange<Double> {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate: Float64 = 0
        var dataSize = UInt32(MemoryLayout<Float64>.size)
        try withUnsafeMutablePointer(to: &rate) { ptr in
            try check(
                AudioObjectGetPropertyData(
                    deviceID,
                    &address,
                    0,
                    nil,
                    &dataSize,
                    ptr
                ),
                label: "kAudioDevicePropertyNominalSampleRate data"
            )
        }
        return rate...rate
    }

    /// Wraps an `OSStatus` HAL call. Non-zero status throws a structured
    /// `MacrecError.ioError` carrying the call site label and the raw status.
    private static func check(_ status: OSStatus, label: String) throws {
        guard status == noErr else {
            throw MacrecError.ioError("CoreAudio HAL: \(label) failed (OSStatus \(status))")
        }
    }
}
