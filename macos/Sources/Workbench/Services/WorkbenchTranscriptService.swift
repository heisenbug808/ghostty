import Foundation

/// One readable entry from a Claude session transcript.
struct WorkbenchTranscriptMessage: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case user
        case assistant
        /// A tool the assistant invoked, rendered as a compact one-liner.
        case tool
    }

    var id: Int
    var kind: Kind
    var text: String
    var timestamp: Date?
    /// Set for `.tool` — the tool's name, shown separately from its argument.
    var toolName: String?
}

/// Renders a session's `.jsonl` transcript as something a human can read, so you
/// can see what a session was doing without resuming it.
///
/// The raw file interleaves conversation with a lot of bookkeeping (`mode`,
/// `attachment`, `file-history-snapshot`, …) and with content that isn't part of
/// the conversation you'd want to skim (subagent sidechains, injected meta
/// messages, tool result payloads, the assistant's thinking). We keep the user and
/// assistant turns plus a one-line trace of each tool call.
final class WorkbenchTranscriptService {
    /// Only the most recent messages are kept: transcripts reach thousands of
    /// entries, and the panel shows a tail you scroll, not the whole history.
    static let defaultLimit = 300

    private var cache: (path: String, modified: Date, limit: Int, messages: [WorkbenchTranscriptMessage])?

    /// Loads the tail of a transcript. Cached on (path, mtime, limit) so switching
    /// between sessions and re-rendering doesn't re-read the file.
    func messages(atPath path: String, limit: Int = defaultLimit) -> [WorkbenchTranscriptMessage] {
        let modified = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date
            ?? .distantPast
        if let cache, cache.path == path, cache.modified == modified, cache.limit == limit {
            return cache.messages
        }
        let messages = Self.parse(atPath: path, limit: limit)
        cache = (path, modified, limit, messages)
        return messages
    }

    static func parse(atPath path: String, limit: Int = defaultLimit) -> [WorkbenchTranscriptMessage] {
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return parse(jsonl: contents, limit: limit)
    }

    static func parse(jsonl: String, limit: Int = defaultLimit) -> [WorkbenchTranscriptMessage] {
        var messages: [WorkbenchTranscriptMessage] = []

        for line in jsonl.split(separator: "\n", omittingEmptySubsequences: true) {
            guard
                let data = line.data(using: .utf8),
                let entry = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { continue }

            let type = entry["type"] as? String
            guard type == "user" || type == "assistant" else { continue }
            // Subagent transcripts and injected system messages aren't part of the
            // conversation the user had.
            if entry["isSidechain"] as? Bool == true { continue }
            if entry["isMeta"] as? Bool == true { continue }

            guard let message = entry["message"] as? [String: Any] else { continue }
            let isAssistant = (message["role"] as? String ?? type) == "assistant"
            let timestamp = (entry["timestamp"] as? String).flatMap(Self.parseTimestamp)

            for (kind, text, toolName) in Self.parts(from: message["content"], isAssistant: isAssistant) {
                messages.append(WorkbenchTranscriptMessage(
                    id: messages.count,
                    kind: kind,
                    text: text,
                    timestamp: timestamp,
                    toolName: toolName))
            }

            // Bound memory on huge transcripts: keep a rolling tail rather than
            // materializing thousands of entries and trimming at the end.
            if messages.count > limit * 2 {
                messages = Array(messages.suffix(limit))
            }
        }

        let tail = messages.suffix(limit)
        // Renumber so ids stay contiguous and stable for SwiftUI identity.
        return tail.enumerated().map { index, message in
            var message = message
            message.id = index
            return message
        }
    }

    /// Flattens one message's content into renderable parts.
    private static func parts(
        from content: Any?,
        isAssistant: Bool
    ) -> [(WorkbenchTranscriptMessage.Kind, String, String?)] {
        let ownKind: WorkbenchTranscriptMessage.Kind = isAssistant ? .assistant : .user

        if let text = content as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : [(ownKind, trimmed, nil)]
        }

        guard let blocks = content as? [[String: Any]] else { return [] }
        var parts: [(WorkbenchTranscriptMessage.Kind, String, String?)] = []
        for block in blocks {
            switch block["type"] as? String {
            case "text":
                let text = (block["text"] as? String ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { parts.append((ownKind, text, nil)) }
            case "tool_use":
                let name = block["name"] as? String ?? "tool"
                parts.append((.tool, toolSummary(name: name, input: block["input"]), name))
            case "image":
                parts.append((ownKind, "[image]", nil))
            default:
                // `thinking` (internal reasoning) and `tool_result` (raw payloads,
                // often huge) are deliberately not part of a readable transcript.
                continue
            }
        }
        return parts
    }

    /// A short, recognizable argument for a tool call — the file for edits, the
    /// command for Bash, and so on.
    private static func toolSummary(name: String, input: Any?) -> String {
        guard let input = input as? [String: Any] else { return "" }
        let preferredKeys = ["command", "file_path", "path", "pattern", "query", "url", "prompt", "description"]
        let value = preferredKeys.compactMap { input[$0] as? String }.first
            ?? input.values.compactMap { $0 as? String }.first
            ?? ""
        let collapsed = value
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return collapsed.count > 120 ? String(collapsed.prefix(120)) + "…" : collapsed
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let iso: ISO8601DateFormatter = ISO8601DateFormatter()

    private static func parseTimestamp(_ value: String) -> Date? {
        isoFractional.date(from: value) ?? iso.date(from: value)
    }
}
