# ntakker Capture / Recording Pipeline — Performance / Functionality / Robustness Review

Scope: `Sources/NtakkerCore/Capture/`, `Mixing/`, `Encoding/`, `Aligning/`, `Devices/`, and `Sources/NtakkerCore/RecordingSession.swift`.
Date: 2026-06-12.
Note: this report is a condensed capture of the reviewing agent's findings; line numbers refer to the state at commit `e4cd174`.

## HIGH severity

### C1. HostClockAligner: excessive per-buffer allocations on the hot audio path
- **File:** `Sources/NtakkerCore/Aligning/HostClockAligner.swift` (~lines 353, 425, 719, 749)
- Rebuilds entire sample buffers on every ingest (~660–1,320 KB/sec of transient allocations) and allocates fresh array slices for every frame emission.
- **Fix:** replace with pre-allocated ring buffers sized for 1–2 seconds of audio; emit frames as views/copies out of the ring instead of reslicing.

### C2. SoftwareAECProcessor: per-buffer allocations even in passthrough
- **File:** `Sources/NtakkerCore/Capture/SoftwareAECProcessor.swift` (~lines 464–467)
- Allocates a fresh 2-D `cleaned` array for every mic buffer (~400 KB/sec), including when AEC is effectively a passthrough.
- **Fix:** pre-allocate scratch buffers once and reuse across calls.

### C3. BufferSummer: triple CMSampleBuffer copies per frame in `.mixed` layout
- **File:** `Sources/NtakkerCore/Mixing/BufferSummer.swift` (~lines 178–181)
- Allocates `srcA`, `srcB`, and `out` arrays per frame (~2.3 MB/sec total).
- **Fix:** scratch buffer pool, or operate on the CMBlockBuffer memory directly.

### C4. RecordingSession: `[weak dispatcher]` in the live tap can drop the final frames
- **File:** `Sources/NtakkerCore/RecordingSession.swift` (~lines 1294–1324)
- If the dispatcher is released before `aligner.flush()` completes, the tail (~100–200 ms) of audio never reaches transcription — the last words vanish from the transcript.
- **Fix:** strong capture (the session orchestrator already guarantees the dispatcher's lifetime).

## MEDIUM severity

### C5. Clock-drift metric computed incorrectly
- **File:** `Sources/NtakkerCore/RecordingSession.swift` (~lines 594–603). The drift value reported in health diagnostics does not reflect actual mic↔system skew.

### C6. M4ARecorder: unbounded pending-buffer queue
- **File:** `Sources/NtakkerCore/Encoding/M4ARecorder.swift` (~lines 707–722). If the AAC encoder stalls, pending buffers accumulate without bound or backpressure.

### C7. `split()` does not roll back on finalize failure
- **File:** `Sources/NtakkerCore/RecordingSession.swift` (~lines 818–828). A failed segment finalize during split can leave the session in an inconsistent segment state.

### C8. AEC deinterleave loop is scalar (no SIMD)
- **File:** `Sources/NtakkerCore/Capture/SoftwareAECProcessor.swift` (~lines 790–794). Use vDSP strided copy.

### C9. AVMicrophoneSource: timer resource not released in deinit
- **File:** `Sources/NtakkerCore/Capture/AVMicrophoneSource.swift`. Add a `deinit` that invalidates the watchdog/level timer.

## Strengths
- PTS anchoring between the two capture stacks is correct.
- AEC v5 multi-layer gating (activity gate, double-talk detector, divergence reset, soft-knee limiter, PTS-aligned reference ring) is excellent.
- Error funneling into `NtakkerError` is clean and consistent.
- AAC priming/trim handling is deferred properly to the encoder.
- Host-clock enforcement and health diagnostics are well designed.
