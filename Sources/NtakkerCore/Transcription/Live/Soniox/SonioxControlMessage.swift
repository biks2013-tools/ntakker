// Sources/NtakkerCore/Transcription/Live/Soniox/SonioxControlMessage.swift
//
// Plan-006 Phase A / Unit A: Soniox WebSocket control messages.
//
// Two control messages are sent as JSON TEXT frames mid-session:
//   * `{"type":"keepalive"}` — fire-and-forget; sent every 10 s of
//     audio silence so the 20 s no-audio timeout never fires.
//   * `{"type":"finalize"}`  — flushes pending non-final tokens; the
//     server emits a batch ending with the `<fin>` marker token.
//
// Per soniox-wire-schema.md §2.3 the control envelope contains ONLY a
// `type` field — Soniox does NOT accept extra fields here. The
// encoder below therefore writes a single key, satisfying that
// invariant.
//
// Naming convention deviation note: SX-3 prescribes snake_case Swift
// names with no `CodingKeys`. The Phase A task brief overrode this
// with "snake_case JSON ↔ camelCase Swift via `CodingKeys`". The
// `type` field is a single token, identical in both cases.

import Foundation

public enum SonioxControlMessage: Codable, Sendable, Equatable {

    case keepalive
    case finalize

    private enum CodingKeys: String, CodingKey {
        case type
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .keepalive:
            try container.encode("keepalive", forKey: .type)
        case .finalize:
            try container.encode("finalize", forKey: .type)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try container.decode(String.self, forKey: .type)
        switch raw {
        case "keepalive":
            self = .keepalive
        case "finalize":
            self = .finalize
        default:
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription:
                        "Unknown SonioxControlMessage type: \"\(raw)\""
                )
            )
        }
    }
}
