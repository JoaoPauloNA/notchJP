import Foundation
import os.log

nonisolated private let agyHookLogger = Logger(subsystem: "com.ruban.notchi", category: "AgyHookInstaller")

/// Installs the notchJP hook into AGY's `~/.gemini/config/hooks.json`.
/// It only adds (and later removes) its own `notchjp` entry, so entries of other tools such as
/// ai-memory are never touched. A copy of the original file is kept the first time.
struct AgyHookInstaller {
    nonisolated static let entryKey = "notchjp"
    nonisolated private static let scriptName = "notchjp-agy-hook.sh"

    nonisolated static var configDirectoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini/config", isDirectory: true)
    }
    nonisolated static var hooksJSONURL: URL { configDirectoryURL.appendingPathComponent("hooks.json") }
    nonisolated static var backupURL: URL { configDirectoryURL.appendingPathComponent("hooks.json.notchjp-backup") }
    nonisolated static var hookScriptURL: URL { configDirectoryURL.appendingPathComponent(scriptName) }

    /// The shape AGY already uses in this file: tool events take matcher groups, the others plain commands.
    nonisolated static func entry(script: String) -> [String: Any] {
        func command(_ event: String) -> [String: Any] {
            ["type": "command", "command": "\"\(script)\" \(event)"]
        }
        func group(_ event: String) -> [[String: Any]] {
            [["matcher": "", "hooks": [command(event)]]]
        }
        return [
            "PreInvocation": [command("PreInvocation")],
            "PreToolUse": group("PreToolUse"),
            "PostToolUse": group("PostToolUse"),
            "Stop": [command("Stop")],
        ]
    }

    /// Existing file with the `notchjp` entry added or replaced; nil when the file is not valid JSON.
    nonisolated static func upsert(from existing: Data?, script: String) -> Data? {
        guard var root = parse(existing) else { return nil }
        root[entryKey] = entry(script: script)
        return serialize(root)
    }

    /// Existing file without the `notchjp` entry; nil when the file is not valid JSON.
    nonisolated static func remove(from existing: Data?) -> Data? {
        guard var root = parse(existing) else { return nil }
        root.removeValue(forKey: entryKey)
        return serialize(root)
    }

    nonisolated static func hasEntry(in data: Data?) -> Bool {
        parse(data)?[entryKey] != nil
    }

    nonisolated static func isInstalled() -> Bool {
        hasEntry(in: try? Data(contentsOf: hooksJSONURL)) && FileManager.default.fileExists(atPath: hookScriptURL.path)
    }

    nonisolated static func agyDirectoryExists() -> Bool {
        FileManager.default.fileExists(atPath: configDirectoryURL.deletingLastPathComponent().path)
    }

    @discardableResult
    nonisolated static func installIfNeeded() -> Bool {
        let fileManager = FileManager.default
        guard agyDirectoryExists() else {
            agyHookLogger.warning("AGY not found (~/.gemini missing)")
            return false
        }
        guard let bundled = Bundle.main.url(forResource: "notchi-agy-hook", withExtension: "sh") else {
            agyHookLogger.error("AGY hook script not found in the app bundle")
            return false
        }
        do {
            try fileManager.createDirectory(at: configDirectoryURL, withIntermediateDirectories: true)
            let existing = fileManager.fileExists(atPath: hooksJSONURL.path) ? try Data(contentsOf: hooksJSONURL) : nil
            guard let updated = upsert(from: existing, script: hookScriptURL.path) else {
                agyHookLogger.error("hooks.json is not valid JSON; left untouched")
                return false
            }
            try HookFile.writeScriptIfNeeded(HookFile.installableScript(from: Data(contentsOf: bundled)), to: hookScriptURL, fileManager: fileManager)
            if let existing, !fileManager.fileExists(atPath: backupURL.path) {
                try existing.write(to: backupURL, options: .atomic)
                try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backupURL.path)
            }
            try write(updated)
            return true
        } catch {
            agyHookLogger.error("Failed to install the AGY hook: \(error.localizedDescription)")
            return false
        }
    }

    nonisolated static func uninstall() {
        let fileManager = FileManager.default
        if let data = try? Data(contentsOf: hooksJSONURL), hasEntry(in: data), let updated = remove(from: data) {
            try? write(updated)
        }
        try? fileManager.removeItem(at: hookScriptURL)
    }

    // MARK: Helpers

    /// Keeps the file's current permissions (AGY's is 0600).
    nonisolated private static func write(_ data: Data) throws {
        let fileManager = FileManager.default
        let permissions = (try? fileManager.attributesOfItem(atPath: hooksJSONURL.path)[.posixPermissions]) as? NSNumber
        try data.write(to: hooksJSONURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: permissions ?? 0o600], ofItemAtPath: hooksJSONURL.path)
    }

    nonisolated private static func parse(_ data: Data?) -> [String: Any]? {
        guard let data, !data.isEmpty else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    nonisolated private static func serialize(_ root: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }
}
