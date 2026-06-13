// Sources/NtakkerCore/Transcription/Net/MultipartFormDataBuilder.swift —
// plan-007 Phase 0 / Task 0.5.
//
// Foundation-only multipart/form-data body builder shared between the
// Azure OpenAI batch provider (Phase A1) and the ElevenLabs provider
// (Phase B). Vendor SDKs would buy nothing here — both endpoints accept
// a vanilla multipart POST returning JSON, and `URLSession` already
// streams the body cleanly.
//
// Design (plan-007 §3.2): a value type rather than an actor or a
// superclass. The few interesting differences between providers
// (URL template, auth header, field set, response decode, error
// envelope) all live in each provider's own type; this helper only
// owns the body bytes.

import Foundation

/// Accumulates `multipart/form-data` parts and emits the final
/// `(contentType, body)` tuple. Used by `AzureOpenAITranscriptionProvider`
/// and `ElevenLabsTranscriptionProvider`.
///
/// Usage:
/// ```swift
/// var multipart = MultipartFormDataBuilder()
/// multipart.append(field: "model", value: "scribe_v2")
/// multipart.append(
///     field: "file",
///     fileNamed: "audio.wav",
///     mimeType: "audio/wav",
///     data: wavData
/// )
/// let (contentType, body) = multipart.build()
/// request.setValue(contentType, forHTTPHeaderField: "Content-Type")
/// request.httpBody = body
/// ```
public struct MultipartFormDataBuilder: Sendable {

    /// The boundary marker used to delimit parts. Defaults to a
    /// UUID-suffixed value so distinct request bodies never collide
    /// (the constant prefix `NtakkerBoundary-` is intentional — it
    /// makes mock-URLProtocol assertions easier to grep for).
    public let boundary: String

    /// Accumulated body bytes. Mutated by `append(...)`; finalised
    /// (with the closing boundary line) by `build()`.
    private var body: Data = Data()

    public init(boundary: String = "NtakkerBoundary-\(UUID().uuidString)") {
        self.boundary = boundary
    }

    // MARK: - Appending parts

    /// Append a text field. Escapes nothing — callers MUST pass values
    /// that are valid in a `multipart/form-data` text part (the
    /// underlying RFC 7578 only forbids embedded `\r\n--{boundary}`,
    /// which would never appear in a sane field value).
    public mutating func append(field name: String, value: String) {
        body.append(boundaryDelimiter())
        body.append(headerLine(
            "Content-Disposition: form-data; name=\"\(name)\""
        ))
        body.append(crlf)
        body.append(value.data(using: .utf8) ?? Data())
        body.append(crlf)
    }

    /// Append a file field carrying binary data with an explicit MIME
    /// type and a server-visible filename (only used for diagnostics on
    /// the vendor side).
    public mutating func append(
        field name: String,
        fileNamed filename: String,
        mimeType: String,
        data: Data
    ) {
        body.append(boundaryDelimiter())
        body.append(headerLine(
            "Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\""
        ))
        body.append(headerLine("Content-Type: \(mimeType)"))
        body.append(crlf)
        body.append(data)
        body.append(crlf)
    }

    // MARK: - Finalising

    /// Returns the final `Content-Type` header value (including the
    /// boundary) and the request body. Calling `build()` does not
    /// invalidate the builder — repeated calls produce the same bytes
    /// (idempotent).
    public func build() -> (contentType: String, body: Data) {
        var finished = body
        finished.append(closingBoundary())
        return (
            "multipart/form-data; boundary=\(boundary)",
            finished
        )
    }

    // MARK: - Internals

    private var crlf: Data {
        Data("\r\n".utf8)
    }

    private func boundaryDelimiter() -> Data {
        Data("--\(boundary)\r\n".utf8)
    }

    private func closingBoundary() -> Data {
        Data("--\(boundary)--\r\n".utf8)
    }

    private func headerLine(_ value: String) -> Data {
        Data("\(value)\r\n".utf8)
    }
}
