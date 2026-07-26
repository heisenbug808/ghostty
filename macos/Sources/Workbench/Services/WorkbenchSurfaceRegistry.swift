#if os(macOS)
import AppKit
import Foundation

/// Best-effort mapping from Workbench sessions/launches to Ghostty windows.
///
/// This is intentionally window-level for the MVP because Ghostty's public app
/// integration already returns/focuses `TerminalController` / `NSWindow` more
/// easily than individual surface objects. Later this can be narrowed to a
/// concrete surface UUID if needed.
@MainActor
final class WorkbenchSurfaceRegistry: ObservableObject {
    static let shared = WorkbenchSurfaceRegistry()

    final class Entry {
        let sessionId: String
        let launchId: String
        weak var window: NSWindow?

        init(sessionId: String, launchId: String, window: NSWindow?) {
            self.sessionId = sessionId
            self.launchId = launchId
            self.window = window
        }
    }

    private var entriesBySession: [String: Entry] = [:]
    private var entriesByLaunch: [String: Entry] = [:]

    func register(sessionId: String, launchId: String, window: NSWindow?) {
        guard let window else { return }
        // Drop any prior launch entry for this session so re-registering under a new
        // launchId doesn't orphan the old one in entriesByLaunch.
        if let previous = entriesBySession[sessionId] {
            entriesByLaunch.removeValue(forKey: previous.launchId)
        }
        let entry = Entry(sessionId: sessionId, launchId: launchId, window: window)
        entriesBySession[sessionId] = entry
        entriesByLaunch[launchId] = entry
    }

    /// The session running in a given window, if any — used to drive the sidebar
    /// highlight from whichever terminal tab is focused.
    func sessionId(for window: NSWindow) -> String? {
        for entry in entriesBySession.values where entry.window === window {
            return entry.sessionId
        }
        return nil
    }

    /// Whether Workbench has a live window for this session.
    ///
    /// A session can be running without one — started from Claude Desktop, another
    /// terminal, or a daemon-hosted background agent. Those can't be focused or
    /// resumed (a second process would fight over the same transcript), so the UI
    /// offers different actions for them.
    func hasWindow(sessionId: String) -> Bool {
        cleanupStaleEntries()
        return entriesBySession[sessionId]?.window != nil
    }

    func focusExisting(sessionId: String) -> Bool {
        cleanupStaleEntries()
        guard let window = entriesBySession[sessionId]?.window else { return false }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    func unregister(launchId: String) {
        guard let entry = entriesByLaunch.removeValue(forKey: launchId) else { return }
        if entriesBySession[entry.sessionId]?.launchId == launchId {
            entriesBySession.removeValue(forKey: entry.sessionId)
        }
    }

    func cleanupStaleEntries() {
        entriesBySession = entriesBySession.filter { _, entry in entry.window != nil }
        entriesByLaunch = entriesByLaunch.filter { _, entry in entry.window != nil }
    }
}
#endif
