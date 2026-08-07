import SwiftUI
import XCTest
@testable import Ghostty

/// Tests for the Claude Workbench module.
///
/// Aligned with the record-based Workbench implementation
/// (`WorkbenchSessionRecord`, `JSONWorkbenchStore` actor, the filesystem
/// index service, the launcher, and the lock service).
final class WorkbenchTests: XCTestCase {
    // MARK: - Models / merge semantics

    func testDisplayTitlePrefersLocalThenIndexed() {
        var record = WorkbenchSessionRecord(id: "abcdef123456", title: "Indexed Title")
        XCTAssertEqual(record.displayTitle, "Indexed Title")

        record.localTitle = "My Name"
        XCTAssertEqual(record.displayTitle, "My Name")

        let bare = WorkbenchSessionRecord(id: "abcdef123456")
        XCTAssertEqual(bare.displayTitle, "abcdef123456")
    }

    func testMergedWithIndexedPreservesUserOwnedFields() {
        var user = WorkbenchSessionRecord(id: "1", title: "Old", status: .idle)
        user.localTitle = "Keep Me"
        user.isPinned = true
        user.tags = ["keep"]

        let indexed = WorkbenchSessionRecord(
            id: "1",
            title: "New",
            summary: "fresh",
            lastModifiedAt: Date(),
            status: .indexed
        )

        let merged = user.mergedWithIndexed(indexed)
        // Index-owned fields adopt the fresh values.
        XCTAssertEqual(merged.title, "New")
        XCTAssertEqual(merged.summary, "fresh")
        // User-owned fields are preserved.
        XCTAssertEqual(merged.localTitle, "Keep Me")
        XCTAssertTrue(merged.isPinned)
        XCTAssertEqual(merged.tags, ["keep"])
        // Display title still prefers the user's local title.
        XCTAssertEqual(merged.displayTitle, "Keep Me")
    }

    // MARK: - Git origin parsing / worktree grouping

    func testOriginNameParsesSCPAndURLRemotes() {
        XCTAssertEqual(WorkbenchGitService.originName("git@github.com:sugerio/marketplace-service.git"), "sugerio/marketplace-service")
        XCTAssertEqual(WorkbenchGitService.originName("https://github.com/sugerio/marketplace-service.git"), "sugerio/marketplace-service")
        XCTAssertEqual(WorkbenchGitService.originName("https://github.com/sugerio/marketplace-service"), "sugerio/marketplace-service")
    }

    func testWorktreeGroupingCollapsesSubdirsAndNestsWorktrees() throws {
        func session(_ id: String, _ cwd: String?) -> WorkbenchSessionRecord {
            WorkbenchSessionRecord(id: id, cwd: cwd, lastModifiedAt: Date())
        }
        // Two subdirs of one main checkout + one linked worktree of the same repo.
        let main = WorkbenchGitInfo(toplevel: "/repo", repoKey: "/repo/.git", branch: "main",
                                    dirty: 2, originName: "org/repo", isLinkedWorktree: false)
        let linked = WorkbenchGitInfo(toplevel: "/repo-wt", repoKey: "/repo/.git", branch: "feat",
                                      dirty: 0, originName: "org/repo", isLinkedWorktree: true)
        let git = [
            "/repo/apps/a": main,
            "/repo/apps/b": main,
            "/repo-wt": linked,
        ]
        let sessions = [session("s1", "/repo/apps/a"), session("s2", "/repo/apps/b"), session("s3", "/repo-wt")]
        let groups = WorkbenchWorktreeGrouping.groups(sessions: sessions, gitInfo: git)

        XCTAssertEqual(groups.count, 2) // one main worktree (2 subdir sessions) + one linked
        let mainGroup = try XCTUnwrap(groups.first { !$0.isLinkedWorktree })
        XCTAssertEqual(mainGroup.sessions.count, 2)
        XCTAssertEqual(mainGroup.repoName, "org/repo")
        // Same repo → adjacent; main checkout sorts before the linked worktree.
        XCTAssertFalse(groups[0].isLinkedWorktree)
        XCTAssertTrue(groups[1].isLinkedWorktree)
    }

    func testWorktreeGroupingNonGitAndNoCwd() {
        let sessions = [
            WorkbenchSessionRecord(id: "g", cwd: "/tmp/plain", lastModifiedAt: Date()),
            WorkbenchSessionRecord(id: "n", cwd: nil, lastModifiedAt: Date()),
        ]
        let groups = WorkbenchWorktreeGrouping.groups(sessions: sessions, gitInfo: [:])
        XCTAssertEqual(groups.count, 2)
        XCTAssertNotNil(groups.first { $0.repoName == "plain" && !$0.isGit })
        XCTAssertNotNil(groups.first { $0.repoName == "No working directory" })
        // The no-cwd bucket always sorts last.
        XCTAssertEqual(groups.last?.repoName, "No working directory")
    }

    func testWorktreeGroupingSeparatesTwoClonesOfOneOrigin() {
        func session(_ id: String, _ cwd: String, at time: TimeInterval) -> WorkbenchSessionRecord {
            WorkbenchSessionRecord(id: id, cwd: cwd, lastModifiedAt: Date(timeIntervalSince1970: time))
        }
        // Same originName but two distinct clones (different repoKey) must NOT collapse.
        let cloneA = WorkbenchGitInfo(toplevel: "/a/repo", repoKey: "/a/repo/.git", branch: "main",
                                      dirty: 0, originName: "org/repo", isLinkedWorktree: false)
        let cloneB = WorkbenchGitInfo(toplevel: "/b/repo", repoKey: "/b/repo/.git", branch: "dev",
                                      dirty: 0, originName: "org/repo", isLinkedWorktree: false)
        let groups = WorkbenchWorktreeGrouping.groups(
            sessions: [session("a", "/a/repo", at: 100), session("b", "/b/repo", at: 200)],
            gitInfo: ["/a/repo": cloneA, "/b/repo": cloneB])
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(Set(groups.map(\.repoKey)), ["/a/repo/.git", "/b/repo/.git"])
        // The more-recently-active clone (B) sorts first.
        XCTAssertEqual(groups.first?.repoKey, "/b/repo/.git")
    }

    func testWorktreeGroupingOrdersRunningThenPinnedThenRecent() throws {
        // All in one non-git group so we isolate intra-group session ordering.
        var running = WorkbenchSessionRecord(id: "run", cwd: "/tmp/proj",
                                             lastModifiedAt: Date(timeIntervalSince1970: 100))
        running.status = .running
        var pinned = WorkbenchSessionRecord(id: "pin", cwd: "/tmp/proj",
                                            lastModifiedAt: Date(timeIntervalSince1970: 200))
        pinned.isPinned = true
        let recentIdle = WorkbenchSessionRecord(id: "idle", cwd: "/tmp/proj",
                                                lastModifiedAt: Date(timeIntervalSince1970: 300))

        let groups = WorkbenchWorktreeGrouping.groups(
            sessions: [recentIdle, pinned, running], gitInfo: [:])
        let group = try XCTUnwrap(groups.first { $0.path == "/tmp/proj" })
        // Running first (even though oldest), then pinned, then the recent idle one.
        XCTAssertEqual(group.sessions.map(\.id), ["run", "pin", "idle"])
    }

    // MARK: - Filters / needs-review

    func testNeedsReviewAndFilterMatching() {
        let now = Date()
        func make(_ id: String, status: WorkbenchSessionStatus = .idle, lastAssistant: Bool? = nil,
                  pinned: Bool = false, archived: Bool = false, modified: Date = Date()) -> WorkbenchSessionRecord {
            var s = WorkbenchSessionRecord(id: id, lastModifiedAt: modified, lastMessageWasAssistant: lastAssistant, status: status)
            s.isPinned = pinned
            s.isArchived = archived
            return s
        }
        let running = make("run", status: .running, lastAssistant: true)
        let waiting = make("wait", lastAssistant: true)                                    // recent + Claude replied → needs review
        let stale = make("stale", lastAssistant: true, modified: now.addingTimeInterval(-2 * 86400)) // 2d old → NOT needs review
        let userTurn = make("user", lastAssistant: false)                                  // last was user → no
        let pinned = make("pin", pinned: true)
        let archived = make("arch", lastAssistant: true, archived: true)

        XCTAssertTrue(waiting.needsReview(now: now))
        XCTAssertFalse(stale.needsReview(now: now))    // recency bound excludes old sessions
        XCTAssertFalse(userTurn.needsReview(now: now))
        XCTAssertFalse(running.needsReview(now: now))  // running is never "needs review"
        XCTAssertFalse(archived.needsReview(now: now)) // archived excluded

        XCTAssertTrue(WorkbenchSessionFilter.running.matches(running))
        XCTAssertFalse(WorkbenchSessionFilter.running.matches(waiting))
        XCTAssertTrue(WorkbenchSessionFilter.needsReview.matches(waiting))
        XCTAssertFalse(WorkbenchSessionFilter.needsReview.matches(stale))
        XCTAssertTrue(WorkbenchSessionFilter.favorite.matches(pinned))
        XCTAssertFalse(WorkbenchSessionFilter.favorite.matches(waiting))
        XCTAssertTrue(WorkbenchSessionFilter.archived.matches(archived))
        XCTAssertFalse(WorkbenchSessionFilter.all.matches(archived))  // all hides archived
        XCTAssertTrue(WorkbenchSessionFilter.all.matches(waiting))
    }

    // MARK: - Fuzzy search (quick-open)

    func testFuzzySearchMatching() {
        // Subsequence match across abbreviations / initials.
        XCTAssertNotNil(WorkbenchFuzzy.score(query: "prsf", in: "partner-prm-search-filters"))
        XCTAssertNotNil(WorkbenchFuzzy.score(query: "search", in: "partner-prm-search-filters"))
        XCTAssertNil(WorkbenchFuzzy.score(query: "fsrp", in: "partner-prm-search-filters")) // wrong order → no match
        XCTAssertNil(WorkbenchFuzzy.score(query: "xyz", in: "abc"))
        XCTAssertEqual(WorkbenchFuzzy.score(query: "", in: "anything"), 0)
        // A word-boundary (prefix) match outranks the same run mid-word.
        let boundary = try! XCTUnwrap(WorkbenchFuzzy.score(query: "part", in: "partner-prm"))
        let midWord = try! XCTUnwrap(WorkbenchFuzzy.score(query: "part", in: "xpartx"))
        XCTAssertGreaterThan(boundary, midWord)
        // Session-level: matches the best of title / cwd / id.
        let session = WorkbenchSessionRecord(id: "abc123", cwd: "/Users/me/dev/webapp")
        XCTAssertNotNil(WorkbenchFuzzy.score(query: "webapp", session: session))
        XCTAssertNil(WorkbenchFuzzy.score(query: "zzzz", session: session))
    }

    // MARK: - Lock staleness

    func testLockStalenessRespectsRunningAndGrace() {
        let now = Date()
        let fresh = WorkbenchSessionLock(sessionId: "s", launchId: "l", pid: nil, acquiredAt: now.addingTimeInterval(-5))
        let old = WorkbenchSessionLock(sessionId: "s", launchId: "l", pid: nil, acquiredAt: now.addingTimeInterval(-120))
        // Fresh lock inside grace: not stale even with no process yet.
        XCTAssertFalse(fresh.isStale(isRunning: false, pidAlive: false, now: now, grace: 45))
        // Old lock, process gone: stale.
        XCTAssertTrue(old.isStale(isRunning: false, pidAlive: false, now: now, grace: 45))
        // Still running: never stale.
        XCTAssertFalse(old.isStale(isRunning: true, pidAlive: false, now: now, grace: 45))
        // Live PID: never stale.
        XCTAssertFalse(old.isStale(isRunning: false, pidAlive: true, now: now, grace: 45))
        // Exactly at the grace boundary: `> grace` is false, so not yet stale.
        let boundary = WorkbenchSessionLock(sessionId: "s", launchId: "l", pid: nil, acquiredAt: now.addingTimeInterval(-45))
        XCTAssertFalse(boundary.isStale(isRunning: false, pidAlive: false, now: now, grace: 45))
    }

    // MARK: - Group collapse store

    func testGroupCollapseStorePersistsAndClears() throws {
        let suite = "wb-collapse-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WorkbenchGroupCollapseStore(defaults: defaults)

        XCTAssertTrue(store.load().isEmpty)
        store.save(["/a", "/b"])
        XCTAssertEqual(store.load(), ["/a", "/b"])
        // A fresh store over the same defaults observes the persisted set.
        XCTAssertEqual(WorkbenchGroupCollapseStore(defaults: defaults).load(), ["/a", "/b"])
        // Saving an empty set clears the backing key entirely.
        store.save([])
        XCTAssertTrue(store.load().isEmpty)
        XCTAssertNil(defaults.object(forKey: WorkbenchGroupCollapseStore.defaultsKey))
    }

    // MARK: - Feature flag

    func testFeatureFlagDefaultsEnabled() {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: WorkbenchFeature.enabledKey)
        defaults.removeObject(forKey: WorkbenchFeature.enabledKey)
        defer {
            if let previous {
                defaults.set(previous, forKey: WorkbenchFeature.enabledKey)
            } else {
                defaults.removeObject(forKey: WorkbenchFeature.enabledKey)
            }
        }
        XCTAssertTrue(WorkbenchFeature.isEnabled)
    }

    // MARK: - Store round trip

    func testJSONStoreRoundTrip() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wb-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appendingPathComponent("workbench.json")

        let store = JSONWorkbenchStore(fileURL: fileURL)
        let empty = try await store.loadSnapshot()
        XCTAssertTrue(empty.sessions.isEmpty)

        var record = WorkbenchSessionRecord(id: "x", title: "Persisted")
        record.tags = ["t1"]
        try await store.updateSession(record)

        // A fresh store reading the same file should observe the persisted data.
        let reloaded = JSONWorkbenchStore(fileURL: fileURL)
        let snapshot = try await reloaded.loadSnapshot()
        XCTAssertEqual(snapshot.sessions.count, 1)
        XCTAssertEqual(snapshot.sessions.first?.title, "Persisted")
        XCTAssertEqual(snapshot.sessions.first?.tags, ["t1"])
    }

    func testStoreUpsertIndexedMergesExisting() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wb-idx-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = JSONWorkbenchStore(fileURL: dir.appendingPathComponent("workbench.json"))

        var existing = WorkbenchSessionRecord(id: "1", title: "Old", status: .idle)
        existing.tags = ["keep"]
        try await store.updateSession(existing)

        let indexed = WorkbenchSessionRecord(id: "1", title: "New", summary: "fresh", status: .indexed)
        try await store.upsertIndexedSessions([indexed])

        let snapshot = try await store.loadSnapshot()
        XCTAssertEqual(snapshot.sessions.count, 1)
        XCTAssertEqual(snapshot.sessions.first?.title, "New")
        XCTAssertEqual(snapshot.sessions.first?.tags, ["keep"])
    }

    // MARK: - Lock service (round-trips through the store)

    func testLockAcquireAndRelease() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wb-lock-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = JSONWorkbenchStore(fileURL: dir.appendingPathComponent("workbench.json"))
        let service = WorkbenchLockService(store: store)

        let lock = try await service.acquire(sessionId: "s1", launchId: "l1", pid: 4242)
        XCTAssertEqual(lock.sessionId, "s1")
        XCTAssertEqual(lock.launchId, "l1")
        XCTAssertEqual(lock.pid, 4242)

        let current = try await service.currentLock(for: "s1")
        XCTAssertNotNil(current)
        // A different session should not observe the lock.
        let other = try await service.currentLock(for: "s2")
        XCTAssertNil(other)

        try await service.release(sessionId: "s1")
        let afterRelease = try await service.currentLock(for: "s1")
        XCTAssertNil(afterRelease)
    }

    func testLocksAreIndependentPerSession() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wb-lock2-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = JSONWorkbenchStore(fileURL: dir.appendingPathComponent("workbench.json"))
        let service = WorkbenchLockService(store: store)

        _ = try await service.acquire(sessionId: "A", launchId: "la")
        _ = try await service.acquire(sessionId: "B", launchId: "lb")
        // Locking B must NOT clobber A's lock (the single-slot bug).
        let lockA = try await service.currentLock(for: "A")
        let lockB = try await service.currentLock(for: "B")
        XCTAssertNotNil(lockA)
        XCTAssertNotNil(lockB)

        try await service.release(sessionId: "A")
        let lockAAfterRelease = try await service.currentLock(for: "A")
        let lockBAfterRelease = try await service.currentLock(for: "B")
        XCTAssertNil(lockAAfterRelease)
        XCTAssertNotNil(lockBAfterRelease)
    }

    func testSnapshotMigratesLegacySingleLock() throws {
        // An older snapshot with a single `lock` field still loads and migrates.
        let legacy = """
        {"projects":[],"sessions":[],"launches":[],"lock":{"sessionId":"s9","launchId":"l9","acquiredAt":"2026-01-01T00:00:00Z"}}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(WorkbenchSnapshot.self, from: Data(legacy.utf8))
        XCTAssertEqual(snapshot.locks["s9"]?.launchId, "l9")
    }

    // MARK: - Filesystem index service

    func testIndexServiceMissingDirectoryReturnsEmpty() async throws {
        let missing = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString)", isDirectory: true)
        let service = FilesystemClaudeSessionIndexService(configDirectory: missing)
        let sessions = try await service.indexedSessions()
        XCTAssertTrue(sessions.isEmpty)
    }

    func testIndexServiceDiscoversJSONLTranscripts() async throws {
        let fm = FileManager.default
        let configDir = fm.temporaryDirectory
            .appendingPathComponent("wb-claude-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: configDir) }

        let projectDir = configDir
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent("-Users-me-dev-app", isDirectory: true)
        try fm.createDirectory(at: projectDir, withIntermediateDirectories: true)

        let sessionFile = projectDir.appendingPathComponent("session-uuid-1.jsonl")
        try "{\"type\":\"summary\"}\n".write(to: sessionFile, atomically: true, encoding: .utf8)
        // A non-transcript file should be ignored.
        try "ignore".write(to: projectDir.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)

        let service = FilesystemClaudeSessionIndexService(configDirectory: configDir)
        let sessions = try await service.indexedSessions()
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.id, "session-uuid-1")
        XCTAssertEqual(sessions.first?.projectId, "-Users-me-dev-app")
        XCTAssertEqual(sessions.first?.transcriptPath, sessionFile.standardizedFileURL.path)
        XCTAssertEqual(sessions.first?.status, .indexed)
    }

    func testIndexServiceScrapesTitleCwdAndMessageCount() async throws {
        let fm = FileManager.default
        let configDir = fm.temporaryDirectory
            .appendingPathComponent("wb-scrape-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: configDir) }

        let projectDir = configDir
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent("-Users-me-dev-app", isDirectory: true)
        try fm.createDirectory(at: projectDir, withIntermediateDirectories: true)

        let transcript = """
        {"type":"user","cwd":"/Users/me/dev/app","gitBranch":"main"}
        {"type":"assistant"}
        {"type":"user"}
        {"type":"ai-title","aiTitle":"Generated Title"}
        {"type":"custom-title","customTitle":"My Session"}
        {"type":"last-prompt","lastPrompt":"do the thing"}
        """
        try transcript.write(
            to: projectDir.appendingPathComponent("session-uuid-1.jsonl"),
            atomically: true, encoding: .utf8)

        let service = FilesystemClaudeSessionIndexService(configDirectory: configDir)
        let sessions = try await service.indexedSessions()
        XCTAssertEqual(sessions.count, 1)
        let session = try XCTUnwrap(sessions.first)
        // custom-title wins over ai-title.
        XCTAssertEqual(session.title, "My Session")
        XCTAssertEqual(session.summary, "do the thing")
        XCTAssertEqual(session.cwd, "/Users/me/dev/app")
        XCTAssertEqual(session.messageCount, 3) // 2 user + 1 assistant
        XCTAssertEqual(session.displayTitle, "My Session")
    }

    func testIndexServiceSkipsSubagentSidechains() async throws {
        let fm = FileManager.default
        let configDir = fm.temporaryDirectory
            .appendingPathComponent("wb-sub-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: configDir) }

        let projectDir = configDir
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent("-Users-me-dev-app", isDirectory: true)
        let subagentsDir = projectDir
            .appendingPathComponent("session-1", isDirectory: true)
            .appendingPathComponent("subagents", isDirectory: true)
        try fm.createDirectory(at: subagentsDir, withIntermediateDirectories: true)

        // Real session transcript (direct child) + a nested subagent sidechain.
        try "{\"type\":\"user\"}".write(
            to: projectDir.appendingPathComponent("session-1.jsonl"), atomically: true, encoding: .utf8)
        try "{\"type\":\"user\"}".write(
            to: subagentsDir.appendingPathComponent("agent-abc.jsonl"), atomically: true, encoding: .utf8)

        let service = FilesystemClaudeSessionIndexService(configDirectory: configDir)
        let sessions = try await service.indexedSessions()
        XCTAssertEqual(sessions.map(\.id), ["session-1"])
    }

    // MARK: - Running state service

    func testRunningStateReturnsLiveAndFiltersDeadPIDs() async throws {
        let fm = FileManager.default
        let configDir = fm.temporaryDirectory
            .appendingPathComponent("wb-run-\(UUID().uuidString)", isDirectory: true)
        let sessionsDir = configDir.appendingPathComponent("sessions", isDirectory: true)
        try fm.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: configDir) }

        // The test runner's own PID is guaranteed alive.
        let livePID = ProcessInfo.processInfo.processIdentifier
        try "{\"pid\":\(livePID),\"sessionId\":\"live-1\",\"cwd\":\"/tmp/live\",\"entrypoint\":\"cli\"}"
            .write(to: sessionsDir.appendingPathComponent("\(livePID).json"), atomically: true, encoding: .utf8)
        // A PID that cannot be running.
        try "{\"pid\":2147480000,\"sessionId\":\"dead-1\"}"
            .write(to: sessionsDir.appendingPathComponent("2147480000.json"), atomically: true, encoding: .utf8)

        let service = FilesystemRunningStateService(configDirectory: configDir)
        let running = try await service.runningSessions()

        XCTAssertNotNil(running["live-1"])
        XCTAssertEqual(running["live-1"]?.pid, livePID)
        XCTAssertEqual(running["live-1"]?.cwd, "/tmp/live")
        XCTAssertNil(running["dead-1"])
    }

    func testRunningStateMissingDirectoryReturnsEmpty() async throws {
        let missing = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString)", isDirectory: true)
        let service = FilesystemRunningStateService(configDirectory: missing)
        let running = try await service.runningSessions()
        XCTAssertTrue(running.isEmpty)
    }

    func testRunningStateKeepsNewestWhenSessionIdRepeats() async throws {
        let fm = FileManager.default
        let configDir = fm.temporaryDirectory
            .appendingPathComponent("wb-dup-\(UUID().uuidString)", isDirectory: true)
        let sessionsDir = configDir.appendingPathComponent("sessions", isDirectory: true)
        try fm.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: configDir) }

        // Two alive processes carrying the same sessionId (a lingering file + the
        // live one). Both PIDs must be alive, so use this process and its parent.
        let livePID = ProcessInfo.processInfo.processIdentifier
        let parentPID = getppid()
        try "{\"pid\":\(parentPID),\"sessionId\":\"dup\",\"cwd\":\"/tmp/old\",\"startedAt\":1000}"
            .write(to: sessionsDir.appendingPathComponent("\(parentPID).json"), atomically: true, encoding: .utf8)
        try "{\"pid\":\(livePID),\"sessionId\":\"dup\",\"cwd\":\"/tmp/new\",\"startedAt\":9999}"
            .write(to: sessionsDir.appendingPathComponent("\(livePID).json"), atomically: true, encoding: .utf8)

        let running = try await FilesystemRunningStateService(configDirectory: configDir).runningSessions()
        // The newer startedAt wins regardless of directory enumeration order.
        XCTAssertEqual(running["dup"]?.pid, livePID)
        XCTAssertEqual(running["dup"]?.cwd, "/tmp/new")
    }



    // MARK: - Launcher

    func testLauncherBuildsResumeCommand() {
        let launcher = WorkbenchLauncherService()
        let built = launcher.build(
            WorkbenchLaunchRequest(mode: .resume(sessionId: "abc123", cwd: "/tmp/proj"))
        )
        XCTAssertEqual(built.displayCommand, "claude --resume abc123")
        XCTAssertEqual(built.workingDirectory, "/tmp/proj")
        XCTAssertEqual(built.sessionId, "abc123")
    }

    /// The executed command must run through a login shell (so a Dock-launched app
    /// picks up the user's PATH and can find `claude`) and must clear the
    /// child-session marker (so spawned sessions are first-class: transcript saved
    /// and registered in ~/.claude/sessions). `displayCommand` stays human-readable.
    func testLauncherWrapsCommandInLoginShellAndClearsChildMarker() {
        let built = WorkbenchLauncherService().build(
            WorkbenchLaunchRequest(mode: .resume(sessionId: "abc123", cwd: nil))
        )
        XCTAssertEqual(built.displayCommand, "claude --resume abc123")
        XCTAssertTrue(built.command.contains(" -l -c "), built.command)
        XCTAssertTrue(built.command.contains("unset CLAUDE_CODE_CHILD_SESSION"), built.command)
        XCTAssertTrue(built.command.contains("exec claude --resume abc123"), built.command)
    }

    func testLauncherBuildsForkCommand() {
        let launcher = WorkbenchLauncherService()
        let built = launcher.build(
            WorkbenchLaunchRequest(mode: .fork(sessionId: "id1", cwd: nil))
        )
        XCTAssertEqual(built.displayCommand, "claude --resume id1 --fork-session")
        XCTAssertEqual(built.sessionId, "id1")
    }

    func testLauncherContinueLatest() {
        let launcher = WorkbenchLauncherService()
        let built = launcher.build(
            WorkbenchLaunchRequest(mode: .continueLatest(cwd: "/work"))
        )
        XCTAssertEqual(built.displayCommand, "claude --continue")
        XCTAssertEqual(built.workingDirectory, "/work")
        XCTAssertNil(built.sessionId)
    }

    func testLauncherShellQuotesUnsafeArguments() {
        let launcher = WorkbenchLauncherService()
        let built = launcher.build(
            WorkbenchLaunchRequest(mode: .new(projectPath: "/tmp", prompt: "hello world"))
        )
        XCTAssertEqual(built.displayCommand, "claude 'hello world'")
    }

    // MARK: - Agent state (hook events)

    func testAgentEventStateMapping() {
        func event(_ name: String, notification: String? = nil) -> WorkbenchAgentEvent {
            WorkbenchAgentEvent(
                sessionId: "s1", event: name, cwd: nil,
                notificationType: notification, source: nil, reason: nil, receivedAt: Date())
        }

        XCTAssertEqual(event("UserPromptSubmit").state, .working)
        XCTAssertEqual(event("SessionStart").state, .working)
        XCTAssertEqual(event("Stop").state, .idle)
        XCTAssertEqual(event("PermissionRequest").state, .awaitingInput)
        XCTAssertEqual(event("SessionEnd").state, .ended)
        XCTAssertEqual(event("Notification", notification: "permission_prompt").state, .awaitingInput)
        XCTAssertEqual(event("Notification", notification: "agent_needs_input").state, .awaitingInput)
        XCTAssertEqual(event("Notification", notification: "idle_prompt").state, .idle)
        // Noise we must not turn into a "waiting on you" signal.
        XCTAssertNil(event("Notification", notification: "auth_success").state)
        XCTAssertNil(event("PostToolUse").state)

        XCTAssertTrue(WorkbenchAgentState.idle.isWaitingOnUser)
        XCTAssertTrue(WorkbenchAgentState.awaitingInput.isWaitingOnUser)
        XCTAssertFalse(WorkbenchAgentState.working.isWaitingOnUser)
    }

    func testAgentEventServiceDrainsConsumesAndPrunes() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wb-events-\(UUID().uuidString)", isDirectory: true)
        let service = WorkbenchAgentEventService(directory: dir)
        service.ensureDirectoryExists()

        func write(_ name: String, _ json: String, ageSeconds: TimeInterval = 0) throws {
            let url = dir.appendingPathComponent(name)
            try json.write(to: url, atomically: true, encoding: .utf8)
            if ageSeconds > 0 {
                try FileManager.default.setAttributes(
                    [.modificationDate: Date().addingTimeInterval(-ageSeconds)],
                    ofItemAtPath: url.path)
            }
        }

        try write("a.json", #"{"session_id":"s1","hook_event_name":"Stop","cwd":"/w"}"#)
        try write("b.json", #"{"hook_event_name":"Stop"}"#)                       // no session_id
        try write("c.json", "not json at all")                                     // malformed
        try write("d.json", #"{"session_id":"old","hook_event_name":"Stop"}"#,
                  ageSeconds: WorkbenchAgentEventService.maxEventAge + 60)         // too old
        try write("e.txt", #"{"session_id":"s2","hook_event_name":"Stop"}"#)       // wrong extension

        let events = service.drain()
        XCTAssertEqual(events.map(\.sessionId), ["s1"])
        XCTAssertEqual(events.first?.cwd, "/w")

        // Everything it looked at is consumed (including the junk), so a bad event
        // can't be re-read forever. The non-.json file is left alone.
        let remaining = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        XCTAssertEqual(remaining, ["e.txt"])
        XCTAssertTrue(service.drain().isEmpty)

        try? FileManager.default.removeItem(at: dir)
    }

    /// Hook state is authoritative; the transcript-shape heuristic is only a
    /// fallback for sessions the hook has never reported on.
    func testNeedsReviewPrefersHookStateOverHeuristic() {
        // Heuristic would say "needs review" (Claude spoke last, recent)...
        var session = WorkbenchSessionRecord(id: "s1", status: .idle)
        session.lastMessageWasAssistant = true
        session.lastModifiedAt = Date()
        XCTAssertTrue(session.needsReview)

        // ...but the hook says Claude is still working, so it must not.
        session.agentState = .working
        XCTAssertFalse(session.needsReview)

        session.agentState = .idle
        XCTAssertTrue(session.needsReview)
        session.agentState = .awaitingInput
        XCTAssertTrue(session.needsReview)
        session.agentState = .ended
        XCTAssertFalse(session.needsReview)

        // A running session that the hook says is waiting on input still counts,
        // which the old status-based guard would have missed.
        session.status = .running
        session.agentState = .awaitingInput
        XCTAssertTrue(session.needsReview)

        // Archived always wins.
        session.isArchived = true
        XCTAssertFalse(session.needsReview)
    }

    // MARK: - Generated titles

    func testTitleExcerptTakesOpeningConversationOnly() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wb-title-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("t.jsonl")
        try ([
            #"{"type":"mode","mode":"auto"}"#,
            // Scaffolding must not be the thing we ask Claude to name.
            #"{"type":"user","message":{"role":"user","content":"<command-name>/model</command-name>"}}"#,
            #"{"type":"user","message":{"role":"user","content":"PE-11318 look at the dashboard"}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","thinking":"hmm"},{"type":"text","text":"Reading the code."}]}}"#,
            // Subagent turns aren't this session's conversation.
            #"{"type":"user","isSidechain":true,"message":{"role":"user","content":"subagent work"}}"#,
            #"{"type":"user","message":{"role":"user","content":"third"}}"#,
        ].joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)

        let excerpt = try XCTUnwrap(WorkbenchTitleGeneratorService.excerpt(atPath: url.path))
        let lines = excerpt.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines, [
            "User: PE-11318 look at the dashboard",
            "Claude: Reading the code.",
            "User: third",
        ])
        // Thinking blocks and scaffolding are absent.
        XCTAssertFalse(excerpt.contains("hmm"))
        XCTAssertFalse(excerpt.contains("command-name"))
        XCTAssertFalse(excerpt.contains("subagent"))

        // Honors the turn budget: this is the *opening*, not the whole transcript.
        let capped = try XCTUnwrap(WorkbenchTitleGeneratorService.excerpt(atPath: url.path, turns: 2))
        XCTAssertEqual(capped.split(separator: "\n").count, 2)

        XCTAssertNil(WorkbenchTitleGeneratorService.excerpt(atPath: "/nope/missing.jsonl"))
    }

    func testTitleSanitizeStripsModelDressing() {
        XCTAssertEqual(
            WorkbenchTitleGeneratorService.sanitize("PE-11318 customer success dashboard plan"),
            "PE-11318 customer success dashboard plan")
        // Quotes, markdown emphasis and trailing punctuation are not part of a title.
        XCTAssertEqual(WorkbenchTitleGeneratorService.sanitize("\"Fix the parser\""), "Fix the parser")
        XCTAssertEqual(WorkbenchTitleGeneratorService.sanitize("**Fix the parser**"), "Fix the parser")
        XCTAssertEqual(WorkbenchTitleGeneratorService.sanitize("Fix the parser."), "Fix the parser")
        // Only the first non-empty line.
        XCTAssertEqual(WorkbenchTitleGeneratorService.sanitize("\n\nFix parser\nsome rambling"), "Fix parser")
        XCTAssertNil(WorkbenchTitleGeneratorService.sanitize("   "))
        XCTAssertNil(WorkbenchTitleGeneratorService.sanitize(""))
        // An explanation instead of a title is rejected rather than shown as one.
        XCTAssertNil(WorkbenchTitleGeneratorService.sanitize(
            String(repeating: "this is a long explanation rather than a title ", count: 5)))
    }

    // MARK: - Incremental indexing

    /// The active session's transcript is the biggest file and the one written to
    /// constantly, so it's re-indexed continuously. Appending must be folded into
    /// the cached state rather than rescanned, and the result has to be identical
    /// to a scan from scratch — including a line that arrives split across two
    /// scrapes, which is what a scrape landing mid-write sees.
    func testIncrementalScrapeMatchesFullScan() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wb-index-\(UUID().uuidString)", isDirectory: true)
        let projects = dir.appendingPathComponent("projects/-Users-someone-repo", isDirectory: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let sessionId = "11111111-2222-3333-4444-555555555555"
        let url = projects.appendingPathComponent("\(sessionId).jsonl")

        func append(_ text: String) throws {
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(text.utf8))
            try handle.close()
            // Distinct mtimes, so the cache can't be reused by accident.
            try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        }

        let first = #"{"type":"user","cwd":"/Users/someone/repo","message":{"role":"user","content":"investigate the stuck referrals"}}"# + "\n"
        try Data(first.utf8).write(to: url)

        let service = FilesystemClaudeSessionIndexService(configDirectory: dir)
        var sessions = try await service.indexedSessions()
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].messageCount, 1)
        // No title of its own, so the derived label is what the list shows.
        XCTAssertNil(sessions[0].title)
        XCTAssertEqual(sessions[0].derivedLabel, "investigate the stuck referrals")
        XCTAssertEqual(sessions[0].displayTitle, "investigate the stuck referrals")
        XCTAssertEqual(sessions[0].cwd, "/Users/someone/repo")

        // Append more, including a title that must win over the derived label.
        try append(#"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"looking"}]}}"# + "\n")
        try append(#"{"type":"custom-title","customTitle":"referral-triage"}"# + "\n")
        sessions = try await service.indexedSessions()
        XCTAssertEqual(sessions[0].messageCount, 2, "counts must accumulate, not reset")
        // A real title outranks the derived label.
        XCTAssertEqual(sessions[0].title, "referral-triage")
        XCTAssertEqual(sessions[0].displayTitle, "referral-triage")
        XCTAssertEqual(sessions[0].lastMessageWasAssistant, true)

        // A complete line with no trailing newline still counts — a transcript
        // that simply doesn't end in one would otherwise lose its last message —
        // and must not be counted a second time when the newline arrives.
        try append(#"{"type":"user","message":{"role":"user","content":"and now"}}"#)
        sessions = try await service.indexedSessions()
        XCTAssertEqual(sessions[0].messageCount, 3, "trailing line without a newline still counts")
        try append("\n")
        sessions = try await service.indexedSessions()
        XCTAssertEqual(sessions[0].messageCount, 3, "and is not counted twice once completed")
        XCTAssertEqual(sessions[0].lastMessageWasAssistant, false)

        // Truncated JSON caught mid-write folds to nothing rather than corrupting
        // the accumulated state.
        try append(#"{"type":"user","message":{"role":"user","cont"#)
        sessions = try await service.indexedSessions()
        XCTAssertEqual(sessions[0].messageCount, 3, "half-written line is ignored")

        // Same bytes, cold service: incremental and full scans must agree.
        let cold = try await FilesystemClaudeSessionIndexService(configDirectory: dir).indexedSessions()
        XCTAssertEqual(cold[0].messageCount, sessions[0].messageCount)
        XCTAssertEqual(cold[0].title, sessions[0].title)
        XCTAssertEqual(cold[0].derivedLabel, sessions[0].derivedLabel)
        XCTAssertEqual(cold[0].summary, sessions[0].summary)
        XCTAssertEqual(cold[0].lastMessageWasAssistant, sessions[0].lastMessageWasAssistant)
    }

    /// A rewritten (shorter) file can't be resumed from a stale offset.
    func testScrapeRescansWhenTranscriptShrinks() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wb-index2-\(UUID().uuidString)", isDirectory: true)
        let projects = dir.appendingPathComponent("projects/-Users-someone-repo", isDirectory: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = projects.appendingPathComponent("22222222-2222-3333-4444-555555555555.jsonl")
        let long = (0..<6).map { _ in
            #"{"type":"user","message":{"role":"user","content":"first version"}}"#
        }.joined(separator: "\n") + "\n"
        try Data(long.utf8).write(to: url)

        let service = FilesystemClaudeSessionIndexService(configDirectory: dir)
        var sessions = try await service.indexedSessions()
        XCTAssertEqual(sessions[0].messageCount, 6)

        let short = #"{"type":"user","message":{"role":"user","content":"rewritten"}}"# + "\n"
        try Data(short.utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)

        sessions = try await service.indexedSessions()
        XCTAssertEqual(sessions[0].messageCount, 1, "shrunken file must be rescanned from the start")
        XCTAssertEqual(sessions[0].derivedLabel, "rewritten")
    }

    // MARK: - Session labels

    /// The rejected strings here are verbatim from real transcripts: two thirds of
    /// sessions have no title from Claude Code, and these are what the list was
    /// falling back to.
    func testSessionLabelRejectsHarnessScaffolding() {
        XCTAssertTrue(WorkbenchSessionLabel.isScaffolding(
            "<local-command-caveat>Caveat: The messages below were generated by the user while running local commands"))
        XCTAssertTrue(WorkbenchSessionLabel.isScaffolding(
            "<local-command-stdout>Cancelled</local-command-stdout>"))
        XCTAssertTrue(WorkbenchSessionLabel.isScaffolding(
            "<local-command-stdout>Set model to Fable 5 and saved as your default</local-command-stdout>"))
        XCTAssertTrue(WorkbenchSessionLabel.isScaffolding("<command-name>/clear</command-name>"))
        XCTAssertTrue(WorkbenchSessionLabel.isScaffolding("<command-message>pr-fix</command-message>"))
        XCTAssertTrue(WorkbenchSessionLabel.isScaffolding("   "))
        // Found by auditing the real corpus: these were becoming session titles.
        XCTAssertTrue(WorkbenchSessionLabel.isScaffolding(
            "<task-notification>\n<task-id>a4ad376a5bc2aed95</task-id>"))
        XCTAssertTrue(WorkbenchSessionLabel.isScaffolding("<bash-input>git stat</bash-input>"))
        XCTAssertTrue(WorkbenchSessionLabel.isScaffolding(
            "<bash-stdout></bash-stdout><bash-stderr>git: 'stat' is not a git command"))
        XCTAssertTrue(WorkbenchSessionLabel.isScaffolding("<system-reminder>be careful</system-reminder>"))

        // Pasted markup is real content the user typed, not scaffolding.
        XCTAssertFalse(WorkbenchSessionLabel.isScaffolding("<div>why does this not center</div>"))
        XCTAssertFalse(WorkbenchSessionLabel.isScaffolding("<html> tag rendering is broken"))

        XCTAssertNil(WorkbenchSessionLabel.label(for: "<local-command-stdout>Cancelled</local-command-stdout>"))
        XCTAssertNil(WorkbenchSessionLabel.label(for: nil))

        // A prompt that merely mentions a marker later on is still a real prompt.
        XCTAssertFalse(WorkbenchSessionLabel.isScaffolding(
            String(repeating: "explain this to me please ", count: 8) + "<command-name>"))
    }

    func testSessionLabelHoistsTicketAndDropsURL() {
        // Real shape: ClickUp URL, then the actual request.
        let label = WorkbenchSessionLabel.label(
            for: "https://app.clickup.com/t/42081486/CS-63034   你看看这个ticket 在讲什么 该怎么做")
        XCTAssertEqual(label, "CS-63034 · 你看看这个ticket 在讲什么 该怎么做")
        XCTAssertFalse(label?.contains("clickup.com") ?? true, "URL should be dropped")

        // GitHub pull requests read as repo#number.
        XCTAssertEqual(
            WorkbenchSessionLabel.label(
                for: "https://github.com/sugerio/marketplace-service/pull/6971 please use a worktree"),
            "marketplace-service#6971 · please use a worktree")

        // A ticket already leading the prompt must not be repeated.
        XCTAssertEqual(
            WorkbenchSessionLabel.label(for: "PE-11325 帮我看看这个ticket"),
            "PE-11325 · 帮我看看这个ticket")

        // Ticket with no other text stands alone.
        XCTAssertEqual(
            WorkbenchSessionLabel.label(for: "https://app.clickup.com/t/42081486/CS-54781"),
            "CS-54781")
    }

    func testSessionLabelNormalizesAndTruncates() {
        XCTAssertEqual(WorkbenchSessionLabel.label(for: "  commit 并开pr  "), "commit 并开pr")
        // Newlines and runs of spaces collapse so the label stays one line.
        XCTAssertEqual(
            WorkbenchSessionLabel.label(for: "fix the\n\nbug   in    parser"),
            "fix the bug in parser")

        let long = String(repeating: "long ", count: 60)
        let label = WorkbenchSessionLabel.label(for: long)
        XCTAssertNotNil(label)
        XCTAssertLessThanOrEqual(label!.count, WorkbenchSessionLabel.maxLength + 1)
        XCTAssertTrue(label!.hasSuffix("…"))
    }

    // MARK: - Transcript content search

    private func writeTranscript(_ lines: [String], to directory: URL, name: String) throws -> String {
        let url = directory.appendingPathComponent(name)
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    func testTranscriptSearchFindsContentAndBuildsProseSnippet() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wb-search-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let a = try writeTranscript([
            #"{"type":"user","message":{"role":"user","content":"why are the referrals stuck in pending create"}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Because the batch workflow collided."}]}}"#,
        ], to: dir, name: "a.jsonl")
        let b = try writeTranscript([
            #"{"type":"user","message":{"role":"user","content":"unrelated question about billing"}}"#,
        ], to: dir, name: "b.jsonl")

        let service = WorkbenchTranscriptSearchService()
        let targets = [
            WorkbenchTranscriptSearchService.Target(sessionId: "A", path: a, modifiedAt: Date()),
            WorkbenchTranscriptSearchService.Target(sessionId: "B", path: b, modifiedAt: Date()),
        ]

        let hits = try await service.search(query: "pending create", in: targets)
        XCTAssertEqual(hits.map(\.sessionId), ["A"])
        // Snippet is the message prose, not the raw JSON line.
        let snippet = hits[0].snippet
        XCTAssertTrue(snippet.localizedCaseInsensitiveContains("pending create"), snippet)
        XCTAssertFalse(snippet.contains("\"role\""), "snippet should not leak JSON: \(snippet)")

        // Case-insensitive, and matches in assistant turns count too.
        let both = try await service.search(query: "COLLIDED", in: targets)
        XCTAssertEqual(both.map(\.sessionId), ["A"])

        // Searching for an id usually hits a tool result payload, not conversation.
        // The snippet must still read as prose rather than escaped JSON.
        let c = try writeTranscript([
            #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"x","content":[{"type":"text","text":"{\"custom_id\":\"CS-61264\",\"name\":\"Referrals Stuck in Pending Create\"}"}]}]}}"#,
        ], to: dir, name: "c.jsonl")
        let payload = try await service.search(
            query: "CS-61264",
            in: [.init(sessionId: "C", path: c, modifiedAt: Date())])
        XCTAssertEqual(payload.map(\.sessionId), ["C"])
        let payloadSnippet = payload[0].snippet
        XCTAssertTrue(payloadSnippet.contains("CS-61264"), payloadSnippet)
        XCTAssertFalse(payloadSnippet.contains("\\\""), "escaped JSON leaked: \(payloadSnippet)")
        XCTAssertFalse(payloadSnippet.contains("tool_use_id"), "raw line leaked: \(payloadSnippet)")

        let absent = try await service.search(query: "nonexistent phrase", in: targets)
        XCTAssertTrue(absent.isEmpty)
        // Too short to be worth scanning a corpus for.
        let tooShort = try await service.search(query: "a", in: targets)
        XCTAssertTrue(tooShort.isEmpty)
    }

    func testTranscriptSearchRanksByMatchCountAndSpansChunkBoundaries() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wb-search2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let few = try writeTranscript([
            #"{"type":"user","message":{"role":"user","content":"tailscale once"}}"#,
        ], to: dir, name: "few.jsonl")
        let many = try writeTranscript((0..<5).map { _ in
            #"{"type":"user","message":{"role":"user","content":"tailscale again"}}"#
        }, to: dir, name: "many.jsonl")

        // A single line larger than the read chunk (256 KB), with the match past
        // the boundary — this is the case naive chunked scanning gets wrong.
        let padding = String(repeating: "x", count: 400_000)
        let huge = try writeTranscript([
            #"{"type":"user","message":{"role":"user","content":"\#(padding) tailscale buried deep"}}"#,
        ], to: dir, name: "huge.jsonl")

        let service = WorkbenchTranscriptSearchService()
        let now = Date()
        let hits = try await service.search(query: "tailscale", in: [
            .init(sessionId: "FEW", path: few, modifiedAt: now),
            .init(sessionId: "MANY", path: many, modifiedAt: now),
            .init(sessionId: "HUGE", path: huge, modifiedAt: now),
        ])

        XCTAssertEqual(Set(hits.map(\.sessionId)), ["FEW", "MANY", "HUGE"])
        XCTAssertEqual(hits.first?.sessionId, "MANY", "more matches should rank first")
        XCTAssertEqual(hits.first(where: { $0.sessionId == "MANY" })?.matchCount, 5)
        XCTAssertEqual(hits.first(where: { $0.sessionId == "FEW" })?.matchCount, 1)
    }

    // MARK: - Theme

    /// The whole point of deriving chrome colors from the terminal is that a dark
    /// terminal gets dark chrome. Luminance decides it — not the system
    /// appearance — so a light terminal theme while macOS is in dark mode still
    /// gets dark-on-light chrome, and vice versa.
    func testThemeDarknessFollowsBackgroundLuminanceNotSystemAppearance() {
        let dark = WorkbenchTheme(background: Color(red: 0.07, green: 0.07, blue: 0.10), opacity: 1, isDark: true)
        XCTAssertTrue(dark.isDark)

        // Derived via the real initializer path (luminance), for a range of colors.
        func isDark(_ red: Double, _ green: Double, _ blue: Double) -> Bool {
            WorkbenchTheme(
                background: Color(red: red, green: green, blue: blue),
                opacity: 1,
                isDark: WorkbenchTheme.backgroundIsDark(Color(red: red, green: green, blue: blue))
            ).isDark
        }

        XCTAssertTrue(isDark(0, 0, 0), "black background")
        XCTAssertTrue(isDark(0.07, 0.07, 0.10), "typical dark terminal theme")
        XCTAssertTrue(isDark(0.15, 0.11, 0.20), "dark purple theme")
        XCTAssertFalse(isDark(1, 1, 1), "white background")
        XCTAssertFalse(isDark(0.98, 0.96, 0.93), "solarized-light-ish background")

        // Green dominates perceived luminance, blue barely registers: pure blue is
        // dark, pure green is not. A naive average would get both wrong.
        XCTAssertTrue(isDark(0, 0, 1), "pure blue reads as dark")
        XCTAssertFalse(isDark(0, 1, 0), "pure green reads as light")
    }

    func testThemeClampsOpacityToStayLegible() {
        // A fully transparent terminal would otherwise leave unreadable chrome.
        XCTAssertEqual(WorkbenchTheme.clampOpacity(0), 0.35, accuracy: 0.001)
        XCTAssertEqual(WorkbenchTheme.clampOpacity(0.2), 0.35, accuracy: 0.001)
        XCTAssertEqual(WorkbenchTheme.clampOpacity(0.8), 0.8, accuracy: 0.001)
        XCTAssertEqual(WorkbenchTheme.clampOpacity(1), 1, accuracy: 0.001)
        XCTAssertEqual(WorkbenchTheme.clampOpacity(1.5), 1, accuracy: 0.001)
    }

    func testDensityDrivesRowPaddingAndSubtitle() {
        XCTAssertTrue(WorkbenchDensity.comfortable.showsSubtitle)
        XCTAssertFalse(WorkbenchDensity.compact.showsSubtitle)
        XCTAssertLessThan(WorkbenchDensity.compact.rowPadding, WorkbenchDensity.comfortable.rowPadding)
        XCTAssertEqual(WorkbenchDensity(rawValue: "compact"), .compact)
    }

    // MARK: - Transcript reader

    /// Shapes taken from a real transcript: plain-string user turns, assistant
    /// text/thinking/tool_use blocks, tool_result echoes on the user side, images,
    /// and the bookkeeping entry types that share the file.
    func testTranscriptParsesConversationAndSkipsNoise() {
        let jsonl = """
        {"type":"mode","mode":"auto"}
        {"type":"user","timestamp":"2026-07-22T10:00:00.000Z","message":{"role":"user","content":"fix the bug"}}
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","thinking":"internal reasoning"},{"type":"text","text":"On it."},{"type":"tool_use","name":"Bash","input":{"command":"go test ./...","description":"run tests"}}]}}
        {"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"x","content":[{"type":"text","text":"ok"}]}]}}
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Tests pass."}]}}
        {"type":"file-history-snapshot","snapshot":{}}
        {"type":"user","isSidechain":true,"message":{"role":"user","content":"subagent prompt"}}
        {"type":"user","isMeta":true,"message":{"role":"user","content":"injected meta"}}
        {"type":"user","message":{"role":"user","content":[{"type":"image","source":{}},{"type":"text","text":"see screenshot"}]}}
        """

        let messages = WorkbenchTranscriptService.parse(jsonl: jsonl)
        let rendered = messages.map { "\($0.kind)|\($0.toolName ?? "-")|\($0.text)" }
        XCTAssertEqual(rendered, [
            "user|-|fix the bug",
            "assistant|-|On it.",
            "tool|Bash|go test ./...",
            "assistant|-|Tests pass.",
            "user|-|[image]",
            "user|-|see screenshot",
        ])

        // Thinking, tool_result payloads, bookkeeping rows, subagent sidechains and
        // injected meta messages are all absent.
        XCTAssertFalse(rendered.contains { $0.contains("internal reasoning") })
        XCTAssertFalse(rendered.contains { $0.contains("ok") })
        XCTAssertFalse(rendered.contains { $0.contains("subagent") })
        XCTAssertFalse(rendered.contains { $0.contains("injected") })

        // Timestamps with fractional seconds parse.
        XCTAssertNotNil(messages.first?.timestamp)
        // Ids are contiguous for stable SwiftUI identity.
        XCTAssertEqual(messages.map(\.id), Array(0..<messages.count))
    }

    func testTranscriptKeepsOnlyTheTailAndPrefersUsefulToolArgument() {
        let lines = (0..<50).map { index in
            #"{"type":"user","message":{"role":"user","content":"message \#(index)"}}"#
        }.joined(separator: "\n")

        let messages = WorkbenchTranscriptService.parse(jsonl: lines, limit: 10)
        XCTAssertEqual(messages.count, 10)
        // The *last* 10, renumbered from zero.
        XCTAssertEqual(messages.first?.text, "message 40")
        XCTAssertEqual(messages.last?.text, "message 49")
        XCTAssertEqual(messages.first?.id, 0)

        // file_path wins over other string values for an edit-shaped tool call.
        let edit = WorkbenchTranscriptService.parse(jsonl: #"""
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Edit","input":{"old_string":"a","file_path":"/repo/main.go","new_string":"b"}}]}}
        """#)
        XCTAssertEqual(edit.first?.toolName, "Edit")
        XCTAssertEqual(edit.first?.text, "/repo/main.go")

        // Newlines are collapsed and long arguments truncated so a tool line stays
        // one line.
        let long = WorkbenchTranscriptService.parse(jsonl: #"""
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{"command":"line one\nline two \#(String(repeating: "x", count: 200))"}}]}}
        """#)
        XCTAssertFalse(long.first?.text.contains("\n") ?? true)
        XCTAssertTrue(long.first?.text.hasSuffix("…") ?? false)
        XCTAssertLessThanOrEqual(long.first?.text.count ?? 999, 121)
    }

    func testTranscriptMissingFileIsEmptyAndCacheHonorsPath() {
        let service = WorkbenchTranscriptService()
        XCTAssertTrue(service.messages(atPath: "/nope/missing.jsonl").isEmpty)

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wb-tx-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let a = dir.appendingPathComponent("a.jsonl")
        let b = dir.appendingPathComponent("b.jsonl")
        try? #"{"type":"user","message":{"role":"user","content":"from A"}}"#
            .write(to: a, atomically: true, encoding: .utf8)
        try? #"{"type":"user","message":{"role":"user","content":"from B"}}"#
            .write(to: b, atomically: true, encoding: .utf8)

        XCTAssertEqual(service.messages(atPath: a.path).first?.text, "from A")
        // A different path must not return the cached result for the previous one.
        XCTAssertEqual(service.messages(atPath: b.path).first?.text, "from B")
        XCTAssertEqual(service.messages(atPath: a.path).first?.text, "from A")

        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Hook installer

    private func makeInstaller() -> (WorkbenchHookInstaller, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wb-claude-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var installer = WorkbenchHookInstaller()
        installer.claudeDirectory = root
        return (installer, root)
    }

    private func readHooks(_ installer: WorkbenchHookInstaller) throws -> [String: Any] {
        let data = try Data(contentsOf: installer.settingsURL)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return object?["hooks"] as? [String: Any] ?? [:]
    }

    /// The critical safety property: installing must not disturb hooks another tool
    /// already registered (the user's real settings.json has several), and must
    /// leave unrelated top-level settings untouched.
    func testHookInstallMergesWithoutClobberingForeignHooks() throws {
        let (installer, _) = makeInstaller()
        let existing = """
        {
          "model": "opus",
          "hooks": {
            "Stop": [
              { "hooks": [ { "type": "command", "command": "/other/tool-bridge" } ] }
            ],
            "PostToolUse": [
              { "matcher": "Edit|Write", "hooks": [ { "type": "command", "command": "/other/vet.sh" } ] }
            ]
          }
        }
        """
        try existing.write(to: installer.settingsURL, atomically: true, encoding: .utf8)

        XCTAssertFalse(installer.isInstalled)
        try installer.install()
        XCTAssertTrue(installer.isInstalled)

        let hooks = try readHooks(installer)

        // Foreign Stop hook survives, ours is appended alongside it.
        let stop = hooks["Stop"] as? [[String: Any]] ?? []
        XCTAssertEqual(stop.count, 2)
        let stopCommands = stop.flatMap { ($0["hooks"] as? [[String: Any]] ?? []) }
            .compactMap { $0["command"] as? String }
        XCTAssertTrue(stopCommands.contains { $0.contains("/other/tool-bridge") })
        XCTAssertTrue(stopCommands.contains { $0.contains(installer.scriptURL.path) })

        // An event we manage that the user never had is created.
        XCTAssertNotNil(hooks["SessionEnd"])
        // An event we don't manage is left exactly as it was.
        let postToolUse = hooks["PostToolUse"] as? [[String: Any]] ?? []
        XCTAssertEqual(postToolUse.count, 1)

        // Unrelated settings preserved.
        let data = try Data(contentsOf: installer.settingsURL)
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(root?["model"] as? String, "opus")

        // A backup of the pre-change file exists.
        let backups = try FileManager.default
            .contentsOfDirectory(atPath: installer.settingsURL.deletingLastPathComponent().path)
            .filter { $0.hasPrefix("settings.json.workbench-backup-") }
        XCTAssertFalse(backups.isEmpty)
    }

    func testHookInstallIsIdempotent() throws {
        let (installer, _) = makeInstaller()
        try installer.install()
        let first = try readHooks(installer)
        try installer.install()
        let second = try readHooks(installer)

        for event in WorkbenchHookInstaller.events {
            let a = (first[event] as? [[String: Any]])?.count ?? 0
            let b = (second[event] as? [[String: Any]])?.count ?? 0
            XCTAssertEqual(a, b, "duplicate hook group added for \(event)")
            XCTAssertEqual(a, 1)
        }
    }

    func testHookUninstallRemovesOnlyOurEntries() throws {
        let (installer, _) = makeInstaller()
        try """
        { "hooks": { "Stop": [ { "hooks": [ { "type": "command", "command": "/other/tool-bridge" } ] } ] } }
        """.write(to: installer.settingsURL, atomically: true, encoding: .utf8)

        try installer.install()
        try installer.uninstall()

        XCTAssertFalse(installer.isInstalled)
        let hooks = try readHooks(installer)
        // Foreign hook still there; our events are gone.
        let stopCommands = (hooks["Stop"] as? [[String: Any]] ?? [])
            .flatMap { ($0["hooks"] as? [[String: Any]] ?? []) }
            .compactMap { $0["command"] as? String }
        XCTAssertEqual(stopCommands, ["/other/tool-bridge"])
        XCTAssertNil(hooks["SessionEnd"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: installer.scriptURL.path))
    }

    /// Runs the real bridge script the installer writes, to prove a hook payload
    /// piped on stdin lands in the events directory as a complete `.json` file.
    func testHookBridgeScriptWritesEventFile() throws {
        let (installer, _) = makeInstaller()
        try installer.install()
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: installer.scriptURL.path))

        // The script derives its output directory from $HOME, so point HOME at a
        // temp root and read from the same place it will write.
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("wb-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let eventsDir = home
            .appendingPathComponent("Library/Application Support/GhosttyClaudeWorkbench/events",
                                   isDirectory: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [installer.scriptURL.path]
        process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        let stdin = Pipe()
        process.standardInput = stdin
        try process.run()
        let payload = #"{"session_id":"sess-1","hook_event_name":"Stop","cwd":"/repo"}"#
        stdin.fileHandleForWriting.write(Data(payload.utf8))
        try stdin.fileHandleForWriting.close()
        process.waitUntilExit()

        // Never block or fail a Claude session.
        XCTAssertEqual(process.terminationStatus, 0)

        let service = WorkbenchAgentEventService(directory: eventsDir)
        let events = service.drain()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.sessionId, "sess-1")
        XCTAssertEqual(events.first?.state, .idle)
        XCTAssertEqual(events.first?.cwd, "/repo")

        try? FileManager.default.removeItem(at: home)
    }
}
