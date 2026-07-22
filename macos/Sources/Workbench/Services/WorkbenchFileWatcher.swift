import Foundation
import CoreServices

/// Watches directories (recursively) for changes and invokes `onChange`,
/// debounced, so the Workbench can live-update running-state and newly created
/// sessions without a manual refresh. Read-only: it observes, never writes.
final class WorkbenchFileWatcher {
    private let paths: [String]
    private let debounce: TimeInterval
    private let onChange: @Sendable () -> Void
    private let queue = DispatchQueue(label: "cloud.suger.workbench.fswatch")
    private var stream: FSEventStreamRef?
    private var pending: DispatchWorkItem?

    init(paths: [String], debounce: TimeInterval = 0.6, onChange: @escaping @Sendable () -> Void) {
        self.paths = paths
        self.debounce = debounce
        self.onChange = onChange
    }

    func start() {
        queue.async { [weak self] in self?.startLocked() }
    }

    func stop() {
        queue.async { [weak self] in self?.stopLocked() }
    }

    deinit { stopLocked() }

    // MARK: - Queue-isolated

    private func startLocked() {
        guard stream == nil, !paths.isEmpty else { return }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<WorkbenchFileWatcher>.fromOpaque(info)
                .takeUnretainedValue()
                .scheduleDebounced()
        }

        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.3, // coalescing latency
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagFileEvents))
        else { return }

        FSEventStreamSetDispatchQueue(created, queue)
        FSEventStreamStart(created)
        stream = created
    }

    private func stopLocked() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    /// Called on `queue` from the FSEvents callback. Coalesce bursts (e.g. a
    /// transcript being written rapidly) into a single trailing `onChange`.
    private func scheduleDebounced() {
        pending?.cancel()
        let work = DispatchWorkItem { [onChange] in onChange() }
        pending = work
        queue.asyncAfter(deadline: .now() + debounce, execute: work)
    }
}
