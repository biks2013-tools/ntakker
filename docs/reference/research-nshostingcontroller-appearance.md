# NSHostingController Appearance Propagation on macOS 26

**Research date**: 2026-04-30
**Context**: Validates the `AppearanceHostingRoot` design recommended in `investigation-ui-redesign.md` Topic 2.

---

## Core Question — Direct Answer

**Does `NSHostingController` (hosting an `NSPopover`) propagate `NSApplication.effectiveAppearance` changes into `@Environment(\.colorScheme)` automatically when the SwiftUI root applies `.preferredColorScheme(nil)`?**

**Answer: CONDITIONAL YES, with one significant caveat.**

`NSHostingController` does inherit and forward `effectiveAppearance` changes from its parent window into the SwiftUI environment — this is the baseline AppKit behavior: appearance propagates downstream through the view hierarchy, and `NSPopover` is documented to "automatically handle appearance inheritance" for common floating surfaces (popovers, tooltips, menus). The system appearance flip (user toggles Light/Dark in System Settings) therefore does reach the hosted SwiftUI tree and triggers a redraw of `@Environment(\.colorScheme)`.

The caveat: `.preferredColorScheme(nil)` only reliably defers to the system if it has never been set to `.light` or `.dark` in the same hosting session — or if it is set freshly on every appearance of the popover. A confirmed bug present up through macOS 14 (Sonoma) caused the modifier to get "stuck" once a non-nil value had been applied: resetting to `nil` at runtime did not restore live system-following behavior. Apple confirmed this was **fixed in macOS 15 (Sequoia)** and the fix carries forward into macOS 26 (Tahoe). Because the project targets macOS 26 exclusively (Exception 002), the fix is present and the design is sound.

**Confidence: MEDIUM-HIGH.** The macOS 15 fix is corroborated by multiple developer forum threads and one Apple DTS response but Apple has not published a release note entry for it. There is no direct macOS 26-specific documentation confirming the same behavior; the inference is that the fix persists.

---

## Key Concepts

### 1. How `NSHostingController` Receives Appearance Changes

`NSHostingController`'s underlying view (`NSHostingView`, a subclass of `NSView`) participates in the standard AppKit appearance-propagation chain:

- `NSView.effectiveAppearance` is computed from the view's own `appearance` (if set) or inherited from its superview.
- `NSPopover` is a separate `NSWindow`-like surface but Apple's AppKit automatically handles appearance inheritance for popovers, menus, and tooltips — they inherit the parent window's effective appearance.
- When the user flips the system appearance, `NSApp.effectiveAppearance` changes. `NSApp.observe(\.effectiveAppearance)` fires immediately (KVO). The hosting view's `viewDidChangeEffectiveAppearance()` is called, and SwiftUI re-evaluates `@Environment(\.colorScheme)` for every view in the hosted tree.

This propagation chain is automatic. No manual observer is needed in `PopoverController` for the system-appearance-flip case.

### 2. `.preferredColorScheme(nil)` Semantics on macOS 26

`.preferredColorScheme(_:)` sets a preference that "floats up" to the presentation boundary — in the case of `NSHostingController`, the presentation is the popover. Passing `nil` signals "no override; inherit whatever the host provides." On macOS 26 with the macOS 15 bug fix in place:

- First launch or fresh `rootView` assignment with `nil` → follows system immediately.
- Transition from `.light` or `.dark` back to `nil` at runtime → follows system (fixed; was broken pre-macOS 15).
- `@AppStorage` reactivity drives the modifier update: when `AppearanceMode` changes to `.system`, `AppearanceMode.colorScheme` returns `nil`, SwiftUI diffs the modifier, and the popover repaints on the next run-loop pass.

### 3. `NSPopover.appearance` Property

`NSPopover` exposes an `appearance: NSAppearance?` property (distinct from the deprecated `NSPopoverAppearance` enum). When `nil` (the default), the popover inherits from the application's effective appearance. **Do not set this property** unless you want to lock the popover to a fixed appearance independent of the system — setting it to `.aqua` or `.darkAqua` would override `.preferredColorScheme` and break the Follow-System path.

### 4. Notification That Fires on System Flip

There is no `NotificationCenter` notification for system appearance changes. The canonical mechanism is:

```swift
// KVO on NSApp — fires immediately when the user toggles System Preferences
let token = NSApp.observe(\.effectiveAppearance) { app, _ in
    // Appearance has changed at the app level
}
```

For views, `NSView.viewDidChangeEffectiveAppearance()` is the equivalent hook. `NSHostingView` uses this internally to push the updated appearance into the SwiftUI environment — developers do not need to implement it themselves.

---

## Canonical Recipe (macOS 26, `NSHostingController` + `NSPopover`)

```swift
// AppearanceMode.swift
enum AppearanceMode: String, CaseIterable {
    case system, light, dark
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}

// AppearanceHostingRoot.swift
struct AppearanceHostingRoot: View {
    @AppStorage("com.macrec.ui.appearance") private var raw: String = "system"
    var body: some View {
        RootView()
            .preferredColorScheme(AppearanceMode(rawValue: raw)?.colorScheme)
    }
}

// PopoverController.swift  (only the relevant line changes)
hostingController = NSHostingController(rootView: AppearanceHostingRoot())
// No additional observer needed for appearance:
// @AppStorage reactivity drives re-evaluation inside the SwiftUI graph.
// NSPopover.appearance must remain nil (default) — do NOT set it.
```

The wrapper is the entire fix. `@AppStorage` is KVO-backed; when `UserDefaults` writes the new appearance key, SwiftUI re-evaluates `AppearanceHostingRoot.body`, updates the `.preferredColorScheme` modifier, and the popover repaints — all within one run loop. No `rootView` re-assignment, no manual `NotificationCenter` observer.

---

## Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| `.preferredColorScheme(nil)` stuck after prior explicit value | LOW on macOS 26 (fixed in macOS 15) | If observed, force-refresh by re-assigning `hostingController.rootView = AppearanceHostingRoot()` on appearance-to-system transition |
| `NSPopover.appearance` set elsewhere in codebase | LOW | Audit `PopoverController`; ensure the property is never written |
| Race condition: popover open while system flips | VERY LOW | AppKit queues `viewDidChangeEffectiveAppearance` on the main queue; the view is not in the middle of a draw. SwiftUI's environment update is deferred to next layout pass. |
| `@AppStorage` key written from background thread | LOW | `UserDefaults.set(_:forKey:)` is thread-safe; SwiftUI's `@AppStorage` delivers the change on the main actor |
| Vibrancy "double-frost" if `NSPopover.appearance` is accidentally set | MEDIUM | Keep `NSPopover.appearance = nil`; do not set `.regularMaterial` inside section backgrounds |
| macOS 26 beta regression in `preferredColorScheme(nil)` tracking | LOW | Verify manually during spike (step 2 of the implementation plan) |

---

## Assumptions and Scope

| Assumption | Confidence | Impact if Wrong |
|---|---|---|
| macOS 15 fix for `preferredColorScheme(nil)` revert carries into macOS 26 | MEDIUM-HIGH | Would need KVO observer on `NSApp.effectiveAppearance` that re-assigns `hostingController.rootView` |
| `NSPopover` inherits `NSApp.effectiveAppearance` automatically (no manual plumbing needed) | HIGH | If not, set `popover.appearance = nil` explicitly to reset any accidental override |
| `@AppStorage` reactivity propagates inside `NSHostingController` SwiftUI graph | HIGH | Well-documented and exercised in the existing `heightObserver` pattern |

**Out of scope**: iOS appearance behavior, `UIWindow.overrideUserInterfaceStyle`, multi-window macOS apps, `NSApp.appearance` mutation (Option 2.B from investigation).

---

## Clarifying Questions for Follow-up

1. Does the project's existing `PopoverController` set `popover.appearance` anywhere? A grep for `.appearance` in `PopoverController.swift` should confirm.
2. Is there any test infrastructure for verifying the `@Environment(\.colorScheme)` value inside a hosted SwiftUI view? If not, manual spike (Acceptance Criterion 5) is the only verification path.
3. Should the Settings window also apply `.preferredColorScheme`? (Yes, per investigation Topic 2 — but it is handled by a separate modifier on the `Settings { }` scene and is not in scope for `AppearanceHostingRoot`.)

---

## References

| # | Source | URL | Information Gathered |
|---|---|---|---|
| 1 | Apple Developer Forums — `preferredColorScheme` not working w/ Xcode 16 | [forums thread 765709](https://developer.apple.com/forums/thread/765709) | Confirmed `preferredColorScheme` + `@AppStorage` broken on macOS 14, confirmed fixed on macOS 15 |
| 2 | WWDC23 "What's New in AppKit" (Session 10054) | [developer.apple.com/videos/play/wwdc2023/10054/](https://developer.apple.com/videos/play/wwdc2023/10054/) | `sceneBridgingOptions`, `NSHostingView`/`NSHostingController` scene-modifier bridging, appearance propagation chain |
| 3 | Jesse Squires — Observing appearance changes on macOS | [jessesquires.com blog 2020-01-08](https://www.jessesquires.com/blog/2020/01/08/observing-appearance-changes-on-ios-and-macos/) | KVO on `NSApp.effectiveAppearance` is the canonical immediate-notification mechanism; `UserDefaults["AppleInterfaceStyle"]` is a hack |
| 4 | TechConcepts — Building macOS Menu Bar Apps with SwiftUI and NSPopover | [techconcepts.org/blog/macos-menu-bar-swiftui-nspopover](https://techconcepts.org/blog/macos-menu-bar-swiftui-nspopover) | Confirmed: popover and Settings scene are separate view hierarchies; shared `@Observable` singleton is the canonical pattern; `NSPopover.appearance` must not be set |
| 5 | Workarounds for reliable color scheme switching — angelo | [write.as/angelo/workarounds](https://write.as/angelo/workarounds-or-how-to-get-reliable-color-scheme-switching-in-swiftui-apps) | Historical record of `preferredColorScheme(nil)` bug in macOS 11 betas; `NSApp.appearance = nil` as AppKit-level workaround |
| 6 | nilcoalescing.com — Reading and setting color scheme in SwiftUI | [nilcoalescing.com/blog/ReadingAndSettingColorSchemeInSwiftUI/](https://nilcoalescing.com/blog/ReadingAndSettingColorSchemeInSwiftUI/) | `.preferredColorScheme` is intercepted at presentation level; setting inside popover only affects that presentation |
| 7 | Apple Developer Documentation — NSAppearance (AppKit propagation chain) | [developer.apple.com/documentation/appkit/nsappearance](https://developer.apple.com/documentation/appkit/nsappearance) | Appearance propagates downstream through view hierarchy; popovers/menus/tooltips automatically inherit from parent |

### Recommended for Deep Reading

- **Apple Developer Forums thread 765709** — the clearest confirmation of the macOS 15 fix for `preferredColorScheme(nil)` revert with `@AppStorage`.
- **WWDC23 Session 10054 "What's New in AppKit"** — authoritative source on `sceneBridgingOptions` and how `NSHostingController` integrates with AppKit's appearance system on macOS Sonoma+.
- **Jesse Squires' KVO post** — the safest escape hatch recipe if the primary approach fails during the spike.
