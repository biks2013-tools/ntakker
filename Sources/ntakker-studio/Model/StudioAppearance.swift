// ntakker-studio/Model/StudioAppearance.swift — 2026-10-18.
//
// Light / dark / follow-the-system for the whole studio. Applied through
// `NSApp.appearance`, so every window follows it — the main window, the
// Settings window, popovers, sheets and the open/save panels — and
// "System" really goes back to following macOS (nil), which
// `.preferredColorScheme(nil)` does not do reliably on macOS.
//
// A per-app preference (UserDefaults), like the other UI state; it is
// not one of the shared settings in ~/.tool-agents/ntakker/.env.

import AppKit
import SwiftUI

enum StudioAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    static let userDefaultsKey = "studio.appearance"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// The stored choice; an unknown or missing value means `.system`.
    static var current: StudioAppearance {
        UserDefaults.standard.string(forKey: userDefaultsKey).flatMap(StudioAppearance.init(rawValue:)) ?? .system
    }

    /// Apply `raw` (a stored value) to the whole app.
    @MainActor
    static func apply(_ raw: String) {
        let mode = StudioAppearance(rawValue: raw) ?? .system
        switch mode {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

/// The System / Light / Dark choice, used in Settings ▸ General and in
/// the View ▸ Appearance menu. Choosing applies it at once.
struct StudioAppearancePicker: View {
    @AppStorage(StudioAppearance.userDefaultsKey) private var raw = StudioAppearance.system.rawValue
    var label = "Appearance"
    var style: Style = .menu

    enum Style { case menu, segmented }

    var body: some View {
        let picker = Picker(label, selection: Binding(
            get: { raw },
            set: { raw = $0; StudioAppearance.apply($0) }
        )) {
            ForEach(StudioAppearance.allCases) { Text($0.title).tag($0.rawValue) }
        }
        switch style {
        case .menu: picker
        case .segmented: picker.pickerStyle(.segmented)
        }
    }
}
