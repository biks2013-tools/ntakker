// test_scripts/probe-soniox-ws.swift
//
// Standalone WebSocket probe for Soniox. Uses URLSessionWebSocketTask
// directly (same primitive our production transport uses) to send the
// same JSON config our SonioxConfigBuilder produces, and prints back
// every server frame verbatim.
//
// Purpose: isolate whether a 401 from Soniox is caused by:
//   (a) the API key itself                — already ruled out by REST 200
//   (b) the JSON config body shape         — what this probe verifies
//   (c) something in our Swift transport   — comparison: this probe IS
//                                             the transport, simplified
//
// Run:    swift test_scripts/probe-soniox-ws.swift
// Reads:  $SONIOX_API_KEY, or ~/.tool-agents/macrec-ui/.env

import Foundation

// MARK: - Resolve API key

func resolveApiKey() -> String? {
    if let env = ProcessInfo.processInfo.environment["SONIOX_API_KEY"], !env.isEmpty {
        return env
    }
    let home = FileManager.default.homeDirectoryForCurrentUser
    let envFile = home.appendingPathComponent(".tool-agents/macrec-ui/.env")
    guard let contents = try? String(contentsOf: envFile, encoding: .utf8) else { return nil }
    for line in contents.split(separator: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("SONIOX_API_KEY=") {
            var value = String(trimmed.dropFirst("SONIOX_API_KEY=".count))
            if value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            return value
        }
    }
    return nil
}

guard let apiKey = resolveApiKey(), !apiKey.isEmpty else {
    FileHandle.standardError.write(Data("ERROR: SONIOX_API_KEY not found\n".utf8))
    exit(1)
}

print("Key: \(apiKey.prefix(6))...\(apiKey.suffix(4)) (\(apiKey.count) chars)")

// MARK: - Build the EXACT same config our production code builds

struct ProbeConfig: Encodable {
    let api_key: String
    let model: String
    let audio_format: String
    let sample_rate: Int
    let num_channels: Int
    let language_hints: [String]
    let language_hints_strict: Bool
    let enable_language_identification: Bool
    let enable_endpoint_detection: Bool
    let max_endpoint_delay_ms: Int
    let enable_speaker_diarization: Bool
    let client_reference_id: String
}

let config = ProbeConfig(
    api_key: apiKey,
    model: "stt-rt-v4",
    audio_format: "pcm_s16le",
    sample_rate: 16000,
    num_channels: 1,
    language_hints: ["el", "en"],
    language_hints_strict: false,
    enable_language_identification: true,
    enable_endpoint_detection: true,
    max_endpoint_delay_ms: 2000,
    enable_speaker_diarization: false,
    client_reference_id: "macrec-probe-soniox-ws"
)

let encoder = JSONEncoder()
encoder.outputFormatting = []
let configData = try encoder.encode(config)
let configJSON = String(decoding: configData, as: UTF8.self)

// Print the JSON with the api_key redacted so the user can copy/paste it
let redacted = configJSON
    .replacingOccurrences(of: "\"api_key\":\"\(apiKey)\"", with: "\"api_key\":\"<REDACTED>\"")
print("\nSending config (key redacted):\n\(redacted)\n")

// MARK: - Connect

let endpoint = URL(string: "wss://stt-rt.soniox.com/transcribe-websocket")!
print("Connecting to \(endpoint)...")

let session = URLSession(configuration: .ephemeral)
let task = session.webSocketTask(with: endpoint)
task.resume()

// MARK: - Send config and receive

let group = DispatchGroup()
group.enter()

Task {
    defer { group.leave() }

    do {
        try await task.send(.string(configJSON))
        print("Config sent OK")
    } catch {
        print("send(config) FAILED: \(error.localizedDescription)")
        return
    }

    // Read up to 5 messages or 8 seconds, whichever comes first.
    let deadline = Date().addingTimeInterval(8.0)
    var messageCount = 0
    while Date() < deadline, messageCount < 5 {
        do {
            let msg = try await task.receive()
            messageCount += 1
            switch msg {
            case .string(let s):
                print("← TEXT  : \(s)")
            case .data(let d):
                print("← BINARY: \(d.count) bytes")
            @unknown default:
                print("← UNKNOWN frame")
            }
        } catch {
            print("← receive ERROR: \(error.localizedDescription)")
            break
        }
    }

    task.cancel(with: .normalClosure, reason: "probe done".data(using: .utf8))
    print("Done.")
}

group.wait()
session.invalidateAndCancel()
