import Foundation

enum WorkbenchLaunchMode: Hashable, Sendable {
    case new(projectPath: String, prompt: String?)
    case resume(sessionId: String, cwd: String?)
    case fork(sessionId: String, cwd: String?)
    case continueLatest(cwd: String?)
    case worktree(projectPath: String, name: String, prompt: String?)
}

struct WorkbenchLaunchRequest: Hashable, Sendable {
    var id: String = UUID().uuidString
    var mode: WorkbenchLaunchMode
    var claudeExecutable: String = "claude"
}

struct WorkbenchBuiltLaunch: Hashable, Sendable {
    var launchId: String
    var command: String
    var workingDirectory: String?
    var displayCommand: String
    var sessionId: String?
}

final class WorkbenchLauncherService {
    func build(_ request: WorkbenchLaunchRequest) -> WorkbenchBuiltLaunch {
        let args = claudeArguments(for: request.mode, executable: request.claudeExecutable)
        let displayCommand = shellJoin(args)
        return WorkbenchBuiltLaunch(
            launchId: request.id,
            command: loginShellWrapped(displayCommand),
            workingDirectory: workingDirectory(for: request.mode),
            displayCommand: displayCommand,
            sessionId: sessionId(for: request.mode)
        )
    }

    /// Wraps the command in the user's login shell so a GUI-launched app (which
    /// starts with launchd's minimal PATH) still resolves `claude` and friends via
    /// the user's shell profile (`~/.zprofile`, `~/.zshrc`, …). Without this, an app
    /// opened from the Dock/Finder fails with `claude: not found`.
    ///
    /// It also clears `CLAUDE_CODE_CHILD_SESSION`, which Claude Code sets in every
    /// subprocess environment. If the Workbench app was itself launched from inside a
    /// Claude session, that marker would otherwise be inherited by the sessions we
    /// spawn, making them "child sessions" — which disables transcript saving and
    /// skips the `~/.claude/sessions` registration the sidebar relies on for live
    /// status. Workbench sessions are first-class, so we strip the marker.
    private func loginShellWrapped(_ command: String) -> String {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        return "\(shellQuote(shell)) -l -c \(shellQuote("unset CLAUDE_CODE_CHILD_SESSION; exec " + command))"
    }

    private func claudeArguments(for mode: WorkbenchLaunchMode, executable: String) -> [String] {
        switch mode {
        case .new(_, let prompt):
            var args = [executable]
            if let prompt, !prompt.isEmpty { args.append(prompt) }
            return args
        case .resume(let id, _):
            return [executable, "--resume", id]
        case .fork(let id, _):
            return [executable, "--resume", id, "--fork-session"]
        case .continueLatest:
            return [executable, "--continue"]
        case .worktree(_, let name, let prompt):
            var args = [executable, "--worktree", name]
            if let prompt, !prompt.isEmpty { args.append(prompt) }
            return args
        }
    }

    private func workingDirectory(for mode: WorkbenchLaunchMode) -> String? {
        switch mode {
        case .new(let projectPath, _), .worktree(let projectPath, _, _): return projectPath
        case .resume(_, let cwd), .fork(_, let cwd), .continueLatest(let cwd): return cwd
        }
    }

    private func sessionId(for mode: WorkbenchLaunchMode) -> String? {
        switch mode {
        case .resume(let id, _), .fork(let id, _): return id
        default: return nil
        }
    }

    private func shellJoin(_ arguments: [String]) -> String {
        arguments.map(shellQuote).joined(separator: " ")
    }

    private func shellQuote(_ value: String) -> String {
        guard !value.isEmpty else { return "''" }
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_+-./:=@")
        if value.unicodeScalars.allSatisfy({ safe.contains($0) }) { return value }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
