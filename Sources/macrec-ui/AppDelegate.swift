// macrec-ui/AppDelegate.swift — see project-design.md §15.1, §15.2,
// §15.11 (quit-while-recording flow), §15.12 (threading), §15.13 (logging),
// and plan-002-toolbar-ui.md §3 Phase C, §3 Phase H.
//
// AppKit `NSApplicationDelegate` for the menu-bar accessory app.
// Instantiated and retained by SwiftUI via the
// `@NSApplicationDelegateAdaptor(AppDelegate.self)` declaration in
// `MacrecUIApp`.
//
// Phase C responsibilities (this file):
//   1. Bootstrap `LoggerFactory` at `.info` once at launch (§15.13).
//   2. Defensively call `NSApp.setActivationPolicy(.accessory)` (in
//      addition to `LSUIElement=true` already set in MacrecUI-Info.plist).
//      Investigation Topic 1 gotcha #1.
//   3. Create the `NSStatusItem` and retain it as a strong stored
//      property (R-26 — local-variable retention loses the icon).
//   4. Construct `PopoverController` (hosting an `NSHostingController<RootView>`).
//   5. Construct `StatusItemController` and wire its click callback to
//      `PopoverController.toggle(relativeTo:)`.
//   6. Stub `applicationShouldTerminate(_:)` returning `.terminateNow`
//      (Phase F replaces this with the confirm-then-finalize-then-quit
//      flow — see project-design.md §15.11).
//
// Phase H additions (this file):
//   - Bootstrap calls `LoggerFactory.bootstrap(subsystem:fileURL:levelString:)`
//     so logs route to BOTH macOS unified logging (Console.app under
//     subsystem `com.local.macrec-ui`) AND the per-UI log file at
//     `~/.tool-agents/macrec-ui/macrec-ui.log` (mode 0600, append).
//   - The hidden `UILoggingMenu` is constructed and held as a stored
//     property so option-click on the status item bar can swap to a
//     debug menu (NFR-16 hidden toggle).
//
// `RecordingController` (Phase D) is NOT instantiated here yet. The
// stored property exists as a placeholder so Phase D's wiring is a
// purely-additive edit. Phase D will:
//   - construct `RecordingController` here in `applicationDidFinishLaunching`,
//   - subscribe `StatusItemController.setState` to its state stream,
//   - inject it into `RootView` via SwiftUI environment.
//
// Concurrency: `NSApplicationDelegate` is implicitly main-thread by
// AppKit contract, but we mark this class `@MainActor` explicitly per
// the strict-concurrency discipline laid out in §15.12 — Swift's
// concurrency checker will not infer `@MainActor` from AppKit
// conformance alone, so the annotation is load-bearing.

import AppKit
import Logging
import MacrecCore
import MacrecUIKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - Strong-retained AppKit components
    //
    // Per investigation Topic 1 gotcha #4 (R-26): the `NSStatusItem`
    // MUST be held by a strong reference on a long-lived owner.
    // Otherwise AppKit deallocates it on the first run-loop tick after
    // the constructing scope returns, and the menu-bar icon vanishes
    // with no error logged. This `AppDelegate` lives for the entire
    // process lifetime (SwiftUI retains it via `@NSApplicationDelegateAdaptor`),
    // so storing the status item here is the canonical idiom.

    /// The menu-bar status item itself. STRONG-RETAINED stored property
    /// per R-26 (see investigation Topic 1, plan-002 §3 Phase C gate
    /// criteria, and project-design §15.1). DO NOT change this to a
    /// computed property or a local in `applicationDidFinishLaunching`.
    private var statusItem: NSStatusItem!

    /// Click handler / icon mapper for the status item.
    private var statusItemController: StatusItemController!

    /// Owns the `NSPopover` hosting the SwiftUI body.
    private var popoverController: PopoverController!

    /// View-model owning all UI-visible state (Phase D, project-design
    /// §15.4). Constructed in `applicationDidFinishLaunching(_:)` and
    /// retained for the lifetime of the app — its observable state
    /// drives the menu-bar icon (via the events forwarder spawned
    /// below) and the popover's SwiftUI views (via the SwiftUI
    /// environment, see `RecordingControllerKey`).
    private var recordingController: RecordingController!

    /// Background `Task` consuming `recordingController.state` updates
    /// to re-tint the status-bar icon. Cancelled in
    /// `applicationWillTerminate(_:)` (Phase F will own that hook).
    private var stateObserverTask: Task<Void, Never>?

    /// Hidden debug-only logging menu (Phase H, NFR-16). Constructed
    /// once at launch and shown ONLY when the user option-clicks the
    /// status-bar icon. Default left-click toggles the popover via
    /// `popoverController` as before.
    private var uiLoggingMenu: UILoggingMenu!

    /// Quit-while-recording flow helper (Phase F, project-design
    /// §15.11). Owns the confirm-then-finalize-then-quit decision tree
    /// invoked from `applicationShouldTerminate(_:)`. Constructed in
    /// `applicationDidFinishLaunching(_:)` after `recordingController`
    /// is built (it captures the controller).
    private var quitFlow: QuitFlow!

    // MARK: - Loggers
    //
    // Per project-design §15.13, every UI component receives a Logger
    // built from `LoggerFactory.make(_:)` with a subsystem prefix of
    // `macrec.ui.<subsystem>`. Loggers are instantiated here (NOT
    // inline inside methods) so the labels are visible in one place.

    private let logger = LoggerFactory.make("macrec.ui.app")
    private let statusItemLogger = LoggerFactory.make("macrec.ui.statusItem")
    private let popoverLogger = LoggerFactory.make("macrec.ui.popover")
    private let controllerLogger = LoggerFactory.make("macrec.ui.controller")
    private let loggingMenuLogger = LoggerFactory.make("macrec.ui.loggingMenu")
    private let quitFlowLogger = LoggerFactory.make("macrec.ui.quitFlow")

    // MARK: - Logging configuration constants
    //
    // Pinned here so they can be reused by `UILoggingMenu` (which
    // re-bootstraps with the SAME subsystem and file URL when the
    // user picks a different level — only the level changes).

    /// macOS unified-logging subsystem string for this app.
    /// Mirrors `CFBundleIdentifier` from `Resources/MacrecUI-Info.plist`
    /// (R-23 — must NOT collide with the CLI's `com.local.macrec`).
    private static let osLogSubsystem = "com.local.macrec-ui"

    /// Tool name for `~/.tool-agents/<toolName>/`. Used to derive both
    /// the `.env` location and the per-UI log file path.
    private static let toolAgentsName = "macrec-ui"

    /// Per-UI log file name (NFR-16). Lives at
    /// `~/.tool-agents/macrec-ui/macrec-ui.log`.
    private static let logFileName = "macrec-ui.log"

    /// Env-var name for the diagnostic log level (NFR-16). Sourced from
    /// the shell environment, which `swift-log`'s bootstrap will then
    /// honor. Allowed values: `info | debug | trace`.
    private static let logLevelEnvVar = "MACREC_UI_LOG_LEVEL"

    /// Resolved log file URL. Computed once in `bootstrapLogging()`
    /// and reused by `UILoggingMenu` on level changes.
    private var resolvedLogFileURL: URL?

    /// The level that was successfully applied by the most recent
    /// bootstrap. Stored as the original env-var string (`info` /
    /// `debug` / `trace`) so the `UILoggingMenu` can render its
    /// checkmark and round-trip back into a re-bootstrap.
    private var resolvedLogLevelString: String = "info"

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 1. Bootstrap swift-log first so every subsequent log line
        //    routes through the same handler. Per project-design §15.13
        //    the UI uses a DUAL backend (macOS unified logging via
        //    OSLog under subsystem `com.local.macrec-ui`, AND a plain-
        //    text file at `~/.tool-agents/macrec-ui/macrec-ui.log`
        //    mode 0600). Idempotent — safe even if a future call site
        //    bootstraps again.
        bootstrapLogging()

        // 1b. Merge `~/.tool-agents/macrec-ui/.env` into the running
        //     process environment. Without this, the four-tier
        //     resolution chain documented in the .env file's header
        //     was effectively shell-only for the UI app — a saved
        //     `GOOGLE_API_KEY` would be invisible to the
        //     `ProcessInfo.processInfo.environment` lookup that
        //     `ControlBar` does at start-recording time. Shell-set
        //     values still win (the loader uses `setenv(..., 0)` which
        //     is a no-op when the variable is already present).
        let merged = EnvFileStore.loadIntoProcess(toolName: AppDelegate.toolAgentsName)
        logger.info("merged \(merged.count) env-file key(s) into process environment")

        logger.info("macrec-ui launching (bundle id=\(Bundle.main.bundleIdentifier ?? "<nil>"))")

        // 2. Defensive activation policy (investigation Topic 1
        //    gotcha #1). LSUIElement=true in MacrecUI-Info.plist
        //    already implies `.accessory`, but SwiftPM-built executables
        //    not wrapped in a `.app` bundle have been observed to keep
        //    a Dock icon unless this is also called explicitly.
        NSApp.setActivationPolicy(.accessory)
        logger.debug("activation policy set to .accessory")

        // 3. Create and retain the status item (R-26).
        //    `variableLength` lets the icon size to its content;
        //    `NSStatusBar.system` is the standard system menu bar.
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        logger.debug("NSStatusItem allocated (variableLength)")

        // 4. Build the `RecordingController` (Phase D, project-design
        //    §15.4). The controller is the single source of UI-visible
        //    state and outlives the popover (so the popover can close
        //    and re-open without losing recording state).
        recordingController = RecordingController(logger: controllerLogger)
        logger.debug("RecordingController constructed")

        // 4a. Build the quit-while-recording flow (Phase F,
        //     project-design §15.11). Captures the controller; held as
        //     a stored property so `applicationShouldTerminate(_:)`
        //     can delegate to it without re-allocating per call.
        quitFlow = QuitFlow(
            controller: recordingController,
            logger: quitFlowLogger
        )
        logger.debug("QuitFlow constructed")

        // 5. Build the popover (hosts `RootView` via NSHostingController).
        //    The controller is injected into the SwiftUI environment so
        //    `RootView` (and Phase E's sub-views) can read it via
        //    `@Environment(\.recordingController)`. The popover applies
        //    the environment modifier internally so its hosting
        //    controller can stay parameterized on the concrete
        //    `RootView` type.
        popoverController = PopoverController(
            rootView: RootView(),
            recordingController: recordingController,
            logger: popoverLogger
        )

        // 6. Build the hidden debug-only logging menu (Phase H).
        //    Surfaced ONLY on option-click; never visible during a
        //    normal click. NFR-16.
        uiLoggingMenu = UILoggingMenu(
            subsystem: AppDelegate.osLogSubsystem,
            fileURL: resolvedLogFileURL,
            currentLevel: resolvedLogLevelString,
            logger: loggingMenuLogger
        )

        // 7. Build the status-item controller and wire its click
        //    callbacks. Normal click → toggle the popover (Phase C
        //    behavior, unchanged). Option-click → show the hidden
        //    `UILoggingMenu` (Phase H, NFR-16). Both closures capture
        //    `self` weakly to avoid an AppDelegate ↔ controller retain
        //    cycle (AppDelegate retains the controller; the controller's
        //    callbacks would otherwise retain AppDelegate).
        statusItemController = StatusItemController(
            statusItem: statusItem,
            onClick: { [weak self] in
                guard let self else { return }
                guard let button = self.statusItem.button else {
                    self.logger.error("status item button missing on click")
                    return
                }
                self.popoverController.toggle(relativeTo: button)
            },
            onOptionClick: { [weak self] in
                guard let self else { return }
                self.logger.debug("option-click → opening UILoggingMenu")
                self.uiLoggingMenu.show(from: self.statusItem)
            },
            logger: statusItemLogger
        )

        // 8. Spawn the state-observer task. Watches
        //    `recordingController.state` (an `@Observable` property
        //    on a `@MainActor` view-model) and re-tints the status-bar
        //    icon accordingly. Implemented with `withObservationTracking`
        //    so a single observation re-arms itself on every read.
        startStateObserver()

        logger.info("macrec-ui ready (status item visible, popover wired, controller live)")
    }

    /// Re-arming observation loop driving the status-bar icon. Reads
    /// `recordingController.state` inside `withObservationTracking`,
    /// which fires the `onChange` closure exactly once on the next
    /// mutation; we call back into ourselves to rearm.
    ///
    /// Cancelled by `applicationWillTerminate(_:)` (Phase F owns that
    /// hook). The closure captures `self` weakly so AppDelegate is the
    /// sole owner of the observation chain.
    private func startStateObserver() {
        // Apply the current state immediately so the icon is correct
        // before any transition fires.
        statusItemController.setState(recordingController.state)

        withObservationTracking { [weak self] in
            // Touch the observed property to register the dependency.
            _ = self?.recordingController.state
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.statusItemController.setState(self.recordingController.state)
                // Re-arm the observation.
                self.startStateObserver()
            }
        }
    }

    // MARK: - Logging bootstrap (Phase H)

    /// Bootstraps swift-log for the UI app. Per project-design §15.13
    /// the UI installs a DUAL backend:
    ///   1. macOS unified logging (`OSLog`) under subsystem
    ///      `com.local.macrec-ui`, category = logger label. Visible
    ///      via Console.app and `log stream --subsystem com.local.macrec-ui`.
    ///   2. Plain-text append-only file at
    ///      `~/.tool-agents/macrec-ui/macrec-ui.log` (mode 0600). The
    ///      enclosing directory is materialized at mode 0700 by
    ///      `ToolAgentsBootstrap.ensure(toolName:)` (idempotent).
    ///
    /// Level resolution (NFR-16):
    ///   - Reads `MACREC_UI_LOG_LEVEL` from the process environment
    ///     (which already includes the merged `~/.tool-agents/macrec-ui/.env`
    ///     contents under the four-tier env-var resolution chain — see
    ///     `~/.tool-agents/macrec-ui/.env` for the documented chain).
    ///   - Allowed values: `info | debug | trace`.
    ///   - Unset → `.info` (documented exception to the no-fallback
    ///     rule; applies ONLY to diagnostic verbosity, see the same
    ///     `.env` file).
    ///   - Set to anything else → `LoggerFactory.bootstrap` throws,
    ///     we log a warning to stderr (the only sink available before
    ///     bootstrap completes) and re-bootstrap at `.info`.
    private func bootstrapLogging() {
        // Materialize ~/.tool-agents/macrec-ui/ at 0700 and seed the
        // .env at 0600 (idempotent). Failure here is recoverable — we
        // fall back to OSLog-only by leaving `resolvedLogFileURL` nil.
        var logFileURL: URL? = nil
        do {
            let dir = try ToolAgentsBootstrap.ensure(
                toolName: AppDelegate.toolAgentsName
            )
            logFileURL = dir.appendingPathComponent(AppDelegate.logFileName)
        } catch {
            FileHandle.standardError.write(Data(
                "macrec-ui: ToolAgentsBootstrap.ensure failed: \(error); continuing with OSLog only\n".utf8
            ))
        }
        self.resolvedLogFileURL = logFileURL

        // Read the env var (may be nil). The new bootstrap overload
        // validates the string and throws on garbage.
        let rawLevel = ProcessInfo.processInfo
            .environment[AppDelegate.logLevelEnvVar]

        do {
            try LoggerFactory.bootstrap(
                subsystem: AppDelegate.osLogSubsystem,
                fileURL: logFileURL,
                levelString: rawLevel
            )
            // Persist the resolved string for the UILoggingMenu's
            // checkmark and re-bootstrap round-trip. When unset we
            // resolved to `.info` per the documented default.
            self.resolvedLogLevelString = (rawLevel?.lowercased()).flatMap {
                ["info", "debug", "trace"].contains($0) ? $0 : nil
            } ?? "info"
        } catch {
            // Invalid env-var value. Surface a warning on stderr (we
            // don't have a Logger yet) and retry at the documented
            // default. The retry path is guaranteed to succeed because
            // we're passing nil → resolves to `.info`.
            FileHandle.standardError.write(Data(
                "macrec-ui: invalid \(AppDelegate.logLevelEnvVar)='\(rawLevel ?? "")' — \(error); falling back to info\n".utf8
            ))
            do {
                try LoggerFactory.bootstrap(
                    subsystem: AppDelegate.osLogSubsystem,
                    fileURL: logFileURL,
                    levelString: nil
                )
            } catch {
                // Unreachable — `nil` is the documented happy-path
                // input — but the throwing API forces us to handle it.
                FileHandle.standardError.write(Data(
                    "macrec-ui: fallback bootstrap also failed: \(error)\n".utf8
                ))
            }
            self.resolvedLogLevelString = "info"
        }
    }

    /// Phase F: delegate the entire quit-while-recording decision to
    /// `QuitFlow.handleTerminationRequest()`. The helper returns the
    /// final `NSApplication.TerminateReply` synchronously:
    ///
    ///   - `.terminateNow`     — no recording in flight; quit immediately.
    ///   - `.terminateCancel`  — user picked "Keep Recording".
    ///   - `.terminateLater`   — user picked "Stop & Quit"; the helper
    ///                           has already kicked off `controller.stop()`
    ///                           and armed an observer that will call
    ///                           `NSApp.reply(toApplicationShouldTerminate: true)`
    ///                           when the controller reaches `.stopped`
    ///                           or `.failed`. AppKit defers the actual
    ///                           process exit until that reply lands.
    ///
    /// See project-design.md §15.11 for the full flow specification and
    /// `QuitFlow.swift` for the implementation.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        logger.info("applicationShouldTerminate received — delegating to QuitFlow")
        return quitFlow.handleTerminationRequest()
    }
}
