import Foundation

/// Compile-time and user-default controlled feature gate for the Claude Workbench.
///
/// The MVP keeps the integration behind a runtime toggle so a Workbench build can
/// still behave like stock Ghostty while the feature is incomplete.
enum WorkbenchFeature {
    static let enabledKey = "Workbench.Enabled"
    static let sidebarVisibleKey = "Workbench.SidebarVisible"
    static let sidebarWidthKey = "Workbench.SidebarWidth"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    static var isSidebarVisible: Bool {
        get { UserDefaults.standard.object(forKey: sidebarVisibleKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: sidebarVisibleKey) }
    }

    static var sidebarWidth: Double {
        get {
            let value = UserDefaults.standard.double(forKey: sidebarWidthKey)
            return value > 0 ? value : 280
        }
        set { UserDefaults.standard.set(max(220, min(420, newValue)), forKey: sidebarWidthKey) }
    }
}
