import Foundation

/// Single source of truth for converting a provider-opaque speaker
/// id (e.g. Soniox's `"spk:1"`) into the short uppercase label that
/// every sidecar format and the live UI chip render. Plan-012 Phase A6.
///
/// Mapping:
///  * Soniox-style `"spk:N"` → `"SN"` (the canonical case for v1).
///  * `nil` or empty → `nil` (caller renders nothing).
///  * Any other non-empty string → uppercased verbatim. This covers
///    future providers that emit named speakers (`"alice"` → `"ALICE"`)
///    or malformed Soniox values without losing information.
public enum SpeakerSidecarLabel {

    public static func label(for raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        if raw.hasPrefix("spk:") {
            let suffix = raw.dropFirst("spk:".count)
            if !suffix.isEmpty { return "S" + suffix }
        }
        return raw.uppercased()
    }
}
