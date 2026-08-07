#if os(macOS)
import AppKit
import SwiftUI

/// Keys the sidebar handles while the search field has focus.
enum WorkbenchKey {
    case up
    case down
    case enter
    case escape
}

/// Routes a few keys to the session list while the search field is focused, so a
/// session can be found and opened without touching the mouse: type to filter,
/// arrow through matches, Enter to open, Escape to clear.
///
/// `onKeyPress` would be the natural way to do this, but it's macOS 14+ and this
/// app still targets 13.0, so it goes through an AppKit event monitor.
///
/// The monitor is app-wide, which matters a great deal here: the rest of the
/// window is a terminal, and swallowing arrow keys would break shell history. It
/// therefore consumes an event only while `isActive` (the search field is focused)
/// *and* the key is one of the four above — everything else is passed straight
/// through, so a focused terminal behaves exactly as it does in stock Ghostty.
struct WorkbenchKeyMonitor: NSViewRepresentable {
    var isActive: Bool
    /// Returns true when the key was handled and should not propagate.
    var onKey: (WorkbenchKey) -> Bool

    func makeNSView(context: Context) -> NSView {
        context.coordinator.start()
        return NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.isActive = isActive
        context.coordinator.onKey = onKey
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(isActive: isActive, onKey: onKey)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator {
        var isActive: Bool
        var onKey: (WorkbenchKey) -> Bool
        private var monitor: Any?

        init(isActive: Bool, onKey: @escaping (WorkbenchKey) -> Bool) {
            self.isActive = isActive
            self.onKey = onKey
        }

        func start() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.isActive else { return event }
                // Modified keys belong to whatever the user actually bound them to.
                let modifiers: NSEvent.ModifierFlags = [.command, .control, .option]
                guard event.modifierFlags.isDisjoint(with: modifiers) else { return event }

                let key: WorkbenchKey
                switch event.keyCode {
                case 126: key = .up
                case 125: key = .down
                case 36, 76: key = .enter   // Return, Enter
                case 53: key = .escape
                default: return event
                }
                return self.onKey(key) ? nil : event
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        deinit { stop() }
    }
}
#endif
