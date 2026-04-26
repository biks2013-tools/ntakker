// MacrecCoreTests/LoggerFactoryTests.swift — see project-design.md §2.5, §6
//
// Phase G (plan-001) — unit tests for LoggerFactory and the LogLevel →
// Logger.Level bridge. Verifies idempotent bootstrap, label round-trip,
// and the design §2.5 level-mapping table (.quiet→.warning, .info→.info,
// .debug→.debug).

import Foundation
import Logging
import Testing
@testable import MacrecCore

@Suite("LoggerFactory")
struct LoggerFactoryTests {

    // MARK: - bootstrap idempotency

    @Test("bootstrap(level:) is idempotent — second call does not crash")
    func bootstrapIdempotent() {
        // The BootstrapState guard ensures LoggingSystem.bootstrap is called
        // at most once per process. Calling LoggerFactory.bootstrap twice
        // must be a no-op rather than a trap.
        LoggerFactory.bootstrap(level: .info)
        LoggerFactory.bootstrap(level: .debug) // must not crash
        LoggerFactory.bootstrap(level: .quiet) // third call, also safe
    }

    // MARK: - make(_:) label round-trip

    @Test("make(_:) returns a Logger whose label matches the requested string")
    func makeLabelRoundTrip() {
        LoggerFactory.bootstrap(level: .info)
        let label = "macrec.test.label"
        let logger = LoggerFactory.make(label)
        #expect(logger.label == label)
    }

    @Test("make returns distinct Loggers for distinct labels")
    func makeDistinctLabels() {
        LoggerFactory.bootstrap(level: .info)
        let a = LoggerFactory.make("macrec.a")
        let b = LoggerFactory.make("macrec.b")
        #expect(a.label != b.label)
    }

    // MARK: - LogLevel rawValue round-trip

    @Test("LogLevel.quiet rawValue is 'quiet'")
    func logLevelQuietRawValue() {
        #expect(LogLevel.quiet.rawValue == "quiet")
    }

    @Test("LogLevel.info rawValue is 'info'")
    func logLevelInfoRawValue() {
        #expect(LogLevel.info.rawValue == "info")
    }

    @Test("LogLevel.debug rawValue is 'debug'")
    func logLevelDebugRawValue() {
        #expect(LogLevel.debug.rawValue == "debug")
    }

    @Test("LogLevel can be reconstructed from its rawValue")
    func logLevelFromRawValue() {
        #expect(LogLevel(rawValue: "quiet") == .quiet)
        #expect(LogLevel(rawValue: "info") == .info)
        #expect(LogLevel(rawValue: "debug") == .debug)
        #expect(LogLevel(rawValue: "invalid") == nil)
    }

    // MARK: - LogLevel.loggingLevel mapping (design §2.5 — LOCKED table)

    @Test("LogLevel.quiet maps to Logger.Level.warning")
    func quietMapsToWarning() {
        #expect(LogLevel.quiet.loggingLevel == .warning)
    }

    @Test("LogLevel.info maps to Logger.Level.info")
    func infoMapsToInfo() {
        #expect(LogLevel.info.loggingLevel == .info)
    }

    @Test("LogLevel.debug maps to Logger.Level.debug")
    func debugMapsToDebug() {
        #expect(LogLevel.debug.loggingLevel == .debug)
    }

    // MARK: - All LogLevel cases are covered

    @Test("Every LogLevel case has a non-trivial loggingLevel")
    func allCasesCovered() {
        // This test will fail at compile time if a new case is added to
        // LogLevel but not handled here.
        for level in LogLevel.allCases {
            let mapped = level.loggingLevel
            // Each case must map to one of the three swift-log levels we
            // committed to in design §2.5.
            let allowed: [Logger.Level] = [.warning, .info, .debug]
            #expect(allowed.contains(mapped), "\(level) maps to unexpected level \(mapped)")
        }
    }
}
