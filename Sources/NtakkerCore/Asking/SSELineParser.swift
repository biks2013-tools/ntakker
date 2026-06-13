// NtakkerCore/Asking/SSELineParser.swift — plan-015 Phase 4.
// Tiny streaming helper that splits a `URLSession.AsyncBytes` byte
// stream into newline-delimited `String` lines. Every concrete
// `AskClient` parses SSE payloads (`data: …`) so this helper is shared.

import Foundation

/// Asynchronous line iterator over an arbitrary `URLSession.AsyncBytes`.
/// Handles `\n` and `\r\n` terminators uniformly. Yields the line text
/// WITHOUT the trailing newline.
struct AsyncLineIterator {
    let bytes: URLSession.AsyncBytes

    /// Returns an `AsyncThrowingStream<String, Error>` that yields each
    /// line in order. The stream terminates when the underlying byte
    /// stream is exhausted.
    func lines() -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var buffer: [UInt8] = []
                buffer.reserveCapacity(1024)
                do {
                    for try await byte in bytes {
                        if byte == 0x0A /* \n */ {
                            // Drop trailing \r if CRLF.
                            if buffer.last == 0x0D /* \r */ {
                                buffer.removeLast()
                            }
                            let line = String(decoding: buffer, as: UTF8.self)
                            buffer.removeAll(keepingCapacity: true)
                            continuation.yield(line)
                        } else {
                            buffer.append(byte)
                        }
                    }
                    if !buffer.isEmpty {
                        let line = String(decoding: buffer, as: UTF8.self)
                        continuation.yield(line)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}
