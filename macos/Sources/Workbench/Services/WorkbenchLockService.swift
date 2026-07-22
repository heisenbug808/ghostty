import Foundation

actor WorkbenchLockService {
    private let store: WorkbenchStore

    init(store: WorkbenchStore) {
        self.store = store
    }

    func currentLock(for sessionId: String) async throws -> WorkbenchSessionLock? {
        try await store.loadSnapshot().locks[sessionId]
    }

    func acquire(sessionId: String, launchId: String, pid: Int32? = nil) async throws -> WorkbenchSessionLock {
        let lock = WorkbenchSessionLock(sessionId: sessionId, launchId: launchId, pid: pid, acquiredAt: Date())
        try await store.updateLock(lock, for: sessionId)
        return lock
    }

    func release(sessionId: String) async throws {
        try await store.updateLock(nil, for: sessionId)
    }
}

extension WorkbenchSessionLock {
    /// A lock is stale once its session is neither running nor backed by a live
    /// PID and enough time has passed for a launched `claude` to have registered
    /// itself. The grace window avoids releasing a lock during process boot.
    func isStale(isRunning: Bool, pidAlive: Bool, now: Date, grace: TimeInterval) -> Bool {
        !isRunning && !pidAlive && now.timeIntervalSince(acquiredAt) > grace
    }
}
