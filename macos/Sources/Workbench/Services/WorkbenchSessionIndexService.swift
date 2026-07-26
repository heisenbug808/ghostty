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
    // Cache scraped metadata by path, keyed on mtime, so a re-index (e.g. from the
    // auto-refresh file watcher firing while a transcript is being written) only
    // re-reads the handful of files that actually changed.
    private var scrapeCache: [String: (mtime: Date, meta: ScrapedMetadata)] = [:]

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
    }

    /// Cheap single-pass scrape: substring pre-filter first, JSON-decode only the
    /// handful of lines that can carry the fields we want. `cwd` is stable per
    /// session, so we stop probing for it once found; titles use last-wins.
    private func scrapeMetadata(at url: URL, mtime: Date?) -> ScrapedMetadata {
        let path = url.standardizedFileURL.path
        if let mtime, let cached = scrapeCache[path], cached.mtime == mtime {
            return cached.meta
        }
        guard
            let data = try? Data(contentsOf: url),
            let contents = String(data: data, encoding: .utf8)
        else { return ScrapedMetadata() }

        var customTitle: String?
        var aiTitle: String?
        var lastPrompt: String?
        var cwd: String?
        var messages = 0
        var lastWasAssistant: Bool?

        contents.enumerateLines { line, _ in
            let interesting = line.contains("\"type\"")
                || line.contains("custom-title")
                || line.contains("ai-title")
                || line.contains("last-prompt")
                || (cwd == nil && line.contains("\"cwd\""))
            guard
                interesting,
                let lineData = line.data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else { return }

            switch object["type"] as? String {
            case "user": messages += 1; lastWasAssistant = false
            case "assistant": messages += 1; lastWasAssistant = true
            case "custom-title": customTitle = (object["customTitle"] as? String) ?? customTitle
            case "ai-title": aiTitle = (object["aiTitle"] as? String) ?? (object["title"] as? String) ?? aiTitle
            case "last-prompt": lastPrompt = (object["lastPrompt"] as? String) ?? lastPrompt
            default: break
            }
            if cwd == nil, let value = object["cwd"] as? String, !value.isEmpty {
                cwd = value
            }
        }

        let meta = ScrapedMetadata(
            title: customTitle ?? aiTitle,
            summary: lastPrompt,
            cwd: cwd,
            messageCount: messages > 0 ? messages : nil,
            lastWasAssistant: lastWasAssistant
        )
        if let mtime { scrapeCache[path] = (mtime, meta) }
        return meta
    }
}
