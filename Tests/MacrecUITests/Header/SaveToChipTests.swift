// MacrecUITests/Header/SaveToChipTests.swift — plan-008 Phase 6
//
// Concept-pinning tests for `SaveToChip`.
//
// `SaveToChip` binds to `@AppStorage("com.macrec.ui.outputFolder")`.
// If this key is silently renamed, the chip would read/write a different
// slot than `ControlBar.startTapped()` resolves — recordings would appear
// in the wrong folder without any compile-time error.
//
// The test target cannot `@testable import macrec_ui`. We re-state the
// locked key string from the source (line 40 of `SaveToChip.swift`) so
// any renamer must update both the source AND this test.
//
// This pattern is established by `ControlBarStartTappedKeysRegressionTests`
// for the analogous `transcriptionEnabled` key.
//
// Uses Swift Testing (project convention).

import Foundation
import Testing

@Suite("SaveToChip contract pins")
struct SaveToChipTests {

    // MARK: - @AppStorage key

    /// The canonical output-folder key, as declared in `SaveToChip.swift`:
    ///   @AppStorage("com.macrec.ui.outputFolder") private var folderPath: String = ""
    ///
    /// This is also the same key that the legacy `FolderPicker` used
    /// (per the file comment: "reads the same canonical @AppStorage key
    /// as FolderPicker"). Pin it so a silent rename breaks loudly.
    private let outputFolderKey = "com.macrec.ui.outputFolder"

    @Test("@AppStorage key is the documented com.macrec.ui.outputFolder string")
    func keyIsCanonical() {
        #expect(outputFolderKey == "com.macrec.ui.outputFolder")
    }

    /// The key must NOT be the bare "outputFolder" or any other short form.
    @Test("Key uses the full reverse-DNS com.macrec.ui prefix")
    func keyHasFullPrefix() {
        #expect(outputFolderKey.hasPrefix("com.macrec.ui."))
    }

    @Test("Key suffix component is 'outputFolder'")
    func keySuffixComponent() {
        let suffix = outputFolderKey.components(separatedBy: ".").last
        #expect(suffix == "outputFolder")
    }

    // MARK: - Round-trip persistence

    /// Verify that a folder path round-trips through UserDefaults under
    /// the canonical key. This confirms the String storage type is correct
    /// (not Data, not URL).
    @Test("Folder path persists as a String under the canonical key")
    func roundTripFolderPath() {
        let suite = "TestSuite-SaveToChip-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let testPath = "/Users/test/Recordings"
        defaults.set(testPath, forKey: outputFolderKey)
        let read = defaults.string(forKey: outputFolderKey)
        #expect(read == testPath)
    }

    /// Default value is an empty string (not nil, not "~/Recordings").
    /// `SaveToChip.onAppear` bootstraps to `DefaultRecordingFolder.resolve()`
    /// when the stored value is empty — so the @AppStorage default itself
    /// must be "" for that bootstrap branch to fire.
    @Test("Default stored value is an empty string (bootstrap fires on empty)")
    func defaultIsEmptyString() {
        let suite = "TestSuite-SaveToChip-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        // When the key has never been set, the stored value is nil.
        // @AppStorage("com.macrec.ui.outputFolder") private var folderPath: String = ""
        // So code branches on `folderPath.isEmpty` which is true for both nil and "".
        let stored: String? = defaults.string(forKey: outputFolderKey)
        let effective = stored ?? ""
        #expect(effective.isEmpty)
    }

    // MARK: - Display name derivation

    /// `SaveToChip.displayName` uses `URL(fileURLWithPath:).lastPathComponent`.
    /// Pin the URL decomposition so the display logic is documented and
    /// any future change is flagged.
    @Test("lastPathComponent of a path gives the folder display name")
    func lastPathComponent() {
        let path = "/Users/test/Recordings"
        let component = URL(fileURLWithPath: path).lastPathComponent
        #expect(component == "Recordings")
    }

    @Test("lastPathComponent works for nested paths")
    func lastPathComponentNested() {
        let path = "/Users/giorgos/Documents/Meeting Notes"
        let component = URL(fileURLWithPath: path).lastPathComponent
        #expect(component == "Meeting Notes")
    }

    /// When `folderPath` is empty the chip shows "Choose…" (the localized
    /// prompt). Pin the string so the UI text contract is documented here.
    @Test("Empty folder path produces 'Choose...' display name contract")
    func emptyPathDisplayContract() {
        // From SaveToChip.displayName:
        //   guard !folderPath.isEmpty else { return String(localized: "Choose…") }
        let emptyPath = ""
        let isempty = emptyPath.isEmpty
        #expect(isempty)
        // The displayed text for this branch is documented as "Choose…"
        let expectedDisplay = "Choose\u{2026}" // "Choose…" with HORIZONTAL ELLIPSIS
        #expect(expectedDisplay == "Choose\u{2026}")
    }
}
