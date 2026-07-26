import Foundation

/// What a Claude session's agent is doing, as reported by the Claude Code hook.
///
/// This is *pushed* truth, unlike the transcript-shape heuristics we fall back to
/// when a session has no hook data (e.g. it predates hook installation).
enum WorkbenchAgentState: String, Codable, Sendable {
    /// The user submitted a prompt / a tool is running — Claude is busy.
    case working
    /// Claude finished its turn and is waiting on the user.
    case idle
    /// Claude is blocked on a permission prompt or other user input.
    case awaitingInput
    /// The session exited.
    case ended

    var isWaitingOnUser: Bool { self == .idle || self == .awaitingInput }
}

/// One hook payload written by the bridge script.
///
/// Claude Code passes a JSON object on stdin containing at least `session_id` and
/// `hook_event_name`; everything else is event-specific and treated as optional so
/// a Claude Code version that adds/renames fields can't break parsing.
struct WorkbenchAgentEvent: Sendable {
    var sessionId: String
    var event: String
    var cwd: String?
    /// `Notification` subtype, e.g. `permission_prompt` / `idle_prompt`.
    var notificationType: String?
    /// `SessionStart` source (startup/resume/clear/compact/fork).
    var source: String?
    /// `SessionEnd` reason.
    var reason: String?
    var receivedAt: Date

    /// The state this event implies, or nil if the event isn't state-bearing.
    var state: WorkbenchAgentState? {
        switch event {
        case "UserPromptSubmit", "PreToolUse", "SessionStart":
            return .working
        case "Stop":
            return .idle
        case "PermissionRequest":
            return .awaitingInput
        case "Notification":
            // Only these subtypes mean "Claude can't continue without you".
            switch notificationType {
            case "permission_prompt", "elicitation_dialog", "agent_needs_input":
                return .awaitingInput
            case "idle_prompt":
                return .idle
            default:
                return nil
            }
        case "SessionEnd":
            return .ended
        default:
            return nil
        }
    }
}

/// Reads (and consumes) hook events dropped by the bridge script.
///
/// The bridge writes one JSON file per event and renames it into place, so a file
/// ending in `.json` is always complete. We delete each file after reading it, so
/// every event is delivered once. Files that pile up while the app isn't running
/// are pruned by age so a long absence can't produce a burst of stale notifications.
final class WorkbenchAgentEventService {
    /// Events older than this are dropped rather than acted on.
    static let maxEventAge: TimeInterval = 5 * 60
    /// Safety valve so a runaway hook can't make us read unbounded files at once.
    static let maxEventsPerDrain = 200

    let directory: URL
    private let fileManager: FileManager

    init(directory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.directory = directory ?? Self.defaultDirectory
    }

    /// `~/Library/Application Support/GhosttyClaudeWorkbench/events` — alongside the
    /// Workbench store. The bridge script derives the same path from `$HOME`.
    static var defaultDirectory: URL {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return appSupport
            .appendingPathComponent("GhosttyClaudeWorkbench", isDirectory: true)
            .appendingPathComponent("events", isDirectory: true)
    }

    func ensureDirectoryExists() {
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Reads and deletes all pending events, newest-last so later events win when
    /// several arrive for the same session.
    func drain() -> [WorkbenchAgentEvent] {
        let urls = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        let now = Date()
        var events: [WorkbenchAgentEvent] = []
        for url in urls.prefix(Self.maxEventsPerDrain) where url.pathExtension == "json" {
            defer { try? fileManager.removeItem(at: url) }

            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? now
            guard now.timeIntervalSince(modified) <= Self.maxEventAge else { continue }
            guard
                let data = try? Data(contentsOf: url),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let sessionId = object["session_id"] as? String, !sessionId.isEmpty,
                let event = object["hook_event_name"] as? String
            else { continue }

            events.append(WorkbenchAgentEvent(
                sessionId: sessionId,
                event: event,
                cwd: object["cwd"] as? String,
                notificationType: object["notification_type"] as? String,
                source: object["source"] as? String,
                reason: object["reason"] as? String,
                receivedAt: modified
            ))
        }
        return events.sorted { $0.receivedAt < $1.receivedAt }
    }
}
