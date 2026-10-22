import Foundation

/// Adds and removes AgentGlance's Claude Code hooks and status line wrapper in settings.json.
/// Existing hooks (e.g. iTerm2's cc-status) and the existing status line command are kept.
public enum Installer {
    public static let hookEvents = [
        "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest",
        "Notification", "Stop", "StopFailure", "SubagentStop", "SessionEnd",
    ]
    public static let defaultBinary = NSHomeDirectory() + "/.local/bin/agentglance"

    /// Where hooks should point. A Homebrew install uses `<prefix>/bin/agentglance`, which survives
    /// `brew upgrade`; anything else is copied to ~/.local/bin.
    public static func hookBinary(forExecutable path: String) -> (binary: String, needsCopy: Bool) {
        if let cellar = path.range(of: "/Cellar/agentglance/") {
            return (String(path[..<cellar.lowerBound]) + "/bin/agentglance", false)
        }
        return (defaultBinary, path != defaultBinary)
    }
    public static let settingsURL = URL(fileURLWithPath: NSHomeDirectory() + "/.claude/settings.json")

    /// Recognises our entries by the binary path used to install them, or by name for other install paths.
    static func isOurs(_ command: String?, binary: String = defaultBinary) -> Bool {
        guard let command else { return false }
        return [binary, "agentglance"].contains { name in
            command.hasPrefix("\(name) hook") || command.hasPrefix("\(name) statusline") || command.contains("/\(name) hook")
                || command.contains("/\(name) statusline")
        }
    }

    public static func install(into settings: [String: Any], binary: String = defaultBinary) -> [String: Any] {
        var settings = settings
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        let hookCommand = "\(binary) hook"
        for event in hookEvents {
            var present = false
            // Re-point existing entries (e.g. moved from ~/.local/bin to Homebrew) rather than adding duplicates.
            var groups = (hooks[event] as? [[String: Any]] ?? []).map { group -> [String: Any] in
                var group = group
                group["hooks"] = (group["hooks"] as? [[String: Any]] ?? []).map { entry -> [String: Any] in
                    guard isOurs(entry["command"] as? String, binary: binary) else { return entry }
                    present = true
                    var entry = entry
                    entry["command"] = hookCommand
                    return entry
                }
                return group
            }
            if !present {
                groups.append(["hooks": [["type": "command", "command": hookCommand, "timeout": 5]]])
            }
            hooks[event] = groups
        }
        settings["hooks"] = hooks

        var statusLine = settings["statusLine"] as? [String: Any] ?? ["type": "command"]
        var wrapped = statusLine["command"] as? String
        if let current = wrapped, isOurs(current, binary: binary) {
            wrapped = current.range(of: "statusline -- ").map { String(current[$0.upperBound...]) }
        }
        statusLine["command"] = wrapped.map { "\(binary) statusline -- \($0)" } ?? "\(binary) statusline"
        statusLine["type"] = "command"
        settings["statusLine"] = statusLine
        return settings
    }

    public static func uninstall(from settings: [String: Any], binary: String = defaultBinary) -> [String: Any] {
        var settings = settings
        if var hooks = settings["hooks"] as? [String: Any] {
            for (event, value) in hooks {
                guard let groups = value as? [[String: Any]] else { continue }
                let kept: [[String: Any]] = groups.compactMap { group in
                    var group = group
                    let entries = (group["hooks"] as? [[String: Any]] ?? []).filter { !isOurs($0["command"] as? String, binary: binary) }
                    if entries.isEmpty { return nil }
                    group["hooks"] = entries
                    return group
                }
                hooks[event] = kept.isEmpty ? nil : kept
            }
            settings["hooks"] = hooks.isEmpty ? nil : hooks
        }

        if var statusLine = settings["statusLine"] as? [String: Any],
           let command = statusLine["command"] as? String, isOurs(command, binary: binary) {
            if let range = command.range(of: "statusline -- ") {
                statusLine["command"] = String(command[range.upperBound...])
                settings["statusLine"] = statusLine
            } else {
                settings["statusLine"] = nil
            }
        }
        return settings
    }

    /// Human-readable list of what `install`/`uninstall` would change.
    public static func describeChanges(from before: [String: Any], to after: [String: Any],
                                       binary: String = defaultBinary) -> [String] {
        var lines: [String] = []
        let oldHooks = before["hooks"] as? [String: Any] ?? [:], newHooks = after["hooks"] as? [String: Any] ?? [:]
        func ours(_ hooks: [String: Any], _ event: String) -> Bool {
            (hooks[event] as? [[String: Any]] ?? []).contains { group in
                (group["hooks"] as? [[String: Any]] ?? []).contains { isOurs($0["command"] as? String, binary: binary) }
            }
        }
        func commands(_ hooks: [String: Any], _ event: String) -> [String] {
            (hooks[event] as? [[String: Any]] ?? []).flatMap { ($0["hooks"] as? [[String: Any]] ?? []) }
                .compactMap { $0["command"] as? String }.filter { isOurs($0, binary: binary) }
        }
        for event in Set(oldHooks.keys).union(newHooks.keys).sorted() {
            let was = ours(oldHooks, event), now = ours(newHooks, event)
            let oldCmds = commands(oldHooks, event), newCmds = commands(newHooks, event)
            if !was && now { lines.append("+ hooks.\(event): agentglance hook (existing hooks kept)") }
            if was && now && oldCmds != newCmds { lines.append("~ hooks.\(event): \(newCmds.joined()) (moved)") }
            if was && !now { lines.append("- hooks.\(event): agentglance hook") }
        }
        let oldStatus = (before["statusLine"] as? [String: Any])?["command"] as? String
        let newStatus = (after["statusLine"] as? [String: Any])?["command"] as? String
        if oldStatus != newStatus {
            lines.append("~ statusLine.command: \(oldStatus ?? "(none)")")
            lines.append("                   → \(newStatus ?? "(none)")")
        }
        return lines
    }

    public static func loadSettings() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return [:] }
        let data = try Data(contentsOf: settingsURL)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return object
    }

    /// Writes settings after saving a timestamped backup of the current file. Returns the backup path.
    @discardableResult
    public static func saveSettings(_ settings: [String: Any]) throws -> URL? {
        var backup: URL?
        if FileManager.default.fileExists(atPath: settingsURL.path) {
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
            let url = settingsURL.deletingLastPathComponent().appendingPathComponent("settings.json.agentglance-backup-\(stamp)")
            try FileManager.default.copyItem(at: settingsURL, to: url)
            backup = url
        }
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .withoutEscapingSlashes])
        try data.write(to: settingsURL, options: .atomic)
        return backup
    }
}
