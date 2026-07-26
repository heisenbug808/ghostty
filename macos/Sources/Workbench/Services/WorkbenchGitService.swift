import Foundation

/// Git facts about a session's working directory, used to aggregate sessions by
/// repository and worktree in the sidebar. Transient — recomputed on refresh,
/// never persisted as Workbench-owned data.
struct WorkbenchGitInfo: Sendable, Hashable {
    /// Working-tree root (`git rev-parse --show-toplevel`).
    var toplevel: String
    /// Repo identity: the resolved common git dir, shared by all worktrees of one
    /// clone. Two separate clones of the same remote have distinct keys.
    var repoKey: String
    var branch: String?
    var dirty: Int?
    /// "org/repo" derived from the origin remote, if any.
    var originName: String?
    /// True when `toplevel` is a linked worktree rather than the main checkout.
    var isLinkedWorktree: Bool
}

protocol WorkbenchGitReading: AnyObject, Sendable {
    func info(forCwd cwd: String) async -> WorkbenchGitInfo?
}

// Stateless (no stored properties), so safe to call concurrently from a task group.
final class WorkbenchGitService: WorkbenchGitReading {
    func info(forCwd cwd: String) async -> WorkbenchGitInfo? {
        guard let out = run(
            ["rev-parse", "--show-toplevel", "--git-common-dir", "--abbrev-ref", "HEAD"],
            atCwd: cwd
        ) else { return nil }

        let lines = out.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count >= 3, !lines[0].isEmpty else { return nil }
        let toplevel = lines[0]
        let branch = lines[2] == "HEAD" ? nil : lines[2]

        let commonRaw = lines[1]
        let repoKey = commonRaw.hasPrefix("/")
            ? URL(fileURLWithPath: commonRaw).standardizedFileURL.path
            : URL(fileURLWithPath: commonRaw, relativeTo: URL(fileURLWithPath: cwd, isDirectory: true))
                .standardizedFileURL.path

        let dirty = run(["status", "--porcelain"], atCwd: toplevel).map {
            $0.isEmpty ? 0 : $0.split(separator: "\n").count
        }
        let originName = run(["remote", "get-url", "origin"], atCwd: toplevel)
            .flatMap(Self.originName)

        // A linked worktree stores `.git` as a file (a gitdir pointer), not a dir.
        var isDir: ObjCBool = false
        let dotGit = URL(fileURLWithPath: toplevel).appendingPathComponent(".git").path
        let exists = FileManager.default.fileExists(atPath: dotGit, isDirectory: &isDir)
        let isLinked = exists && !isDir.boolValue

        return WorkbenchGitInfo(
            toplevel: toplevel,
            repoKey: repoKey,
            branch: branch,
            dirty: dirty,
            originName: originName,
            isLinkedWorktree: isLinked
        )
    }

    /// "org/repo" from either scp-style (`git@host:org/repo.git`) or URL-style
    /// (`https://host/org/repo.git`) remotes.
    static func originName(_ url: String) -> String? {
        var value = url
        if value.hasSuffix(".git") { value = String(value.dropLast(4)) }
        let afterColon = value.split(separator: ":").last.map(String.init) ?? value
        let comps = afterColon.split(separator: "/").map(String.init)
        guard comps.count >= 2 else { return comps.last }
        return comps.suffix(2).joined(separator: "/")
    }

    private func run(_ args: [String], atCwd cwd: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", cwd] + args
        // A Finder-launched app has a minimal PATH; widen it so `git` resolves.
        var env = ProcessInfo.processInfo.environment
        let extra = "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"
        env["PATH"] = env["PATH"].map { "\($0):\(extra)" } ?? extra
        process.environment = env
        let stdout = Pipe()
        process.standardOutput = stdout
        // Discard stderr to /dev/null rather than an unread Pipe: a Pipe that git
        // fills past its ~64KB buffer would block git's write while we block on
        // reading stdout — a deadlock. We never use stderr anyway.
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Grouping

/// A worktree node in the sidebar tree: one working-tree root with its sessions.
/// Non-git working directories become single-node "repos" keyed by the path.
struct WorkbenchWorktreeGroup: Identifiable, Hashable {
    var id: String
    var repoKey: String
    var repoName: String
    var path: String
    var branch: String?
    var dirty: Int?
    var isLinkedWorktree: Bool
    var isGit: Bool
    var sessions: [WorkbenchSessionRecord]

    var runningCount: Int { sessions.filter { $0.status == .running }.count }
    var lastModified: Date { sessions.compactMap(\.lastModifiedAt).max() ?? .distantPast }
}

enum WorkbenchWorktreeGrouping {
    private static let noCwdKey = "\u{0}no-cwd"

    /// Groups sessions into repo -> worktree order. Sessions in the same working
    /// tree (or the same subdir of it) collapse into one group; worktrees of one
    /// repo cluster together, and repos are ordered by most-recent activity.
    static func groups(
        sessions: [WorkbenchSessionRecord],
        gitInfo: [String: WorkbenchGitInfo]
    ) -> [WorkbenchWorktreeGroup] {
        var byWorktree: [String: WorkbenchWorktreeGroup] = [:]
        for session in sessions {
            let key: String
            let group: WorkbenchWorktreeGroup
            if let cwd = session.cwd, let info = gitInfo[cwd] {
                key = info.toplevel
                group = byWorktree[key] ?? WorkbenchWorktreeGroup(
                    id: info.toplevel, repoKey: info.repoKey,
                    repoName: info.originName ?? URL(fileURLWithPath: info.toplevel).lastPathComponent,
                    path: info.toplevel, branch: info.branch, dirty: info.dirty,
                    isLinkedWorktree: info.isLinkedWorktree, isGit: true, sessions: [])
            } else if let cwd = session.cwd {
                key = cwd
                group = byWorktree[key] ?? WorkbenchWorktreeGroup(
                    id: cwd, repoKey: cwd,
                    repoName: URL(fileURLWithPath: cwd).lastPathComponent,
                    path: cwd, branch: nil, dirty: nil,
                    isLinkedWorktree: false, isGit: false, sessions: [])
            } else {
                key = noCwdKey
                group = byWorktree[key] ?? WorkbenchWorktreeGroup(
                    id: noCwdKey, repoKey: noCwdKey, repoName: "No working directory",
                    path: "", branch: nil, dirty: nil,
                    isLinkedWorktree: false, isGit: false, sessions: [])
            }
            var updated = group
            updated.sessions.append(session)
            byWorktree[key] = updated
        }

        // Sort sessions inside each group: running first, then pinned, then most
        // recent. Running is surfaced above pinned because an in-progress Claude
        // session is the most time-sensitive thing to return to.
        for key in byWorktree.keys {
            byWorktree[key]?.sessions.sort { lhs, rhs in
                let lhsRunning = lhs.status == .running
                let rhsRunning = rhs.status == .running
                if lhsRunning != rhsRunning { return lhsRunning }
                if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
                return (lhs.lastModifiedAt ?? lhs.updatedAt) > (rhs.lastModifiedAt ?? rhs.updatedAt)
            }
        }

        // Order: repos by most-recent activity, worktrees of a repo adjacent
        // (main checkout before linked worktrees), no-cwd bucket last.
        let repoRecency = Dictionary(
            byWorktree.values.map { ($0.repoKey, $0.lastModified) },
            uniquingKeysWith: max)
        return byWorktree.values.sorted { lhs, rhs in
            if lhs.repoKey != rhs.repoKey {
                let lr = lhs.id == noCwdKey ? Date.distantPast : (repoRecency[lhs.repoKey] ?? .distantPast)
                let rr = rhs.id == noCwdKey ? Date.distantPast : (repoRecency[rhs.repoKey] ?? .distantPast)
                if lr != rr { return lr > rr }
                return lhs.repoKey < rhs.repoKey
            }
            if lhs.isLinkedWorktree != rhs.isLinkedWorktree { return !lhs.isLinkedWorktree }
            return lhs.lastModified > rhs.lastModified
        }
    }
}
