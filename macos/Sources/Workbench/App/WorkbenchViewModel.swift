import Foundation
import SwiftUI

@MainActor
final class WorkbenchViewModel: ObservableObject {
    /// Shared across all terminal tabs/windows so every sidebar reflects the same
    /// data + selection, the highlight can follow the focused session, and the
    /// Claude index is built once rather than per tab.
    static let shared = WorkbenchViewModel()

    struct LaunchBlock: Identifiable {
        let id = UUID()
        var title: String
        var message: String
    }

    /// Result of `prepareLaunchRequest`, so the initiating VIEW (not the shared
    /// model) owns any alert — otherwise a block alert pops in every open window.
    enum LaunchDecision {
        case proceed(WorkbenchLaunchRequest)
        case blocked(LaunchBlock)
        case ignored
    }

    @Published private(set) var sessions: [WorkbenchSessionRecord] = []
    /// Sessions grouped by repository and worktree. Cached — rebuilt only when
    /// sessions / git info / search change — so SwiftUI body evaluations (one per
    /// sidebar per re-render) don't re-run grouping+sorting over every session.
    @Published private(set) var worktreeGroups: [WorkbenchWorktreeGroup] = []
    @Published var selectedSessionID: String?
    @Published var filter: WorkbenchSessionFilter = .all {
        didSet {
            guard oldValue != filter else { return }
            rebuildGroups()
        }
    }
    @Published var searchText: String = "" {
        didSet {
            guard oldValue != searchText else { return }
            rebuildGroups()
        }
    }
    @Published var statusMessage: String?
    /// Collapsed worktree groups, keyed by `WorkbenchWorktreeGroup.id`. Persisted
    /// so collapse state survives refreshes and relaunches.
    @Published private(set) var collapsedGroupIDs: Set<String>
    /// Reactive sidebar visibility. Initialized from the persisted feature flag
    /// and written back on change so the toggle is both live and durable.
    @Published var isSidebarVisible: Bool = WorkbenchFeature.isSidebarVisible {
        didSet {
            guard oldValue != isSidebarVisible else { return }
            WorkbenchFeature.isSidebarVisible = isSidebarVisible
        }
    }

    private let store: WorkbenchStore
    private let indexer: WorkbenchSessionIndexing
    private let runningState: WorkbenchRunningStateReading
    private let gitService: WorkbenchGitReading
    private let collapseStore: WorkbenchGroupCollapseStore
    private var fileWatcher: WorkbenchFileWatcher?
    private var isRefreshing = false
    private var refreshQueued = false

    /// Transient git facts keyed by cwd, recomputed each refresh (never persisted).
    private var gitInfoByCwd: [String: WorkbenchGitInfo] = [:]

    /// Grace before a lock whose process never registered is treated as stale.
    private let lockLaunchGrace: TimeInterval = 45

    init(
        store: WorkbenchStore = JSONWorkbenchStore(),
        indexer: WorkbenchSessionIndexing = FilesystemClaudeSessionIndexService(),
        runningState: WorkbenchRunningStateReading = FilesystemRunningStateService(),
        gitService: WorkbenchGitReading = WorkbenchGitService(),
        collapseStore: WorkbenchGroupCollapseStore = WorkbenchGroupCollapseStore()
    ) {
        self.store = store
        self.indexer = indexer
        self.runningState = runningState
        self.gitService = gitService
        self.collapseStore = collapseStore
        self.collapsedGroupIDs = collapseStore.load()
        // Do not touch disk (index/scan) unless the feature is actually enabled.
        // This keeps "feature disabled" behavior identical to stock Ghostty:
        // constructing the model must have zero filesystem side effects.
        guard WorkbenchFeature.isEnabled else { return }
        Task { await refresh() }
        startFileWatcher()
    }

    deinit {
        fileWatcher?.stop()
    }

    /// The resolved `~/.claude` config directory (honoring `CLAUDE_CONFIG_DIR`).
    static func claudeConfigDirectory() -> URL {
        if let override = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".claude", isDirectory: true)
    }

    /// Live-updates the sidebar when Claude writes session or transcript files, so
    /// running-state and new sessions appear without hitting the refresh button.
    private func startFileWatcher() {
        let base = Self.claudeConfigDirectory()
        let paths = [
            base.appendingPathComponent("sessions", isDirectory: true).path,
            base.appendingPathComponent("projects", isDirectory: true).path,
        ]
        fileWatcher = WorkbenchFileWatcher(paths: paths) { [weak self] in
            Task { @MainActor in await self?.refresh() }
        }
        fileWatcher?.start()
    }

    /// Count of sessions matching a filter (ignores the search text), for the
    /// filter-chip badges. Cheap over a few dozen sessions.
    func count(for filter: WorkbenchSessionFilter) -> Int {
        sessions.lazy.filter { filter.matches($0) }.count
    }

    var filteredSessions: [WorkbenchSessionRecord] {
        let base = sessions.filter { filter.matches($0) }
        guard !searchText.isEmpty else { return base }
        return base.filter { WorkbenchFuzzy.score(query: searchText, session: $0) != nil }
    }

    /// Highest-scoring match for the current search — what Enter in the search
    /// field opens (fuzzy quick-open, the core "command palette" value).
    var topSearchMatch: WorkbenchSessionRecord? {
        guard !searchText.isEmpty else { return nil }
        return sessions
            .filter { filter.matches($0) }
            .compactMap { session in
                WorkbenchFuzzy.score(query: searchText, session: session).map { (session, $0) }
            }
            .max { $0.1 < $1.1 }?.0
    }

    var selectedSession: WorkbenchSessionRecord? {
        guard let selectedSessionID else { return nil }
        return sessions.first { $0.id == selectedSessionID }
    }

    func refresh() async {
        // Coalesce overlapping refreshes (the file watcher can fire while one is in
        // flight): run one, and if changes arrived meanwhile, run exactly once more.
        if isRefreshing {
            refreshQueued = true
            return
        }
        isRefreshing = true
        defer {
            isRefreshing = false
            if refreshQueued {
                refreshQueued = false
                Task { await self.refresh() }
            }
        }
        do {
            let snapshot = try await store.loadSnapshot()
            sessions = snapshot.sessions
            let indexed = try await indexer.indexedSessions()
            try await store.upsertIndexedSessions(indexed)
            let updated = try await store.loadSnapshot()

            // Overlay live process state (never persisted): recomputed each refresh
            // from ~/.claude/sessions so a stale PID can't linger as "running".
            let running = (try? await runningState.runningSessions()) ?? [:]

            // Self-heal locks whose session is no longer alive, so a crash (or a
            // launch without the lifecycle helper) can't lock a session forever.
            let activeLockSessions = await reconcileLocks(updated.locks, running: running)

            // Drop "ghost" sessions whose transcript was deleted: the store keeps
            // metadata records, but a session with no transcript on disk can't be
            // resumed. Keep it only if it's currently running/launching (a brand-new
            // session whose transcript may not be indexed yet).
            let indexedIDs = Set(indexed.map(\.id))
            sessions = updated.sessions.compactMap { session -> WorkbenchSessionRecord? in
                let isLive = running[session.id] != nil || activeLockSessions.contains(session.id)
                guard indexedIDs.contains(session.id) || isLive else { return nil }
                var session = session
                if let info = running[session.id] {
                    session.status = .running
                    session.runningPID = info.pid
                    if session.cwd == nil { session.cwd = info.cwd }
                } else if session.status == .running {
                    session.status = .idle
                    session.runningPID = nil
                } else if session.status == .launching && !activeLockSessions.contains(session.id) {
                    // Launch fizzled (no process, no live lock) — don't stick on launching.
                    session.status = .idle
                }
                return session
            }

            gitInfoByCwd = await loadGitInfo(for: sessions)
            rebuildGroups()

            let runningCount = sessions.filter { $0.status == .running }.count
            statusMessage = indexed.isEmpty
                ? "No Claude sessions found yet"
                : "Indexed \(indexed.count) session(s) · \(runningCount) running"
        } catch {
            statusMessage = "Workbench index failed: \(error.localizedDescription)"
        }
    }

    func select(_ session: WorkbenchSessionRecord) {
        selectedSessionID = session.id
    }

    func toggleSidebar() {
        isSidebarVisible.toggle()
    }

    func prepareLaunchRequest(mode: WorkbenchLaunchMode) async -> LaunchDecision {
        let request = WorkbenchLaunchRequest(mode: mode)

        switch mode {
        case .resume(let sessionId, _):
            if sessions.first(where: { $0.id == sessionId })?.status == .running {
                statusMessage = "Session \(String(sessionId.prefix(8))) is already running"
                return .ignored
            }
            do {
                if let lock = try await WorkbenchLockService(store: store).currentLock(for: sessionId) {
                    let message = "Session \(String(sessionId.prefix(8))) is locked by launch \(String(lock.launchId.prefix(8))). Wait for it to exit, or use Fork Session instead of opening the same session twice."
                    statusMessage = message
                    return .blocked(LaunchBlock(title: "Session Locked", message: message))
                }
                _ = try await WorkbenchLockService(store: store).acquire(
                    sessionId: sessionId,
                    launchId: request.id
                )
                markSessionLaunching(sessionId: sessionId, launchId: request.id)
            } catch {
                statusMessage = "Failed to lock session: \(error.localizedDescription)"
                return .ignored
            }
            return .proceed(request)

        case .fork, .new, .continueLatest, .worktree:
            return .proceed(request)
        }
    }

    func togglePinned(_ session: WorkbenchSessionRecord) {
        mutate(session) { $0.isPinned.toggle() }
    }

    func toggleArchived(_ session: WorkbenchSessionRecord) {
        mutate(session) {
            $0.isArchived.toggle()
            $0.status = $0.isArchived ? .archived : .idle
        }
    }

    /// Sets a local display name (Workbench-owned; never overwritten by indexing).
    /// An empty name clears it, falling back to the Claude/AI title.
    func rename(_ session: WorkbenchSessionRecord, to newTitle: String) {
        mutate(session) {
            let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            $0.localTitle = trimmed.isEmpty ? nil : trimmed
        }
    }

    private func mutate(_ session: WorkbenchSessionRecord, _ block: (inout WorkbenchSessionRecord) -> Void) {
        // Update the in-memory session in place so the live running-state overlay on
        // the OTHER sessions is preserved (a full reload from the store would drop
        // it until the next refresh), then persist asynchronously.
        guard let index = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        var updated = sessions[index]
        block(&updated)
        updated.updatedAt = Date()
        sessions[index] = updated
        rebuildGroups()
        Task {
            do {
                try await store.updateSession(updated)
            } catch {
                self.statusMessage = "Failed to update session: \(error.localizedDescription)"
            }
        }
    }

    private func markSessionLaunching(sessionId: String, launchId: String) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionId }) else { return }
        sessions[index].status = .launching
        sessions[index].lastLaunchId = launchId
        sessions[index].updatedAt = Date()
        let updated = sessions[index]
        Task {
            do {
                try await store.updateSession(updated)
            } catch {
                statusMessage = "Failed to persist launch state: \(error.localizedDescription)"
            }
        }
    }

    private func rebuildGroups() {
        worktreeGroups = WorkbenchWorktreeGrouping.groups(sessions: filteredSessions, gitInfo: gitInfoByCwd)
    }

    /// Whether a group is currently collapsed. While a search is active every
    /// group is force-expanded so matches can't hide inside a collapsed group.
    func isGroupCollapsed(_ id: String) -> Bool {
        guard searchText.isEmpty else { return false }
        return collapsedGroupIDs.contains(id)
    }

    func toggleGroupCollapsed(_ id: String) {
        if collapsedGroupIDs.contains(id) {
            collapsedGroupIDs.remove(id)
        } else {
            collapsedGroupIDs.insert(id)
        }
        collapseStore.save(collapsedGroupIDs)
    }

    /// Expands the group containing `sessionId` (if collapsed) so a newly selected
    /// or focus-followed session is visible and scroll-to can reach its row.
    func expandGroupContaining(_ sessionId: String) {
        guard
            let group = worktreeGroups.first(where: { $0.sessions.contains { $0.id == sessionId } }),
            collapsedGroupIDs.contains(group.id)
        else { return }
        collapsedGroupIDs.remove(group.id)
        collapseStore.save(collapsedGroupIDs)
    }

    /// Releases stale locks and returns the set of session ids that still hold a
    /// valid lock (so their `.launching` state is preserved during process boot).
    private func reconcileLocks(
        _ locks: [String: WorkbenchSessionLock],
        running: [String: WorkbenchRunningInfo]
    ) async -> Set<String> {
        var active: Set<String> = []
        let now = Date()
        for (sessionId, lock) in locks {
            let isRunning = running[sessionId] != nil
            let pidAlive = lock.pid.map { FilesystemRunningStateService.isProcessAlive($0) } ?? false
            if lock.isStale(isRunning: isRunning, pidAlive: pidAlive, now: now, grace: lockLaunchGrace) {
                try? await WorkbenchLockService(store: store).release(sessionId: sessionId)
            } else {
                active.insert(sessionId)
            }
        }
        return active
    }

    private func loadGitInfo(for sessions: [WorkbenchSessionRecord]) async -> [String: WorkbenchGitInfo] {
        let cwds = Array(Set(sessions.compactMap(\.cwd)))
        let gitService = self.gitService
        // Run the per-cwd git lookups concurrently instead of one-at-a-time.
        return await withTaskGroup(of: (String, WorkbenchGitInfo?).self) { group in
            for cwd in cwds {
                group.addTask { (cwd, await gitService.info(forCwd: cwd)) }
            }
            var info: [String: WorkbenchGitInfo] = [:]
            for await (cwd, gitInfo) in group {
                if let gitInfo { info[cwd] = gitInfo }
            }
            return info
        }
    }
}
