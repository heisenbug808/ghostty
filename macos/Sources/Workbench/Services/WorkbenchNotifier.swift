#if os(macOS)
import AppKit
import UserNotifications

/// Posts macOS notifications when a Claude session finishes its turn or needs
/// input, driven by the hook events — so a session working in a background tab or
/// another window can tell you it's done without you watching it.
///
/// This is intentionally *not* a `UNUserNotificationCenterDelegate`: Ghostty's
/// `AppDelegate` already owns that role for terminal notifications. Instead we tag
/// our notifications with `workbenchSessionId` in `userInfo`, and AppDelegate hands
/// those back to us via `isWorkbenchNotification` / `handle(response:)`.
@MainActor
final class WorkbenchNotifier: ObservableObject {
    static let shared = WorkbenchNotifier()

    static let notifyOnCompleteKey = "Workbench.NotifyOnComplete"
    static let notifyOnAwaitingInputKey = "Workbench.NotifyOnAwaitingInput"
    /// `nonisolated` because `workbenchSessionId(from:)` reads it from AppDelegate's
    /// notification callbacks, which aren't main-actor isolated.
    private nonisolated static let sessionIdKey = "workbenchSessionId"

    /// Default on, matching what you'd want from a background agent: tell me when
    /// it's done, and tell me when it's stuck waiting for me.
    static var notifyOnComplete: Bool {
        get { UserDefaults.standard.object(forKey: notifyOnCompleteKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: notifyOnCompleteKey) }
    }

    static var notifyOnAwaitingInput: Bool {
        get { UserDefaults.standard.object(forKey: notifyOnAwaitingInputKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: notifyOnAwaitingInputKey) }
    }

    private var didRequestAuthorization = false

    /// Whether the system will actually show what we post. Notifications failing
    /// silently — denied permission, or Do Not Disturb — is indistinguishable from
    /// a broken pipeline from the user's side, so the settings menu reports it.
    @Published private(set) var permission: Permission = .unknown

    enum Permission {
        case unknown
        case allowed
        case denied
        case notRequested

        var summary: String? {
            switch self {
            case .allowed, .unknown: return nil
            case .denied: return "Notifications are turned off for Workbench in System Settings"
            case .notRequested: return "Notifications not enabled yet"
            }
        }
    }

    func requestAuthorizationIfNeeded() {
        guard !didRequestAuthorization else { return }
        didRequestAuthorization = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in
            Task { @MainActor in self.refreshPermission() }
        }
    }

    /// Reads the current authorization so the UI can say why nothing is appearing.
    func refreshPermission() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let permission: Permission
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral: permission = .allowed
            case .denied: permission = .denied
            case .notDetermined: permission = .notRequested
            @unknown default: permission = .unknown
            }
            Task { @MainActor in self.permission = permission }
        }
    }

    /// Opens the pane where the user can turn notifications back on.
    func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications")
        else { return }
        NSWorkspace.shared.open(url)
    }

    /// Notifies for a state transition. `title` is the session's display title.
    ///
    /// Suppressed when the session's own window is already focused — you're looking
    /// right at it, so a banner is noise.
    func notify(sessionId: String, title: String, state: WorkbenchAgentState, cwd: String?) {
        let body: String
        switch state {
        case .idle:
            guard Self.notifyOnComplete else { return }
            body = "Finished — waiting on you"
        case .awaitingInput:
            guard Self.notifyOnAwaitingInput else { return }
            body = "Needs your approval"
        case .working, .ended:
            return
        }

        guard !isSessionWindowFocused(sessionId) else { return }
        requestAuthorizationIfNeeded()

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = cwd.map { "\(body) · \(($0 as NSString).lastPathComponent)" } ?? body
        content.sound = .default
        content.userInfo = [Self.sessionIdKey: sessionId]

        // One live notification per session: a newer state replaces the older one
        // instead of stacking up.
        let request = UNNotificationRequest(
            identifier: "workbench.session.\(sessionId)",
            content: content,
            trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    func clear(sessionId: String) {
        UNUserNotificationCenter.current()
            .removeDeliveredNotifications(withIdentifiers: ["workbench.session.\(sessionId)"])
    }

    // MARK: - AppDelegate bridge

    /// The Workbench session a notification belongs to, or nil if it isn't ours.
    /// `nonisolated` so `AppDelegate`'s notification-center callbacks (which are not
    /// main-actor isolated) can check ownership before hopping to the main actor.
    nonisolated static func workbenchSessionId(from notification: UNNotification) -> String? {
        notification.request.content.userInfo[sessionIdKey] as? String
    }

    /// Reveals a session after its notification is tapped: focus the window if
    /// Workbench opened one, otherwise just surface the app with it selected.
    func focus(sessionId: String) {
        clear(sessionId: sessionId)
        WorkbenchViewModel.shared.selectedSessionID = sessionId
        WorkbenchViewModel.shared.expandGroupContaining(sessionId)
        if !WorkbenchSurfaceRegistry.shared.focusExisting(sessionId: sessionId) {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func isSessionWindowFocused(_ sessionId: String) -> Bool {
        guard let window = NSApp.keyWindow else { return false }
        return WorkbenchSurfaceRegistry.shared.sessionId(for: window) == sessionId
    }
}
#endif
