#if os(macOS)
import AppKit
import SwiftUI

/// Colors for Workbench chrome, derived from the terminal's own theme.
///
/// The sidebar and details panel used to paint themselves with system control
/// colors, which meant a dark terminal sat next to a light gray panel and the
/// whole thing read as a SwiftUI view bolted onto Ghostty rather than part of it.
/// Everything here comes from the same `background` / `background-opacity` config
/// the terminal uses, so the chrome follows whatever theme is set.
struct WorkbenchTheme: Equatable {
    /// The terminal's background color.
    var background: Color
    /// The terminal's `background-opacity`. Drives how much vibrancy shows
    /// through the chrome, so a translucent terminal gets translucent chrome.
    var opacity: Double
    /// Whether `background` is dark, which decides whether text and fills are
    /// light-on-dark or dark-on-light.
    var isDark: Bool

    var primary: Color { isDark ? .white.opacity(0.93) : .black.opacity(0.85) }
    var secondary: Color { isDark ? .white.opacity(0.62) : .black.opacity(0.55) }
    var tertiary: Color { isDark ? .white.opacity(0.40) : .black.opacity(0.38) }
    var separator: Color { isDark ? .white.opacity(0.10) : .black.opacity(0.09) }
    var hoverFill: Color { isDark ? .white.opacity(0.07) : .black.opacity(0.05) }
    var selectionFill: Color { Color.accentColor.opacity(isDark ? 0.26 : 0.16) }
    /// Fill for a raised surface (search field, pill, card) on top of `background`.
    var elevatedFill: Color { isDark ? .white.opacity(0.06) : .black.opacity(0.045) }
    var accent: Color { .accentColor }

    /// Fallback used before a config is available (previews, feature disabled).
    static let system = WorkbenchTheme(
        background: Color(nsColor: .controlBackgroundColor),
        opacity: 1,
        isDark: NSApp.effectiveAppearance.isDarkMode)

    init(background: Color, opacity: Double, isDark: Bool) {
        self.background = background
        self.opacity = opacity
        self.isDark = isDark
    }

    init(config: Ghostty.Config) {
        let background = config.backgroundColor
        self.background = background
        // Clamp: a fully transparent terminal would otherwise make the chrome
        // unreadable, and values above 1 are meaningless.
        self.opacity = min(max(config.backgroundOpacity, 0.35), 1)
        self.isDark = Self.isDark(background)
    }

    /// Relative luminance (Rec. 709) of the background, so the derived colors
    /// don't depend on the *system* appearance — a light terminal theme in dark
    /// mode still needs dark text.
    private static func isDark(_ color: Color) -> Bool {
        guard let srgb = NSColor(color).usingColorSpace(.sRGB) else {
            return NSApp.effectiveAppearance.isDarkMode
        }
        let luminance = 0.2126 * srgb.redComponent
            + 0.7152 * srgb.greenComponent
            + 0.0722 * srgb.blueComponent
        return luminance < 0.5
    }
}

extension NSAppearance {
    var isDarkMode: Bool {
        bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}

private struct WorkbenchThemeKey: EnvironmentKey {
    static let defaultValue = WorkbenchTheme.system
}

extension EnvironmentValues {
    /// Injected once at the Workbench root; every panel reads it from here rather
    /// than each view reaching for the config.
    var workbenchTheme: WorkbenchTheme {
        get { self[WorkbenchThemeKey.self] }
        set { self[WorkbenchThemeKey.self] = newValue }
    }
}

/// Background for Workbench chrome: window vibrancy with the terminal's color
/// laid over it at the terminal's own opacity.
///
/// At `background-opacity: 1` the tint is opaque and you get a solid panel that
/// matches the terminal exactly. Below that, the tint is partial and the material
/// shows through, so the chrome is translucent to the same degree the terminal is.
struct WorkbenchChromeBackground: View {
    @Environment(\.workbenchTheme) private var theme

    var body: some View {
        ZStack {
            WorkbenchVisualEffect(material: .sidebar, blendingMode: .behindWindow)
            theme.background.opacity(theme.opacity)
        }
        .ignoresSafeArea()
    }
}

struct WorkbenchVisualEffect: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.autoresizingMask = [.width, .height]
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

/// Row density for the session list.
enum WorkbenchDensity: String, CaseIterable, Sendable {
    case compact
    case comfortable

    var label: String { self == .compact ? "Compact" : "Comfortable" }
    /// Vertical padding applied to a session row.
    var rowPadding: CGFloat { self == .compact ? 3 : 6 }
    /// Whether rows show their secondary line.
    var showsSubtitle: Bool { self == .comfortable }
}
#endif
