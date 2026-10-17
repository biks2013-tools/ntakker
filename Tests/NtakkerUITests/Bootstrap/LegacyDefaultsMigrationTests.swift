import Foundation
import Testing
@testable import NtakkerUIKit

@Suite("LegacyDefaultsMigration")
struct LegacyDefaultsMigrationTests {
    @Test("copies legacy settings once and never overwrites new ones")
    func copiesOnce() {
        let suite = "ntakker-migration-test-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        d.set("new", forKey: "kept")
        let legacy: [String: Any] = ["kept": "old", "com.ntakker-cli.ui.outputFolder": "/x", "n": 3]
        #expect(LegacyDefaultsMigration.run(defaults: d, legacy: legacy) == 2)
        #expect(d.string(forKey: "kept") == "new")
        #expect(d.string(forKey: "com.ntakker-cli.ui.outputFolder") == "/x")
        #expect(d.integer(forKey: "n") == 3)
        d.removeObject(forKey: "n")
        #expect(LegacyDefaultsMigration.run(defaults: d, legacy: legacy) == 0, "runs only once")
        #expect(d.object(forKey: "n") == nil)
    }
}
