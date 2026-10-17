// NtakkerSettingsUI/SharedSettingsStore.swift — plan-025.
//
// The apps' live view of the shared settings file
// (`~/.tool-agents/ntakker/.env`, see `SharedSettings`). One instance per
// app (`.shared`). It watches the file's folder, so a change written by
// the other app, by the CLI's migration or by hand shows up at once; and
// every write goes to the file (atomic, mode 0600) and into the process
// environment, which the recording and Ask code read.
//
// `@SharedSetting` is the drop-in replacement for `@AppStorage` for the
// settings that moved into the file.

import Foundation
import NtakkerCore
import Observation
import SwiftUI

@MainActor @Observable
public final class SharedSettingsStore {
    public static let shared = SharedSettingsStore()

    public private(set) var values: [String: String] = [:]
    /// Set when the file exists but cannot be parsed; values then stay as
    /// last read, and writes still go through `EnvFileStore.upsert`.
    public private(set) var loadError: String?

    @ObservationIgnored private var source: DispatchSourceFileSystemObject?
    @ObservationIgnored private var folderFD: Int32 = -1

    init() {
        _ = try? ToolAgentsBootstrap.ensure(toolName: SharedSettings.toolName)
        reload()
        watch()
    }

    public func reload() {
        do {
            let fresh = try SharedSettings.readAll()
            loadError = nil
            guard fresh != values else { return }
            values = fresh
            for (k, v) in fresh { setenv(k, v, 1) }
        } catch {
            loadError = "\(SharedSettings.fileURL.path): \(error.localizedDescription)"
        }
    }

    public func string(_ key: String) -> String? {
        guard let v = values[key], !v.isEmpty else { return nil }
        return v
    }

    /// Write `value` (empty or nil removes the key).
    public func set(_ key: String, _ value: String?) {
        let v = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard (values[key] ?? "") != v else { return }
        do {
            try SharedSettings.write(key, v)
            if v.isEmpty { unsetenv(key); values[key] = nil } else { values[key] = v }
        } catch {
            loadError = "Could not save \(key): \(error.localizedDescription)"
        }
    }

    public func bool(_ key: String) -> Bool? {
        switch string(key)?.lowercased() {
        case "1", "true", "yes", "on": return true
        case "0", "false", "no", "off": return false
        default: return nil
        }
    }

    public func setBool(_ key: String, _ value: Bool) { set(key, value ? "true" : "false") }

    // MARK: - Watching

    @ObservationIgnored private var fileSource: DispatchSourceFileSystemObject?

    /// Two watchers: the folder (the apps write atomically, which replaces
    /// the file) and the file itself (an editor or `>>` changes it in
    /// place). After every folder event the file watcher is re-attached,
    /// since the file it watched may have been replaced.
    private func watch() {
        let dir = SharedSettings.fileURL.deletingLastPathComponent().path
        folderFD = open(dir, O_EVTONLY)
        guard folderFD >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: folderFD, eventMask: [.write, .rename, .delete], queue: .main)
        src.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.reload()
                self?.watchFile()
            }
        }
        let fd = folderFD
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
        watchFile()
    }

    private func watchFile() {
        fileSource?.cancel()
        fileSource = nil
        let fd = open(SharedSettings.fileURL.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename], queue: .main)
        src.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.reload()
                if let s = self?.fileSource, s.data.contains(.delete) || s.data.contains(.rename) { self?.watchFile() }
            }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        fileSource = src
    }
}

/// `@AppStorage`-style access to a string setting in the shared file.
/// The default is what the tools use when the key is unset (documented
/// per key); it is never written to the file on its own.
@MainActor @propertyWrapper
public struct SharedSetting: DynamicProperty {
    private let key: String
    private let defaultValue: String
    private let store: SharedSettingsStore

    public init(wrappedValue: String, _ key: String, store: SharedSettingsStore = .shared) {
        self.key = key
        self.defaultValue = wrappedValue
        self.store = store
    }

    public var wrappedValue: String {
        get { store.string(key) ?? defaultValue }
        nonmutating set { store.set(key, newValue) }
    }

    public var projectedValue: Binding<String> {
        Binding(get: { wrappedValue }, set: { wrappedValue = $0 })
    }
}

/// Boolean flavour (`true`/`false` in the file).
@MainActor @propertyWrapper
public struct SharedBoolSetting: DynamicProperty {
    private let key: String
    private let defaultValue: Bool
    private let store: SharedSettingsStore

    public init(wrappedValue: Bool, _ key: String, store: SharedSettingsStore = .shared) {
        self.key = key
        self.defaultValue = wrappedValue
        self.store = store
    }

    public var wrappedValue: Bool {
        get { store.bool(key) ?? defaultValue }
        nonmutating set { store.setBool(key, newValue) }
    }

    public var projectedValue: Binding<Bool> {
        Binding(get: { wrappedValue }, set: { wrappedValue = $0 })
    }
}
