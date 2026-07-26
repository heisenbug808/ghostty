import Foundation

/// Live process info for a Claude session.
///
/// Claude Code writes one `~/.claude/sessions/<pid>.json` file per running
/// process, each carrying `pid`, `sessionId`, and `cwd`. We read those as the
/// authoritative pid<->session<->cwd map. Read-only: this never writes to
/// `~/.claude`, and it treats a file's presence as "live" only after verifying
/// the PID is still alive.
struct WorkbenchRunningInfo: Sendable, Hashable {
    var pid: Int32
    var sessionId: String
    var cwd: String?
    var entrypoint: String?
    var name: String?
    /// Epoch millis the process started; used to prefer the newest launch when a
    /// stale crashed-PID file and the live file both carry the same sessionId.
    var startedAt: Double
}

protocol WorkbenchRunningStateReading: AnyObject {
    /// sessionId -> running info, for processes that are currently alive.
    func runningSessions() async throws -> [String: WorkbenchRunningInfo]
}

final class FilesystemRunningStateService: WorkbenchRunningStateReading {
    private let fileManager: FileManager
    private let sessionsDirectory: URL

    init(fileManager: FileManager = .default, configDirectory: URL? = nil) {
        self.fileManager = fileManager
        let base: URL
        if let configDirectory {
            base = configDirectory
        } else if let override = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !override.isEmpty {
            base = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            base = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent(".claude", isDirectory: true)
        }
        self.sessionsDirectory = base.appendingPathComponent("sessions", isDirectory: true)
    }

    func runningSessions() async throws -> [String: WorkbenchRunningInfo] {
        let entries = (try? fileManager.contentsOfDirectory(
            at: sessionsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        var result: [String: WorkbenchRunningInfo] = [:]
        for url in entries where url.pathExtension == "json" {
            guard
                let data = try? Data(contentsOf: url),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let pidValue = object["pid"] as? Int,
                let sessionId = object["sessionId"] as? String, !sessionId.isEmpty
            else { continue }

            let pid = Int32(truncatingIfNeeded: pidValue)
            guard Self.isProcessAlive(pid) else { continue }

            let startedAt = (object["startedAt"] as? NSNumber)?.doubleValue ?? 0
            // If the same session id appears twice (a lingering crashed-PID file
            // plus the live one), keep the most recently started process.
            if let existing = result[sessionId], existing.startedAt >= startedAt { continue }
            result[sessionId] = WorkbenchRunningInfo(
                pid: pid,
                sessionId: sessionId,
                cwd: object["cwd"] as? String,
                entrypoint: object["entrypoint"] as? String,
                name: object["name"] as? String,
                startedAt: startedAt
            )
        }
        return result
    }

    /// `kill(pid, 0)` is a no-op existence probe: success means the process is
    /// alive; `EPERM` means it exists but is owned by another user.
    static func isProcessAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    /// Ends a session's process. `SIGTERM` lets Claude Code shut down cleanly
    /// (flush the transcript, release its daemon socket); `force` sends `SIGKILL`
    /// as the fallback for a process that ignores `SIGTERM`. Works for detached /
    /// background sessions too, since it targets the PID directly rather than a
    /// terminal window.
    @discardableResult
    static func terminate(_ pid: Int32, force: Bool = false) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, force ? SIGKILL : SIGTERM) == 0
    }
}
