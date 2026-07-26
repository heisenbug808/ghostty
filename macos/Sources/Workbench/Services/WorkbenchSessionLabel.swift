import Foundation

/// Turns a raw user prompt into something recognizable in a session list.
///
/// Two thirds of sessions have no title from Claude Code, so the list falls back
/// to a prompt. Raw prompts make poor labels for two reasons:
///
///  - The *last* prompt is usually housekeeping ("commit 并开pr"), not what the
///    session was about, so the index prefers the first substantive one.
///  - Prompts often open with a ticket URL, which pushes the actual request out
///    of a narrow row. The ticket id is the memorable part, so it gets hoisted to
///    the front and the URL is dropped.
///
/// Prompts also frequently begin with harness scaffolding (`<local-command-…>`,
/// `<command-name>`, caveat banners) that the user never typed; those aren't
/// labels at all and are rejected outright.
enum WorkbenchSessionLabel {
    /// Plain-text markers that mean "this text is scaffolding, not a user request".
    private static let scaffolding = [
        "Caveat: The messages below were generated",
    ]

    /// Harness scaffolding arrives as pseudo-XML at the very start of the message —
    /// slash-command echoes, local command output, background task notifications,
    /// injected reminders. Matching the family by shape rather than listing every
    /// tag means a newly introduced one doesn't silently become a session title.
    /// Deliberately narrow: a prompt that opens with `<div>` or `<html>` is real
    /// pasted content and still counts.
    private static let scaffoldingTagPattern =
        "^<(command|local-command|bash|task|system|ide|user-prompt|assistant)[a-z-]*[>\\s]"

    static let maxLength = 72

    /// True when a prompt is scaffolding rather than something the user wrote.
    static func isScaffolding(_ prompt: String) -> Bool {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        if firstMatch(pattern: scaffoldingTagPattern, in: trimmed, group: 0) != nil { return true }
        // Check a prefix window rather than the whole string: a real prompt can
        // legitimately quote one of these markers further in.
        let head = String(trimmed.prefix(160))
        return scaffolding.contains { head.localizedCaseInsensitiveContains($0) }
    }

    /// A short label for a prompt, or nil if there's nothing usable in it.
    static func label(for prompt: String?) -> String? {
        guard let prompt, !isScaffolding(prompt) else { return nil }

        let reference = self.reference(in: prompt)
        var body = prompt
        // Drop URLs: whatever mattered in them is now in `reference`, and a bare
        // URL crowds out the request in a narrow row.
        body = replacing(pattern: "https?://[^\\s]+", in: body, with: " ")
        body = body
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        body = replacing(pattern: " {2,}", in: body, with: " ")
        body = body.trimmingCharacters(in: CharacterSet(charactersIn: " \t·-—:;,.、。：；"))

        // A ticket id already at the front would otherwise be repeated by the
        // hoisted reference.
        if let reference, body.hasPrefix(reference) {
            body = String(body.dropFirst(reference.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: " \t·-—:;,.、。：；"))
        }

        switch (reference, body.isEmpty) {
        case (let reference?, true): return truncate(reference)
        case (let reference?, false): return truncate("\(reference) · \(body)")
        case (nil, false): return truncate(body)
        case (nil, true): return nil
        }
    }

    /// The memorable identifier in a prompt: a ticket key like `CS-63034`, or a
    /// GitHub pull/issue rendered as `repo#123`.
    private static func reference(in prompt: String) -> String? {
        if let ticket = firstMatch(pattern: "\\b[A-Z]{2,}-[0-9]{2,}\\b", in: prompt, group: 0) {
            return ticket
        }
        let github = "github\\.com/[^/\\s]+/([^/\\s]+)/(?:pull|issues)/([0-9]+)"
        if let repo = firstMatch(pattern: github, in: prompt, group: 1),
           let number = firstMatch(pattern: github, in: prompt, group: 2) {
            return "\(repo)#\(number)"
        }
        return nil
    }

    private static func truncate(_ value: String) -> String {
        guard value.count > maxLength else { return value }
        return String(value.prefix(maxLength)).trimmingCharacters(in: .whitespaces) + "…"
    }

    // MARK: - Regex helpers

    private static var cache: [String: NSRegularExpression] = [:]

    private static func regex(_ pattern: String) -> NSRegularExpression? {
        if let cached = cache[pattern] { return cached }
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        cache[pattern] = expression
        return expression
    }

    private static func firstMatch(pattern: String, in value: String, group: Int) -> String? {
        guard let expression = regex(pattern) else { return nil }
        let range = NSRange(value.startIndex..., in: value)
        guard
            let match = expression.firstMatch(in: value, range: range),
            group < match.numberOfRanges,
            let matched = Range(match.range(at: group), in: value)
        else { return nil }
        return String(value[matched])
    }

    private static func replacing(pattern: String, in value: String, with template: String) -> String {
        guard let expression = regex(pattern) else { return value }
        return expression.stringByReplacingMatches(
            in: value,
            range: NSRange(value.startIndex..., in: value),
            withTemplate: template)
    }
}
