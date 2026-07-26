import Foundation

/// Names a session by asking Claude to read the start of its transcript.
///
/// Labels derived mechanically from the opening prompt are recognizable but often
/// verbose or, when a session opened with housekeeping, unhelpful. Asking Claude
/// for a few words turns
///
///   PE-11318 · 你看一下这个 关于 internal console 的 customer success dashboard该怎么做 你…
///
/// into `PE-11318 customer success dashboard plan`.
///
/// This costs tokens and takes seconds per session, so it never runs on its own —
/// only when explicitly asked for.
final class WorkbenchTitleGeneratorService {
    /// Conversational turns fed to the model. The task is stated at the start of a
    /// session, so the opening is what identifies it.
    static let excerptTurns = 10
    /// Per-turn character budget, to keep the prompt small.
    private static let turnLimit = 260
    /// A title longer than this isn't a label any more.
    private static let maxTitleLength = 60
    private static let timeout: TimeInterval = 90

    enum GenerationError: LocalizedError {
        case claudeUnavailable
        case emptyResponse

        var errorDescription: String? {
            switch self {
            case .claudeUnavailable:
                return "Couldn't run the claude CLI. Make sure it works in your shell."
            case .emptyResponse:
                return "Claude returned no title."
            }
        }
    }

    /// Generates a title from a transcript, or nil when there's nothing to read.
    func title(forTranscriptAt path: String) async throws -> String? {
        guard let excerpt = Self.excerpt(atPath: path), !excerpt.isEmpty else { return nil }
        let output = try await Self.runClaude(prompt: Self.prompt(for: excerpt))
        return Self.sanitize(output)
    }

    // MARK: - Excerpt

    /// The first few conversational turns, streamed so a large transcript isn't
    /// loaded to read its beginning.
    static func excerpt(atPath path: String, turns: Int = excerptTurns) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }

        var lines: [String] = []
        var pending = Data()
        let newline = UInt8(ascii: "\n")

        while lines.count < turns {
            guard let chunk = try? handle.read(upToCount: 1 << 16), !chunk.isEmpty else { break }
            pending.append(chunk)
            while lines.count < turns, let end = pending.firstIndex(of: newline) {
                let lineData = pending[pending.startIndex..<end]
                pending.removeSubrange(pending.startIndex...end)
                guard
                    let line = String(data: lineData, encoding: .utf8),
                    let turn = Self.turn(in: line)
                else { continue }
                lines.append(turn)
            }
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// One `Role: text` line, or nil for anything that isn't conversation.
    private static func turn(in line: String) -> String? {
        guard
            let data = line.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let type = object["type"] as? String,
            type == "user" || type == "assistant",
            object["isSidechain"] as? Bool != true,
            object["isMeta"] as? Bool != true,
            let message = object["message"] as? [String: Any]
        else { return nil }

        var text: String?
        if let content = message["content"] as? String {
            text = content
        } else if let blocks = message["content"] as? [[String: Any]] {
            let texts = blocks.compactMap { block -> String? in
                guard block["type"] as? String == "text" else { return nil }
                return block["text"] as? String
            }
            text = texts.isEmpty ? nil : texts.joined(separator: " ")
        }

        guard var body = text?.trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty,
              !WorkbenchSessionLabel.isScaffolding(body)
        else { return nil }

        body = body.replacingOccurrences(of: "\n", with: " ")
        if body.count > turnLimit { body = String(body.prefix(turnLimit)) }
        return "\(type == "user" ? "User" : "Claude"): \(body)"
    }

    private static func prompt(for excerpt: String) -> String {
        """
        Below is the beginning of a coding session transcript. Reply with ONLY a \
        3-6 word title naming the concrete task. No quotes, no trailing \
        punctuation, no preamble. Include a ticket id or component name if one \
        appears. Match the language of the request.

        \(excerpt)
        """
    }

    // MARK: - Running claude

    /// Runs `claude -p` with the prompt on stdin.
    ///
    /// Through a login shell because a GUI-launched app has launchd's minimal PATH,
    /// and from a neutral working directory so the CLI doesn't load a project's
    /// CLAUDE.md and answer from that context instead of the transcript.
    private static func runClaude(prompt: String) async throws -> String {
        let process = Process()
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-c", "claude -p"]
        process.currentDirectoryURL = FileManager.default.temporaryDirectory

        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw GenerationError.claudeUnavailable
        }

        try? input.fileHandleForWriting.write(contentsOf: Data(prompt.utf8))
        try? input.fileHandleForWriting.close()

        // Read on a background thread; a full pipe buffer would otherwise deadlock
        // a process we're also waiting on.
        let data = await withCheckedContinuation { (continuation: CheckedContinuation<Data, Never>) in
            DispatchQueue.global(qos: .utility).async {
                let data = (try? output.fileHandleForReading.readToEnd()) ?? Data()
                continuation.resume(returning: data)
            }
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if Task.isCancelled { break }
        }
        if process.isRunning { process.terminate() }

        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            throw GenerationError.emptyResponse
        }
        return text
    }

    /// Keeps the first non-empty line and strips the ways a model tends to dress up
    /// a one-line answer.
    static func sanitize(_ output: String) -> String? {
        guard let first = output
            .split(separator: "\n")
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { !$0.isEmpty })
        else { return nil }

        var title = first.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`*#—-–:.。、 "))
        // A refusal or an explanation isn't a title.
        guard !title.isEmpty, title.count <= maxTitleLength * 2 else { return nil }
        if title.count > maxTitleLength { title = String(title.prefix(maxTitleLength)) }
        return title.trimmingCharacters(in: .whitespaces)
    }
}
