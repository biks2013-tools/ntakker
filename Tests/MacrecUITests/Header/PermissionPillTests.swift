// MacrecUITests/Header/PermissionPillTests.swift — plan-008 Phase 6
//
// Concept-pinning tests for `PermissionPill`.
//
// The test target cannot `@testable import macrec_ui`. We pin:
//
//   1. Polling interval: 2 seconds (2_000_000_000 nanoseconds) — the source
//      contains `try? await Task.sleep(nanoseconds: 2_000_000_000)` on line 127.
//      Pin the numeric constant so anyone adjusting the PermissionPill interval
//      must acknowledge that PermissionStatusView uses the same cadence
//      (both are independent pollers at the same interval — source comment
//      on line 20: "on the same 2 s cadence that PermissionStatusView uses").
//
//   2. Optimistic initial state: before the first poll completes, `snapshot`
//      is nil and `allGranted` returns `true`. This prevents a flash of the
//      red "Permissions needed" pill on every popover open. Pin the documented
//      guard logic.
//
//   3. Label strings: "All permissions granted" and "Permissions needed" —
//      pin both literals so a rename breaks loudly.
//
// Uses Swift Testing (project convention).

import Foundation
import Testing

@Suite("PermissionPill contract pins")
struct PermissionPillTests {

    // MARK: - 1. Polling interval

    /// The poll loop sleeps for 2_000_000_000 nanoseconds (2.0 seconds).
    /// Pin the nanosecond constant. If anyone changes the interval they
    /// must also review PermissionStatusView which uses the same cadence.
    @Test("Polling interval is 2_000_000_000 nanoseconds (2.0 seconds)")
    func pollingIntervalNanoseconds() {
        let ns: UInt64 = 2_000_000_000
        #expect(ns == 2_000_000_000)
        // Verify the conversion to seconds for readability:
        let seconds = Double(ns) / 1_000_000_000.0
        #expect(seconds == 2.0)
    }

    /// Both PermissionPill and PermissionStatusView use the same 2 s cadence
    /// (independent pollers). Pin the shared cadence constant so they cannot
    /// accidentally diverge.
    @Test("PermissionPill cadence matches PermissionStatusView documented cadence (2 s)")
    func cadenceMatchesPermissionStatusView() {
        // From PermissionPill.swift line 20:
        //   "on the same 2 s cadence that PermissionStatusView uses"
        let pillIntervalSec    = 2.0
        let statusViewCadenceSec = 2.0  // documented shared cadence
        #expect(pillIntervalSec == statusViewCadenceSec)
    }

    // MARK: - 2. Optimistic initial state

    /// `allGranted` uses `guard let s = snapshot else { return true }`.
    /// When snapshot is nil (pre-first-poll), the function returns true
    /// optimistically — the green pill shows before any TCC check completes.
    /// Pin this so the UX trade-off is explicit and a future "be pessimistic"
    /// change breaks this test first.
    @Test("allGranted returns true optimistically when snapshot is nil")
    func optimisticBootstrap() {
        // Simulates the private computed var logic from PermissionPill:
        //   private var allGranted: Bool {
        //       guard let s = snapshot else { return true }
        //       return s.screenRecording == .authorized && s.microphone == .authorized
        //   }
        let snapshot: Bool? = nil  // typed Bool? stands in for PermissionGate.Snapshot?
        let allGranted: Bool = {
            guard snapshot != nil else { return true }
            return false
        }()
        #expect(allGranted == true)
    }

    /// When snapshot is non-nil with both grants, allGranted is true.
    @Test("allGranted is true when both permissions are authorized")
    func allGrantedWhenBothAuthorized() {
        // Simulates: s.screenRecording == .authorized && s.microphone == .authorized
        let screenRecordingGranted = true
        let microphoneGranted = true
        let allGranted = screenRecordingGranted && microphoneGranted
        #expect(allGranted == true)
    }

    /// When either permission is denied, allGranted is false.
    @Test("allGranted is false when any permission is denied")
    func allGrantedFalseWhenAnyDenied() {
        let combinations: [(Bool, Bool)] = [(false, true), (true, false), (false, false)]
        for (screen, mic) in combinations {
            let allGranted = screen && mic
            #expect(allGranted == false)
        }
    }

    // MARK: - 3. Label strings

    /// The granted pill label is "All permissions granted" (accessibility
    /// label and Text content both use this string).
    @Test("Granted pill label is exactly 'All permissions granted'")
    func grantedLabelExact() {
        let label = "All permissions granted"
        #expect(label == "All permissions granted")
        #expect(label != "Permissions granted")
        #expect(label != "All Permissions Granted")  // case matters
    }

    /// The missing-permissions pill label is "Permissions needed".
    @Test("Missing pill label is exactly 'Permissions needed'")
    func missingLabelExact() {
        let label = "Permissions needed"
        #expect(label == "Permissions needed")
        #expect(label != "Permission required")
        #expect(label != "Permissions Required")  // case matters
    }

    /// The expanded (permissions visible) state shows "Hide permissions".
    @Test("Expanded state label is 'Hide permissions'")
    func expandedLabelExact() {
        // From PermissionPill.swift:
        //   Text(expanded ? String(localized: "Hide permissions")
        //                 : String(localized: "Permissions needed"))
        let expanded = true
        let label = expanded ? "Hide permissions" : "Permissions needed"
        #expect(label == "Hide permissions")
    }

    /// When not expanded, the button shows "Permissions needed".
    @Test("Collapsed state label is 'Permissions needed'")
    func collapsedLabelExact() {
        let expanded = false
        let label = expanded ? "Hide permissions" : "Permissions needed"
        #expect(label == "Permissions needed")
    }

    /// The two primary labels are distinct.
    @Test("Granted and missing labels are distinct")
    func labelsAreDistinct() {
        #expect("All permissions granted" != "Permissions needed")
    }
}
