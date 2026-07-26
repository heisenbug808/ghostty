import Foundation

enum WorkbenchSessionStatus: String, Codable, CaseIterable, Sendable {
    case indexed
    case idle
    case launching
    case running
    case failed
    case archived
    case unknown
}

struct WorkbenchProjectRecord: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var name: String
    var path: String?
    var createdAt: Date
    var updatedAt: Date

    init(id: String = UUID().uuidString, name: String, path: String? = nil, createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.path = path
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Subsequence fuzzy matcher for the sidebar's quick-open search — so typing
/// "pmrsf" finds "partner-prm-search-filters". Returns a score (higher = better,
/// rewarding contiguous runs and word-boundary hits) or nil when it doesn't match.
enum WorkbenchFuzzy {
    static func score(query: String, in text: String) -> Int? {
        guard !query.isEmpty else { return 0 }
        let q = Array(query.lowercased())
        let t = Array(text.lowercased())
        var qi = 0, score = 0, run = 0, ti = 0
        while ti < t.count && qi < q.count {
            if t[ti] == q[qi] {
                run += 1
                score += 1 + run
                if ti == 0 || "/ -_.".contains(t[ti - 1]) { score += 3 } // word boundary
                qi += 1
            } else {
                run = 0
            }
            ti += 1
        }
        return qi == q.count ? score : nil
    }

    /// Best score across a session's searchable fields, or nil if none match.
    static func score(query: String, session: WorkbenchSessionRecord) -> Int? {
        [session.displayTitle, session.cwd ?? "", session.id]
            .compactMap { score(query: query, in: $0) }
            .max()
    }
}

/// Sidebar session filter. `all` hides archived; `archived` shows only archived.
enum WorkbenchSessionFilter: String, CaseIterable, Sendable {
    case all, running, needsReview, favorite, archived

    var label: String {
        switch self {
        case .all: return "All"
        case .running: return "Running"
        case .needsReview: return "Needs review"
        case .favorite: return "Favorites"
        case .archived: return "Archived"
        }
    }

    var systemImage: String {
        switch self {
        case .all: return "tray.full"
        case .running: return "play.circle"
        case .needsReview: return "exclamationmark.bubble"
        case .favorite: return "pin"
        case .archived: return "archivebox"
        }
    }

    func matches(_ session: WorkbenchSessionRecord) -> Bool {
        switch self {
        case .all: return !session.isArchived
        case .running: return session.status == .running && !session.isArchived
        case .needsReview: return session.needsReview
        case .favorite: return session.isPinned && !session.isArchived
        case .archived: return session.isArchived
        }
    }
}

struct WorkbenchSessionRecord: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var projectId: String?
    var cwd: String?

    // Claude-owned / index-owned fields. These can be rebuilt from Claude metadata.
    var title: String?
    var summary: String?
    var lastModifiedAt: Date?
    var transcriptPath: String?
    var messageCount: Int?
    /// True when the last conversational message was the assistant's (Claude is
    /// waiting on the user). Drives `needsReview`.
    var lastMessageWasAssistant: Bool?
    /// Label built from the opening prompt when Claude Code never titled the
    /// session. Index-owned and ranked below a real title.
    var derivedLabel: String?
    var forkedFromSessionId: String?

    // Workbench-owned fields. Index refresh must never overwrite these.
    var localTitle: String?
    /// Title produced on request by asking Claude to name the session. Ranked
    /// below the user's own rename and below Claude Code's own title, but above
    /// the mechanically derived label.
    var generatedTitle: String?
    var isPinned: Bool
    var isArchived: Bool
    var tags: [String]

    // Runtime fields.
    var status: WorkbenchSessionStatus
    /// Last state the Claude Code hook reported for this session, if the hook is
    /// installed. Authoritative — see `needsReview`.
    var agentState: WorkbenchAgentState?
    var agentStateAt: Date?
    var lastLaunchId: String?
    var runningPID: Int32?
    var lastExitCode: Int32?
    var lastError: String?
    var createdByWorkbench: Bool
    var createdAt: Date
    var updatedAt: Date

    init(
        id: String,
        projectId: String? = nil,
        cwd: String? = nil,
        title: String? = nil,
        summary: String? = nil,
        lastModifiedAt: Date? = nil,
        transcriptPath: String? = nil,
        messageCount: Int? = nil,
        lastMessageWasAssistant: Bool? = nil,
        derivedLabel: String? = nil,
        forkedFromSessionId: String? = nil,
        localTitle: String? = nil,
        generatedTitle: String? = nil,
        isPinned: Bool = false,
        isArchived: Bool = false,
        tags: [String] = [],
        status: WorkbenchSessionStatus = .indexed,
        agentState: WorkbenchAgentState? = nil,
        agentStateAt: Date? = nil,
        lastLaunchId: String? = nil,
        runningPID: Int32? = nil,
        lastExitCode: Int32? = nil,
        lastError: String? = nil,
        createdByWorkbench: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.projectId = projectId
        self.cwd = cwd
        self.title = title
        self.summary = summary
        self.lastModifiedAt = lastModifiedAt
        self.transcriptPath = transcriptPath
        self.messageCount = messageCount
        self.lastMessageWasAssistant = lastMessageWasAssistant
        self.derivedLabel = derivedLabel
        self.forkedFromSessionId = forkedFromSessionId
        self.localTitle = localTitle
        self.generatedTitle = generatedTitle
        self.isPinned = isPinned
        self.isArchived = isArchived
        self.tags = tags
        self.status = status
        self.agentState = agentState
        self.agentStateAt = agentStateAt
        self.lastLaunchId = lastLaunchId
        self.runningPID = runningPID
        self.lastExitCode = lastExitCode
        self.lastError = lastError
        self.createdByWorkbench = createdByWorkbench
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// What the list shows, most authoritative first: the user's own name for it,
    /// then Claude Code's title, then a generated one, then the label derived from
    /// the opening prompt, and only then raw prompt text.
    var displayTitle: String {
        if let localTitle, !localTitle.isEmpty { return localTitle }
        if let title, !title.isEmpty { return title }
        if let generatedTitle, !generatedTitle.isEmpty { return generatedTitle }
        if let derivedLabel, !derivedLabel.isEmpty { return derivedLabel }
        if let summary, !summary.isEmpty { return summary }
        return String(id.prefix(12))
    }

    /// How recently a session must have been active to still count as needing
    /// review — older "Claude replied" sessions are ones you've already moved on
    /// from, so they shouldn't clutter the signal.
    static let needsReviewWindow: TimeInterval = 24 * 60 * 60

    /// A session worth returning to.
    ///
    /// When the Claude Code hook has reported this session's state we trust it
    /// outright — the agent itself told us whether it's working or waiting on the
    /// user, which is exactly the question. Only sessions with no hook data fall
    /// back to inferring it from transcript shape (Claude spoke last, recently),
    /// which over-reports because "Claude replied last" isn't the same as
    /// "Claude needs you".
    var needsReview: Bool { needsReview(now: Date()) }

    func needsReview(now: Date) -> Bool {
        guard !isArchived else { return false }
        if let agentState { return agentState.isWaitingOnUser }
        guard status != .running, lastMessageWasAssistant == true,
              let lastModifiedAt else { return false }
        return now.timeIntervalSince(lastModifiedAt) < Self.needsReviewWindow
    }

    /// Merge index-owned fields while preserving all user-owned metadata.
    func mergedWithIndexed(_ indexed: WorkbenchSessionRecord) -> WorkbenchSessionRecord {
        var result = self
        result.projectId = indexed.projectId ?? result.projectId
        result.cwd = indexed.cwd ?? result.cwd
        result.title = indexed.title ?? result.title
        result.summary = indexed.summary ?? result.summary
        result.lastModifiedAt = indexed.lastModifiedAt ?? result.lastModifiedAt
        result.transcriptPath = indexed.transcriptPath ?? result.transcriptPath
        result.messageCount = indexed.messageCount ?? result.messageCount
        result.lastMessageWasAssistant = indexed.lastMessageWasAssistant ?? result.lastMessageWasAssistant
        result.derivedLabel = indexed.derivedLabel ?? result.derivedLabel
        result.forkedFromSessionId = indexed.forkedFromSessionId ?? result.forkedFromSessionId
        if result.status == .unknown || result.status == .indexed || result.status == .idle {
            result.status = indexed.status
        }
        result.updatedAt = Date()
        return result
    }
}

struct WorkbenchLaunchRecord: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var sessionId: String?
    var projectId: String?
    var cwd: String?
    var commandDisplay: String
    var pid: Int32?
    var startedAt: Date
    var exitedAt: Date?
    var exitCode: Int32?
    var error: String?
}

struct WorkbenchSessionLock: Codable, Hashable, Sendable {
    var sessionId: String
    var launchId: String
    var pid: Int32?
    var acquiredAt: Date
}
