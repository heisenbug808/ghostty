#if os(macOS)
import AppKit
import SwiftUI
import GhosttyKit

struct WorkbenchTerminalRootView<TerminalContent: View>: View {
    @ObservedObject var model: WorkbenchViewModel
    let ghostty: Ghostty.App
    @ObservedObject private var ghosttyConfig: Ghostty.Config
    let parentWindowProvider: () -> NSWindow?
    let terminalContent: TerminalContent
    @State private var duplicateRunningSession: WorkbenchSessionRecord?
    // Per-view alert state (must NOT live on the shared model, or the alert would
    // pop in every open window at once).
    @State private var launchBlock: WorkbenchViewModel.LaunchBlock?
    // Persisted sidebar width, shared across all windows via UserDefaults so a drag
    // in one window resizes them all and survives relaunch.
    @AppStorage("workbench.sidebarWidth") private var sidebarWidth: Double = 280
    @AppStorage("workbench.detailsWidth") private var detailsWidth: Double = 320
    // The app-wide registry — the SAME instance TerminalController.windowDidBecomeKey
    // reads, so registering here actually drives the focus-follows highlight.
    private var surfaceRegistry: WorkbenchSurfaceRegistry { .shared }

    init(
        model: WorkbenchViewModel,
        ghostty: Ghostty.App,
        parentWindowProvider: @escaping () -> NSWindow?,
        @ViewBuilder terminalContent: () -> TerminalContent
    ) {
        self.model = model
        self.ghostty = ghostty
        self.ghosttyConfig = ghostty.config
        self.parentWindowProvider = parentWindowProvider
        self.terminalContent = terminalContent()
    }

    /// Chrome colors follow the terminal's own theme. `ghosttyConfig` is observed
    /// so a live config reload (or theme switch) repaints the sidebar with it.
    private var theme: WorkbenchTheme { WorkbenchTheme(config: ghosttyConfig) }

    var body: some View {
        Group {
            if WorkbenchFeature.isEnabled {
                if model.isSidebarVisible {
                    HStack(spacing: 0) {
                        WorkbenchSidebarView(
                            model: model,
                            onOpenSession: { launch(session: $0, fork: false) },
                            onForkSession: { launch(session: $0, fork: true) },
                            onLaunch: { launch(mode: $0) }
                        )
                        .frame(width: sidebarWidth)
                        WorkbenchResizeHandle(
                            width: $sidebarWidth,
                            minWidth: workbenchMinSidebarWidth,
                            maxWidth: workbenchMaxSidebarWidth
                        )
                        terminalContent
                        if model.isDetailsVisible {
                            // Dragging this handle leftward widens the panel, so the
                            // translation is inverted relative to the sidebar's.
                            WorkbenchResizeHandle(
                                width: $detailsWidth,
                                minWidth: workbenchMinDetailsWidth,
                                maxWidth: workbenchMaxDetailsWidth,
                                inverted: true
                            )
                            Group {
                                if let selected = model.selectedSession {
                                    WorkbenchDetailsPanel(
                                        model: model,
                                        session: selected,
                                        onResume: { launch(session: selected, fork: false) },
                                        onFork: { launch(session: selected, fork: true) }
                                    )
                                } else {
                                    // Keep the panel in place rather than collapsing the
                                    // layout every time selection clears.
                                    WorkbenchPanelPlaceholder(
                                        icon: "sidebar.right",
                                        title: "No session selected",
                                        message: "Click a session to see its details, transcript, and git state.")
                                    .background(WorkbenchChromeBackground())
                                }
                            }
                            .frame(width: detailsWidth)
                            // Slide in from the edge it lives on rather than
                            // appearing instantly and shoving the terminal aside.
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                        }
                    }
                    .animation(.spring(response: 0.28, dampingFraction: 0.85),
                               value: model.isDetailsVisible)
                } else {
                    // Sidebar hidden: keep an always-available affordance to reveal it
                    // again, since hiding it removes the in-sidebar toggle button and we
                    // intentionally avoid editing the shared MainMenu.xib for the MVP.
                    terminalContent
                        .overlay(alignment: .topLeading) {
                            Button {
                                model.toggleSidebar()
                            } label: {
                                Image(systemName: "sidebar.left")
                                    .padding(6)
                            }
                            .buttonStyle(.borderless)
                            .help("Show Claude Workbench sidebar")
                            .padding(6)
                        }
                }
            } else {
                terminalContent
            }
        }
        .environment(\.workbenchTheme, theme)
        .alert(
            "Session Already Running",
            isPresented: duplicateRunningAlertBinding,
            presenting: duplicateRunningSession
        ) { session in
            Button("Fork Session") {
                duplicateRunningSession = nil
                launch(session: session, fork: true)
            }
            Button("Cancel", role: .cancel) {
                duplicateRunningSession = nil
            }
        } message: { session in
            Text("Workbench could not find an existing Ghostty window for “\(session.displayTitle)”. Forking is safer than opening the same Claude session twice.")
        }
        .alert(item: $launchBlock) { block in
            Alert(
                title: Text(block.title),
                message: Text(block.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    private var duplicateRunningAlertBinding: Binding<Bool> {
        Binding(
            get: { duplicateRunningSession != nil },
            set: { isPresented in
                if !isPresented { duplicateRunningSession = nil }
            }
        )
    }

    private func launch(session: WorkbenchSessionRecord, fork: Bool) {
        if !fork {
            // If Workbench already opened a window for this session, just focus it —
            // regardless of whether the status has flipped from .launching to
            // .running yet. Without this, a second click re-enters the resume path
            // and hits the still-held session lock ("Session Locked").
            if surfaceRegistry.focusExisting(sessionId: session.id) {
                return
            }
            // Running elsewhere (or a window we can no longer focus): don't relaunch
            // into the lock — offer to fork instead.
            if session.status == .running {
                duplicateRunningSession = session
                return
            }
        }

        launch(mode: fork
            ? .fork(sessionId: session.id, cwd: session.cwd)
            : .resume(sessionId: session.id, cwd: session.cwd))
    }

    /// Launches any mode (new / continue / worktree in addition to resume/fork)
    /// in a new Ghostty tab and registers it so the highlight follows.
    private func launch(mode: WorkbenchLaunchMode) {
        Task { @MainActor in
            let request: WorkbenchLaunchRequest
            switch await model.prepareLaunchRequest(mode: mode) {
            case .ignored:
                return
            case .blocked(let block):
                launchBlock = block
                return
            case .proceed(let preparedRequest):
                request = preparedRequest
            }

            let launcher = WorkbenchLauncherService()
            let built = launcher.build(request)
            var config = Ghostty.SurfaceConfiguration()
            config.workingDirectory = built.workingDirectory
            config.command = built.command
            config.waitAfterCommand = true
            config.environmentVariables["GHOSTTY_WORKBENCH_LAUNCH_ID"] = built.launchId
            if let sessionId = built.sessionId {
                config.environmentVariables["GHOSTTY_WORKBENCH_SESSION_ID"] = sessionId
            }
            let controller = TerminalController.newTab(ghostty, from: parentWindowProvider(), withBaseConfig: config)
            if let sessionId = built.sessionId {
                surfaceRegistry.register(sessionId: sessionId, launchId: built.launchId, window: controller?.window)
                // Carry the user's own name onto the tab; without this the tab
                // shows whatever the terminal reports and a rename appears to do
                // nothing outside the sidebar.
                if let title = model.tabTitle(forSessionId: sessionId) {
                    controller?.titleOverride = title
                }
            }
        }
    }
}

private let workbenchMinSidebarWidth: Double = 220
private let workbenchMaxSidebarWidth: Double = 480
private let workbenchMinDetailsWidth: Double = 260
private let workbenchMaxDetailsWidth: Double = 560

/// A 1pt divider with a wider invisible hit area that drags to resize the sidebar,
/// showing the horizontal-resize cursor on hover — like a Ghostty split divider.
private struct WorkbenchResizeHandle: View {
    @Binding var width: Double
    let minWidth: Double
    let maxWidth: Double
    /// True for a panel on the *right*, where dragging left must grow it.
    var inverted = false
    // The width when the current drag began, so translation is applied to a stable base.
    @State private var dragStartWidth: Double?

    var body: some View {
        Divider()
            .overlay {
                Color.clear
                    .frame(width: 10)
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        if hovering {
                            NSCursor.resizeLeftRight.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                let base = dragStartWidth ?? width
                                if dragStartWidth == nil { dragStartWidth = base }
                                let delta = inverted ? -value.translation.width : value.translation.width
                                width = min(max(base + delta, minWidth), maxWidth)
                            }
                            .onEnded { _ in dragStartWidth = nil }
                    )
            }
    }
}

#endif
