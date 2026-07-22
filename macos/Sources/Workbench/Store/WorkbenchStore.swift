import Foundation

protocol WorkbenchStore: AnyObject {
    func loadSnapshot() async throws -> WorkbenchSnapshot
    func upsertProject(_ project: WorkbenchProjectRecord) async throws
    func upsertIndexedSessions(_ sessions: [WorkbenchSessionRecord]) async throws
    func updateSession(_ session: WorkbenchSessionRecord) async throws
    func upsertLaunch(_ launch: WorkbenchLaunchRecord) async throws
    /// Sets (`lock` non-nil) or clears (`lock` nil) the lock for one session.
    func updateLock(_ lock: WorkbenchSessionLock?, for sessionId: String) async throws
}

struct WorkbenchSnapshot: Codable, Sendable {
    var projects: [WorkbenchProjectRecord]
    var sessions: [WorkbenchSessionRecord]
    var launches: [WorkbenchLaunchRecord]
    /// Per-session advisory locks. One session's lock never clobbers another's.
    var locks: [String: WorkbenchSessionLock]

    static let empty = WorkbenchSnapshot(projects: [], sessions: [], launches: [], locks: [:])

    init(
        projects: [WorkbenchProjectRecord],
        sessions: [WorkbenchSessionRecord],
        launches: [WorkbenchLaunchRecord],
        locks: [String: WorkbenchSessionLock]
    ) {
        self.projects = projects
        self.sessions = sessions
        self.launches = launches
        self.locks = locks
    }

    private enum CodingKeys: String, CodingKey {
        case projects, sessions, launches, locks
        case lock // legacy single-lock field, migrated on read
    }

    // Lenient decode so an older on-disk snapshot (single `lock`, or missing
    // `locks`) still loads without discarding user-owned metadata.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        projects = try container.decodeIfPresent([WorkbenchProjectRecord].self, forKey: .projects) ?? []
        sessions = try container.decodeIfPresent([WorkbenchSessionRecord].self, forKey: .sessions) ?? []
        launches = try container.decodeIfPresent([WorkbenchLaunchRecord].self, forKey: .launches) ?? []
        var decoded = try container.decodeIfPresent([String: WorkbenchSessionLock].self, forKey: .locks) ?? [:]
        if decoded.isEmpty, let legacy = try container.decodeIfPresent(WorkbenchSessionLock.self, forKey: .lock) {
            decoded[legacy.sessionId] = legacy
        }
        locks = decoded
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(projects, forKey: .projects)
        try container.encode(sessions, forKey: .sessions)
        try container.encode(launches, forKey: .launches)
        try container.encode(locks, forKey: .locks)
    }
}

actor JSONWorkbenchStore: WorkbenchStore {
    private let fileURL: URL
    private var snapshot: WorkbenchSnapshot?

    init(fileURL: URL = JSONWorkbenchStore.defaultURL()) {
        self.fileURL = fileURL
    }

    static func defaultURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return appSupport
            .appendingPathComponent("GhosttyClaudeWorkbench", isDirectory: true)
            .appendingPathComponent("workbench.json")
    }

    func loadSnapshot() async throws -> WorkbenchSnapshot {
        if let snapshot { return snapshot }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            snapshot = .empty
            return .empty
        }
        let data = try Data(contentsOf: fileURL)
        let decoded = try JSONDecoder.workbench.decode(WorkbenchSnapshot.self, from: data)
        snapshot = decoded
        return decoded
    }

    func upsertProject(_ project: WorkbenchProjectRecord) async throws {
        var current = try await loadSnapshot()
        if let index = current.projects.firstIndex(where: { $0.id == project.id || ($0.path != nil && $0.path == project.path) }) {
            current.projects[index] = project
        } else {
            current.projects.append(project)
        }
        try persist(current)
    }

    func upsertIndexedSessions(_ sessions: [WorkbenchSessionRecord]) async throws {
        var current = try await loadSnapshot()
        for indexed in sessions {
            if let index = current.sessions.firstIndex(where: { $0.id == indexed.id }) {
                current.sessions[index] = current.sessions[index].mergedWithIndexed(indexed)
            } else {
                current.sessions.append(indexed)
            }
        }
        current.sessions.sort { lhs, rhs in
            (lhs.lastModifiedAt ?? lhs.updatedAt) > (rhs.lastModifiedAt ?? rhs.updatedAt)
        }
        try persist(current)
    }

    func updateSession(_ session: WorkbenchSessionRecord) async throws {
        var current = try await loadSnapshot()
        if let index = current.sessions.firstIndex(where: { $0.id == session.id }) {
            current.sessions[index] = session
        } else {
            current.sessions.append(session)
        }
        try persist(current)
    }

    func upsertLaunch(_ launch: WorkbenchLaunchRecord) async throws {
        var current = try await loadSnapshot()
        if let index = current.launches.firstIndex(where: { $0.id == launch.id }) {
            current.launches[index] = launch
        } else {
            current.launches.append(launch)
        }
        current.launches = Array(current.launches.suffix(200))
        try persist(current)
    }

    func updateLock(_ lock: WorkbenchSessionLock?, for sessionId: String) async throws {
        var current = try await loadSnapshot()
        current.locks[sessionId] = lock // assigning nil removes the entry
        try persist(current)
    }

    private func persist(_ current: WorkbenchSnapshot) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder.workbench.encode(current)
        try data.write(to: fileURL, options: [.atomic])
        snapshot = current
    }
}

private extension JSONDecoder {
    static var workbench: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private extension JSONEncoder {
    static var workbench: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
