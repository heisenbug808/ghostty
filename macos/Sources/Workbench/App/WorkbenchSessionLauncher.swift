#if os(macOS)
import AppKit
import GhosttyKit

/// Opens a Claude Workbench session in a Ghostty tab. Shared by the sidebar and
/// Ghostty's native command palette so both drive the same focus-existing +
/// resume + surface-registration path.
@MainActor
enum WorkbenchSessionLauncher {
    /// Focuses the session's existing window if it's running and registered;
    /// otherwise resumes it in a new tab (respecting the per-session lock). No-op
    /// if the launch is blocked (e.g. already locked).
    static func open(
        _ session: WorkbenchSessionRecord,
        ghostty: Ghostty.App,
        from parent: NSWindow?
    ) async {
        if session.status == .running,
           WorkbenchSurfaceRegistry.shared.focusExisting(sessionId: session.id) {
            return
        }

        let decision = await WorkbenchViewModel.shared.prepareLaunchRequest(
            mode: .resume(sessionId: session.id, cwd: session.cwd)
        )
        guard case let .proceed(request) = decision else { return }

        let built = WorkbenchLauncherService().build(request)
        var config = Ghostty.SurfaceConfiguration()
        config.workingDirectory = built.workingDirectory
        config.command = built.command
        config.waitAfterCommand = true
        config.environmentVariables["GHOSTTY_WORKBENCH_LAUNCH_ID"] = built.launchId
        if let sessionId = built.sessionId {
            config.environmentVariables["GHOSTTY_WORKBENCH_SESSION_ID"] = sessionId
        }
        let controller = TerminalController.newTab(ghostty, from: parent, withBaseConfig: config)
        if let sessionId = built.sessionId {
            WorkbenchSurfaceRegistry.shared.register(
                sessionId: sessionId, launchId: built.launchId, window: controller?.window)
        }
    }
}
#endif
