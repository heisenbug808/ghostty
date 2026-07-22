import Foundation

/// Persists which sidebar worktree groups are collapsed, keyed by the group's
/// stable id (worktree toplevel / cwd / the no-cwd sentinel). Stored in
/// `UserDefaults` so collapse state survives refreshes and app relaunches.
struct WorkbenchGroupCollapseStore {
    static let defaultsKey = "Workbench.CollapsedGroups"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> Set<String> {
        Set(defaults.stringArray(forKey: Self.defaultsKey) ?? [])
    }

    func save(_ ids: Set<String>) {
        if ids.isEmpty {
            defaults.removeObject(forKey: Self.defaultsKey)
        } else {
            defaults.set(Array(ids), forKey: Self.defaultsKey)
        }
    }
}
