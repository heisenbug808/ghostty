#if os(macOS)
import AppKit
import SwiftUI
import GhosttyKit

struct WorkbenchTerminalRootView<TerminalContent: View>: View {
    @ObservedObject var model: WorkbenchViewModel
    let ghostty: Ghostty.App
    let parentWindowProvider: () -> NSWindow?
    let terminalContent: TerminalContent
    @State private var duplicateRunningSession: WorkbenchSessionRecord?
    // Per-view alert state (must NOT live on the shared model, or the alert would
    // pop in every open window at once).
    @State private var launchBlock: WorkbenchViewModel.LaunchBlock?
    // Persisted sidebar width, shared across all windows via UserDefaults so a drag
    // in one window resizes them all and survives relaunch.
    @AppStorage("workbench.sidebarWidth") private var sidebarWidth: Double = 280
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
        self.parentWindowProvider = parentWindowProvider
        self.terminalContent = terminalContent()
    }

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
                    }
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
        if !fork, session.status == .running {
            if surfaceRegistry.focusExisting(sessionId: session.id) {
                return
            }
            duplicateRunningSession = session
            return
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
            }
        }
    }
}

private let workbenchMinSidebarWidth: Double = 220
private let workbenchMaxSidebarWidth: Double = 480

/// A 1pt divider with a wider invisible hit area that drags to resize the sidebar,
/// showing the horizontal-resize cursor on hover — like a Ghostty split divider.
private struct WorkbenchResizeHandle: View {
    @Binding var width: Double
    let minWidth: Double
    let maxWidth: Double
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
                                width = min(max(base + value.translation.width, minWidth), maxWidth)
                            }
                            .onEnded { _ in dragStartWidth = nil }
                    )
            }
    }
}

#endif
