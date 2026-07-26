import Foundation

/// Installs the Claude Code hook that lets sessions *push* their state to the
/// Workbench, instead of the sidebar inferring it from transcript shape.
///
/// Two pieces:
///  1. a tiny `/bin/sh` bridge script that writes each hook payload into the
///     Workbench events directory and always exits 0, so it can never block or
///     slow down a Claude session — even if Workbench isn't running;
///  2. entries in `~/.claude/settings.json` pointing the relevant hook events at
///     that script.
///
/// The settings merge is deliberately additive: it appends its own matcher group
/// per event and never touches groups it didn't create, so hooks installed by
/// other tools keep working. A timestamped backup is written before any change.
struct WorkbenchHookInstaller {
    /// Hook events we register. `Stop` and the permission events are the ones that
    /// replace the "is Claude waiting on me?" guesswork; `UserPromptSubmit` gives us
    /// the busy edge. We deliberately skip `PreToolUse`, which would fire on every
    /// single tool call for a marginal gain in resolution.
    static let events = [
        "SessionStart",
        "UserPromptSubmit",
        "Stop",
        "PermissionRequest",
        "Notification",
        "SessionEnd",
    ]

    enum InstallError: LocalizedError {
        case settingsNotJSONObject
        case scriptWriteFailed(String)

        var errorDescription: String? {
            switch self {
            case .settingsNotJSONObject:
                return "~/.claude/settings.json isn't a JSON object, so Workbench won't edit it. Fix or move that file, then try again."
            case .scriptWriteFailed(let detail):
                return "Couldn't write the hook script: \(detail)"
            }
        }
    }

    var claudeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        .appendingPathComponent(".claude", isDirectory: true)
    var eventsDirectory: URL = WorkbenchAgentEventService.defaultDirectory

    var scriptURL: URL {
        claudeDirectory
            .appendingPathComponent("hooks", isDirectory: true)
            .appendingPathComponent("ghostty-workbench-hook.sh")
    }

    var settingsURL: URL { claudeDirectory.appendingPathComponent("settings.json") }

    /// The command string we write into settings.json. Also our install marker: a
    /// hook entry is "ours" iff its command contains the script path.
    var hookCommand: String { "\"\(scriptURL.path)\"" }

    var isInstalled: Bool {
        guard FileManager.default.isExecutableFile(atPath: scriptURL.path),
              let settings = loadSettings(),
              let hooks = settings["hooks"] as? [String: Any]
        else { return false }
        // Installed only when every event we manage is wired up.
        return Self.events.allSatisfy { event in
            guard let groups = hooks[event] as? [[String: Any]] else { return false }
            return groups.contains { groupContainsOurHook($0) }
        }
    }

    // MARK: - Install / uninstall

    func install() throws {
        try writeScript()

        var settings = loadSettings() ?? [:]
        if !settings.isEmpty, JSONSerialization.isValidJSONObject(settings) == false {
            throw InstallError.settingsNotJSONObject
        }
        var hooks = settings["hooks"] as? [String: Any] ?? [:]

        for event in Self.events {
            var groups = hooks[event] as? [[String: Any]] ?? []
            guard !groups.contains(where: { groupContainsOurHook($0) }) else { continue }
            groups.append(ourGroup(for: event))
            hooks[event] = groups
        }

        settings["hooks"] = hooks
        try writeSettings(settings)
    }

    func uninstall() throws {
        guard var settings = loadSettings(),
              var hooks = settings["hooks"] as? [String: Any] else { return }

        for event in Self.events {
            guard var groups = hooks[event] as? [[String: Any]] else { continue }
            // Drop our hook from each group; drop the group if that empties it.
            groups = groups.compactMap { group in
                guard groupContainsOurHook(group) else { return group }
                var group = group
                let remaining = (group["hooks"] as? [[String: Any]] ?? [])
                    .filter { !hookIsOurs($0) }
                if remaining.isEmpty { return nil }
                group["hooks"] = remaining
                return group
            }
            if groups.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = groups }
        }

        if hooks.isEmpty { settings.removeValue(forKey: "hooks") } else { settings["hooks"] = hooks }
        try writeSettings(settings)
        try? FileManager.default.removeItem(at: scriptURL)
    }

    // MARK: - Pieces

    /// A matcher group containing only our hook. `Notification` uses `*` so we
    /// receive every subtype and decide in-app which ones mean "waiting on you".
    private func ourGroup(for event: String) -> [String: Any] {
        var group: [String: Any] = [
            "hooks": [[
                "type": "command",
                "command": hookCommand,
                // Short: the script is a file write. If it ever hangs, Claude
                // shouldn't wait on it.
                "timeout": 5,
            ] as [String: Any]],
        ]
        if event == "Notification" || event == "PermissionRequest" {
            group["matcher"] = "*"
        }
        return group
    }

    private func groupContainsOurHook(_ group: [String: Any]) -> Bool {
        (group["hooks"] as? [[String: Any]] ?? []).contains { hookIsOurs($0) }
    }

    private func hookIsOurs(_ hook: [String: Any]) -> Bool {
        (hook["command"] as? String)?.contains(scriptURL.path) ?? false
    }

    private func writeScript() throws {
        let hooksDirectory = scriptURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: hooksDirectory, withIntermediateDirectories: true)
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        } catch {
            throw InstallError.scriptWriteFailed(error.localizedDescription)
        }
    }

    /// Writes the payload on stdin to a uniquely named file and renames it into
    /// place, so a reader that sees `*.json` always sees a complete event.
    private var script: String {
        """
        #!/bin/sh
        # Ghostty Workbench agent-state bridge — installed by Ghostty Workbench.
        #
        # Claude Code pipes the hook payload (JSON) on stdin. We drop it in the
        # Workbench events directory for the sidebar to pick up, and ALWAYS exit 0
        # so this can never block, slow down, or fail a Claude session. Safe to run
        # when Workbench isn't installed or isn't running.
        DIR="$HOME/Library/Application Support/GhosttyClaudeWorkbench/events"
        mkdir -p "$DIR" 2>/dev/null || exit 0

        # Occasionally sweep events nobody consumed (Workbench not running), so they
        # can't accumulate forever. Cheap: runs for a small fraction of invocations.
        if [ "$(( $$ % 64 ))" -eq 0 ]; then
          find "$DIR" -type f -mmin +60 -delete 2>/dev/null
        fi

        TMP=$(mktemp "$DIR/tmpXXXXXXXX" 2>/dev/null) || exit 0
        cat > "$TMP" 2>/dev/null
        # Atomic publish: readers only look at *.json
        mv "$TMP" "$TMP.json" 2>/dev/null || rm -f "$TMP" 2>/dev/null
        exit 0
        """
    }

    // MARK: - settings.json IO

    private func loadSettings() -> [String: Any]? {
        guard let data = try? Data(contentsOf: settingsURL) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Backs up the current file before overwriting, so a bad merge is recoverable.
    private func writeSettings(_ settings: [String: Any]) throws {
        if let existing = try? Data(contentsOf: settingsURL) {
            let stamp = Int(Date().timeIntervalSince1970)
            let backup = settingsURL.deletingLastPathComponent()
                .appendingPathComponent("settings.json.workbench-backup-\(stamp)")
            try? existing.write(to: backup)
        }
        let data = try JSONSerialization.data(
            withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: settingsURL, options: .atomic)
    }
}
