import Foundation

/// A session whose transcript contains the search query.
struct WorkbenchTranscriptHit: Identifiable, Hashable, Sendable {
    var sessionId: String
    /// Text around the first match, for showing what was found.
    var snippet: String
    /// Matches found in this transcript, capped — enough to rank, not to count.
    var matchCount: Int

    var id: String { sessionId }
}

/// Searches *inside* transcripts, so a session can be found by what was discussed
/// in it rather than only by its title.
///
/// Titles only get you so far with dozens of sessions; "the one where I looked at
/// the stuck referrals" is a content question. The corpus here is a couple hundred
/// megabytes across ~80 files with individual transcripts up to ~60 MB, so this:
///
///  - streams each file line by line instead of loading it, keeping peak memory
///    flat regardless of transcript size;
///  - tests each raw line with a cheap substring check and only parses JSON for
///    the lines that actually match, since parsing every line would dominate;
///  - scans newest-first and stops at a result cap, because the session you're
///    reaching for is far more often recent;
///  - checks for cancellation continuously, so each keystroke abandons the
///    previous scan instead of queueing another full pass.
final class WorkbenchTranscriptSearchService {
    /// Stop after this many matching sessions.
    static let defaultSessionLimit = 25
    /// Stop counting matches within one transcript at this point.
    private static let perFileMatchCap = 50
    /// How many files to scan at once.
    private static let concurrency = 4

    struct Target: Sendable {
        var sessionId: String
        var path: String
        /// Used to scan the most recently touched transcripts first.
        var modifiedAt: Date
    }

    /// Returns sessions whose transcripts contain `query`. Throws
    /// `CancellationError` if the enclosing task is cancelled.
    func search(
        query: String,
        in targets: [Target],
        limit: Int = defaultSessionLimit
    ) async throws -> [WorkbenchTranscriptHit] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2 else { return [] }

        let ordered = targets.sorted { $0.modifiedAt > $1.modifiedAt }
        var hits: [WorkbenchTranscriptHit] = []
        var index = 0

        // Hand-rolled bounded concurrency: a plain task group over 80 files would
        // start 80 concurrent file reads and thrash.
        try await withThrowingTaskGroup(of: WorkbenchTranscriptHit?.self) { group in
            func addNext() {
                guard index < ordered.count else { return }
                let target = ordered[index]
                index += 1
                group.addTask { Self.scan(target: target, query: query) }
            }

            for _ in 0..<min(Self.concurrency, ordered.count) { addNext() }

            while let result = try await group.next() {
                try Task.checkCancellation()
                if let result { hits.append(result) }
                if hits.count >= limit {
                    group.cancelAll()
                    break
                }
                addNext()
            }
        }

        // Most matches first, then most recent, so the ordering is stable.
        let recency = Dictionary(ordered.map { ($0.sessionId, $0.modifiedAt) },
                                 uniquingKeysWith: { first, _ in first })
        return hits.sorted {
            $0.matchCount != $1.matchCount
                ? $0.matchCount > $1.matchCount
                : (recency[$0.sessionId] ?? .distantPast) > (recency[$1.sessionId] ?? .distantPast)
        }
    }

    /// Scans one transcript. Returns nil when the query isn't in it.
    private static func scan(target: Target, query: String) -> WorkbenchTranscriptHit? {
        guard let file = FileHandle(forReadingAtPath: target.path) else { return nil }
        defer { try? file.close() }

        var matches = 0
        var snippet: String?
        var pending = Data()
        let newline = UInt8(ascii: "\n")

        while !Task.isCancelled {
            guard
                let chunk = try? file.read(upToCount: 1 << 18),
                !chunk.isEmpty
            else { break }
            pending.append(chunk)

            // Process whole lines only; a partial trailing line waits for the next
            // chunk so a match spanning a chunk boundary isn't missed.
            while let end = pending.firstIndex(of: newline) {
                let lineData = pending[pending.startIndex..<end]
                pending.removeSubrange(pending.startIndex...end)
                guard let line = String(data: lineData, encoding: .utf8) else { continue }
                guard line.localizedCaseInsensitiveContains(query) else { continue }
                matches += 1
                if snippet == nil { snippet = Self.snippet(from: line, query: query) }
                if matches >= perFileMatchCap { break }
            }
            if matches >= perFileMatchCap { break }
        }

        // Trailing line without a newline.
        if matches < perFileMatchCap,
           let line = String(data: pending, encoding: .utf8),
           line.localizedCaseInsensitiveContains(query) {
            matches += 1
            if snippet == nil { snippet = Self.snippet(from: line, query: query) }
        }

        guard matches > 0, !Task.isCancelled else { return nil }
        return WorkbenchTranscriptHit(
            sessionId: target.sessionId,
            snippet: snippet ?? "",
            matchCount: matches)
    }

    /// Readable context around the match: prefers the conversational text of the
    /// entry, falling back to the raw line when it isn't a message.
    private static func snippet(from line: String, query: String) -> String {
        let haystack = Self.messageText(in: line) ?? line
        let source = haystack.localizedCaseInsensitiveContains(query) ? haystack : line

        let flattened = source
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        guard let range = flattened.range(of: query, options: [.caseInsensitive]) else {
            return String(flattened.prefix(160))
        }

        let window = 60
        let start = flattened.index(
            range.lowerBound,
            offsetBy: -min(window, flattened.distance(from: flattened.startIndex, to: range.lowerBound)))
        let end = flattened.index(
            range.upperBound,
            offsetBy: min(window, flattened.distance(from: range.upperBound, to: flattened.endIndex)))

        var result = String(flattened[start..<end]).trimmingCharacters(in: .whitespaces)
        if start != flattened.startIndex { result = "…" + result }
        if end != flattened.endIndex { result += "…" }
        return result
    }

    /// Pulls readable text out of a transcript line, so snippets read as prose
    /// instead of JSON.
    ///
    /// Matches land in tool results and tool arguments at least as often as in
    /// conversation — searching for a ticket id usually hits the payload an API
    /// returned — so those are unwrapped too rather than falling back to the raw
    /// line, which would show the reader escaped JSON.
    private static func messageText(in line: String) -> String? {
        guard
            let data = line.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let message = object["message"] as? [String: Any]
        else { return nil }

        if let text = message["content"] as? String { return text }
        guard let blocks = message["content"] as? [[String: Any]] else { return nil }

        let texts = blocks.compactMap { block -> String? in
            switch block["type"] as? String {
            case "text":
                return block["text"] as? String
            case "tool_result":
                return flatten(block["content"])
            case "tool_use":
                // Argument values only; the keys are noise in a snippet.
                guard let input = block["input"] as? [String: Any] else { return nil }
                return input.values.compactMap { $0 as? String }.joined(separator: " ")
            default:
                return nil
            }
        }
        let joined = texts.joined(separator: " ")
        return joined.isEmpty ? nil : joined
    }

    /// Tool results carry either a string or an array of content blocks.
    private static func flatten(_ content: Any?) -> String? {
        if let text = content as? String { return text }
        guard let blocks = content as? [[String: Any]] else { return nil }
        let texts = blocks.compactMap { $0["text"] as? String }
        return texts.isEmpty ? nil : texts.joined(separator: " ")
    }
}
