// Sources/NtakkerCore/Transcription/Live/Soniox/SonioxKeepaliveTimer.swift
//
// Plan-006 Phase D / Unit D1: periodic keepalive sender.
//
// Soniox closes any session idle for >20 s of audio (HTTP 408). To
// keep sessions alive during long pauses (the "intermission" gap a
// user takes between thoughts) we send `{"type":"keepalive"}` every
// `interval` seconds. The transport handles serialisation; this
// actor only owns the cadence and lifetime of the sending task.

import Foundation

/// Sends `{"type":"keepalive"}` every `interval` to a transport.
/// Stops cleanly on `stop()` or task cancellation.
public actor SonioxKeepaliveTimer {

    private let interval: Duration
    private var task: Task<Void, Never>?

    public init(interval: Duration = .seconds(10)) {
        self.interval = interval
    }

    /// Start the keepalive loop. If a previous loop is still running,
    /// it is cancelled first so there is at most one sender at a time.
    public func start(
        transport: any WebSocketTransport,
        encoder: JSONEncoder = JSONEncoder()
    ) async {
        task?.cancel()
        let interval = self.interval
        task = Task {
            // Pre-encode the keepalive frame once — it never changes
            // during the lifetime of the loop.
            let payload: String
            if let data = try? encoder.encode(SonioxControlMessage.keepalive),
               let text = String(data: data, encoding: .utf8) {
                payload = text
            } else {
                payload = "{\"type\":\"keepalive\"}"
            }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return  // cancelled mid-sleep
                }
                if Task.isCancelled { return }
                try? await transport.send(text: payload)
            }
        }
    }

    /// Cancel the running keepalive task. Safe to call multiple times.
    public func stop() async {
        task?.cancel()
        task = nil
    }
}
