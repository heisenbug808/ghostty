import Foundation

protocol WorkbenchSessionIndexing: AnyObject {
    func indexedSessions() async throws -> [WorkbenchSessionRecord]
}

/// Filesystem indexer for Claude sessions.
///
/// The session id, project, transcript path, and mtime come from the file
/// layout alone. For a title/cwd/message-count preview we additionally scrape a
/// small, well-known set of JSONL record types (`custom-title`, `ai-title`,
/// `last-prompt`, and the per-message `cwd`). Everything else in the transcript
/// stays opaque, and a scrape failure degrades to the file-layout metadata only.
final class FilesystemClaudeSessionIndexService: WorkbenchSessionIndexing {
    private let fileManager: FileManager
    private let configDirectory: URL
    /// Scrape state per transcript, so re-indexing only reads what's new.
    ///
    /// The active session's transcript is both the largest file here (tens of MB)
    /// and the one that changes constantly, so the file watcher re-indexes it every
    /// time Claude writes a line. Re-reading it whole each time is the difference
    /// between reading a few hundred bytes and rereading 60 MB once a second.
    /// `offset` is the end of the last *complete* line consumed; everything before
    /// it is already folded into `meta`.
    private struct ScrapeState {
        var size: Int
        var mtime: Date
        var offset: UInt64
        var accumulator: Accumulator
        var meta: ScrapedMetadata
    }

    private var scrapeCache: [String: ScrapeState] = [:]

    init(fileManager: FileManager = .default, configDirectory: URL? = nil) {
        self.fileManager = fileManager
        if let configDirectory {
            self.configDirectory = configDirectory
        } else if let override = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !override.isEmpty {
            self.configDirectory = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            self.configDirectory = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent(".claude", isDirectory: true)
        }
    }

    func indexedSessions() async throws -> [WorkbenchSessionRecord] {
        let projectsDirectory = configDirectory.appendingPathComponent("projects", isDirectory: true)
        guard fileManager.fileExists(atPath: projectsDirectory.path) else { return [] }

        let enumerator = fileManager.enumerator(
            at: projectsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        let projectsPath = projectsDirectory.standardizedFileURL.path
        var sessions: [WorkbenchSessionRecord] = []
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "jsonl" else { continue }
            // Only real session transcripts live at projects/<encoded-cwd>/<id>.jsonl.
            // Anything deeper (e.g. <id>/subagents/agent-*.jsonl) is a sidechain, not
            // a resumable session, so skip it.
            guard url.deletingLastPathComponent().deletingLastPathComponent()
                .standardizedFileURL.path == projectsPath else { continue }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            let id = url.deletingPathExtension().lastPathComponent
            guard !id.isEmpty else { continue }

            let projectName = url.deletingLastPathComponent().lastPathComponent
            let projectId = projectName.isEmpty ? "unknown" : projectName
            let meta = scrapeMetadata(at: url, mtime: values?.contentModificationDate)
            sessions.append(WorkbenchSessionRecord(
                id: id,
                projectId: projectId,
                cwd: meta.cwd,
                title: meta.title,
                summary: meta.summary,
                lastModifiedAt: values?.contentModificationDate,
                transcriptPath: url.standardizedFileURL.path,
                messageCount: meta.messageCount,
                lastMessageWasAssistant: meta.lastWasAssistant,
                derivedLabel: meta.derivedLabel,
                status: .indexed
            ))
        }
        return sessions.sorted { ($0.lastModifiedAt ?? .distantPast) > ($1.lastModifiedAt ?? .distantPast) }
    }

    private struct ScrapedMetadata {
        var title: String?
        var summary: String?
        var cwd: String?
        var messageCount: Int?
        /// True when the last conversational line was from the assistant (Claude
        /// replied and is waiting on the user) — drives the "needs review" filter.
        var lastWasAssistant: Bool?
        /// Label derived from the opening prompt, kept separate from a real title.
        var derivedLabel: String?
    }

    /// Raw fields folded out of the transcript, kept separate from the derived
    /// `ScrapedMetadata` so a partial scan can be resumed and finished later.
    /// Every field is incrementally computable: counters add, "last wins" fields
    /// overwrite, and "first wins" fields only fill when still empty.
    private struct Accumulator {
        var customTitle: String?
        var aiTitle: String?
        var lastPrompt: String?
        /// The opening request, which describes what the session is *about* — the
        /// last prompt is usually trailing housekeeping.
        var firstPrompt: String?
        var cwd: String?
        var messages = 0
        var lastWasAssistant: Bool?

        var metadata: ScrapedMetadata {
            ScrapedMetadata(
                // Only Claude Code's own title counts as a title. The label built
                // from the opening request (falling back to the last prompt when a
                // session never had a usable opening one) is reported separately so
                // a generated title can outrank it.
                title: customTitle ?? aiTitle,
                summary: lastPrompt,
                cwd: cwd,
                messageCount: messages > 0 ? messages : nil,
                lastWasAssistant: lastWasAssistant,
                derivedLabel: WorkbenchSessionLabel.label(for: firstPrompt)
                    ?? WorkbenchSessionLabel.label(for: lastPrompt))
        }
    }

    /// Streams the transcript, folding each line into an accumulator.
    ///
    /// Reads only the bytes appended since the last scrape when the file has just
    /// grown, which is the normal case for the session being written to right now.
    /// A file that shrank was rewritten rather than appended to, so it's rescanned
    /// from the start. Lines are decoded from a chunk buffer rather than loading
    /// the file, keeping peak memory flat no matter how large a transcript gets.
    private func scrapeMetadata(at url: URL, mtime: Date?) -> ScrapedMetadata {
        let path = url.standardizedFileURL.path
        let attributes = try? fileManager.attributesOfItem(atPath: path)
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        let cached = scrapeCache[path]

        // Untouched since the last scrape: nothing to do.
        if let cached, let mtime, cached.mtime == mtime, cached.size == size {
            return cached.meta
        }

        let resumable = cached.map { size >= $0.size } ?? false
        var accumulator = resumable ? (cached?.accumulator ?? Accumulator()) : Accumulator()
        var offset: UInt64 = resumable ? (cached?.offset ?? 0) : 0

        guard let handle = FileHandle(forReadingAtPath: path) else { return ScrapedMetadata() }
        defer { try? handle.close() }
        if offset > 0 { try? handle.seek(toOffset: offset) }

        var pending = Data()
        let newline = UInt8(ascii: "\n")
        while true {
            guard let chunk = try? handle.read(upToCount: 1 << 18), !chunk.isEmpty else { break }
            pending.append(chunk)
            while let end = pending.firstIndex(of: newline) {
                let lineData = pending[pending.startIndex..<end]
                let consumed = pending.distance(from: pending.startIndex, to: end) + 1
                pending.removeSubrange(pending.startIndex...end)
                offset += UInt64(consumed)
                if let line = String(data: lineData, encoding: .utf8) {
                    fold(line: line, into: &accumulator)
                }
            }
        }
        // A trailing line with no newline is either the last line of a file that
        // simply doesn't end in one — which must still count — or a line caught
        // mid-write, whose truncated JSON folds to nothing. Either way it's folded
        // into the *returned* result but not into the cached state, and `offset`
        // stops short of it: when the newline arrives the line is read again and
        // folded exactly once.
        var result = accumulator
        if !pending.isEmpty, let line = String(data: pending, encoding: .utf8) {
            fold(line: line, into: &result)
        }

        let meta = result.metadata
        if let mtime {
            scrapeCache[path] = ScrapeState(
                size: size, mtime: mtime, offset: offset, accumulator: accumulator, meta: meta)
        }
        return meta
    }

    /// Substring pre-filter first, JSON-decode only the handful of lines that can
    /// carry the fields we want.
    private func fold(line: String, into accumulator: inout Accumulator) {
        let interesting = line.contains("\"type\"")
            || line.contains("custom-title")
            || line.contains("ai-title")
            || line.contains("last-prompt")
            || (accumulator.cwd == nil && line.contains("\"cwd\""))
        guard
            interesting,
            let lineData = line.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
        else { return }

        switch object["type"] as? String {
        case "user":
            accumulator.messages += 1
            accumulator.lastWasAssistant = false
            // Keep the first prompt the user actually wrote: skip subagent
            // transcripts, injected meta turns, and harness scaffolding.
            if accumulator.firstPrompt == nil,
               object["isSidechain"] as? Bool != true,
               object["isMeta"] as? Bool != true,
               let message = object["message"] as? [String: Any],
               let text = message["content"] as? String,
               !WorkbenchSessionLabel.isScaffolding(text) {
                accumulator.firstPrompt = text
            }
        case "assistant":
            accumulator.messages += 1
            accumulator.lastWasAssistant = true
        case "custom-title":
            accumulator.customTitle = (object["customTitle"] as? String) ?? accumulator.customTitle
        case "ai-title":
            accumulator.aiTitle = (object["aiTitle"] as? String)
                ?? (object["title"] as? String) ?? accumulator.aiTitle
        case "last-prompt":
            accumulator.lastPrompt = (object["lastPrompt"] as? String) ?? accumulator.lastPrompt
        default:
            break
        }
        if accumulator.cwd == nil, let value = object["cwd"] as? String, !value.isEmpty {
            accumulator.cwd = value
        }
    }
}
