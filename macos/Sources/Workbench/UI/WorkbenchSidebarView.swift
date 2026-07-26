#if os(macOS)
import AppKit
import SwiftUI

struct WorkbenchSidebarView: View {
    @ObservedObject var model: WorkbenchViewModel
    var onOpenSession: (WorkbenchSessionRecord) -> Void
    var onForkSession: (WorkbenchSessionRecord) -> Void
    var onLaunch: (WorkbenchLaunchMode) -> Void = { _ in }
    @State private var renameTarget: WorkbenchSessionRecord?
    @State private var renameText: String = ""
    @State private var worktreeDirectory: String?
    @State private var worktreeName: String = ""
    @State private var endTarget: WorkbenchSessionRecord?

    var body: some View {
        VStack(spacing: 0) {
            header
            search
            filterBar
            Divider()
            sessionList
            Divider()
            footer
        }
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
        .alert("Rename Session", isPresented: renameBinding) {
            TextField("Display name", text: $renameText)
            Button("Save") {
                if let target = renameTarget { model.rename(target, to: renameText) }
                renameTarget = nil
            }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        } message: {
            Text("A local name for this session. Leave empty to use Claude's title.")
        }
        .alert("New Worktree", isPresented: worktreeBinding) {
            TextField("Branch / worktree name", text: $worktreeName)
            Button("Create") {
                let name = worktreeName.trimmingCharacters(in: .whitespaces)
                if let dir = worktreeDirectory, !name.isEmpty {
                    onLaunch(.worktree(projectPath: dir, name: name, prompt: nil))
                }
                worktreeDirectory = nil
            }
            Button("Cancel", role: .cancel) { worktreeDirectory = nil }
        }
        .alert("End Session?", isPresented: endBinding, presenting: endTarget) { session in
            Button("End Session", role: .destructive) {
                let target = session
                endTarget = nil
                Task { await model.endSession(target) }
            }
            Button("Cancel", role: .cancel) { endTarget = nil }
        } message: { session in
            Text("This terminates the running Claude process for “\(session.displayTitle)”. Any unsaved work in that session is lost. Use this to clean up background sessions that have no window.")
        }
    }

    private var renameBinding: Binding<Bool> {
        Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })
    }

    private var endBinding: Binding<Bool> {
        Binding(get: { endTarget != nil }, set: { if !$0 { endTarget = nil } })
    }

    private var worktreeBinding: Binding<Bool> {
        Binding(get: { worktreeDirectory != nil }, set: { if !$0 { worktreeDirectory = nil } })
    }

    /// Prompts for a directory (New / Continue / Worktree targets).
    private func chooseDirectory() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .font(.system(size: 11))
                .foregroundStyle(.purple)
            Text("Claude Workbench")
                .font(.system(size: 12.5, weight: .semibold))
            Spacer(minLength: 2)
            Menu {
                Button("New Session…") {
                    if let dir = chooseDirectory() { onLaunch(.new(projectPath: dir, prompt: nil)) }
                }
                Button("Continue Latest…") {
                    if let dir = chooseDirectory() { onLaunch(.continueLatest(cwd: dir)) }
                }
                Button("New Worktree…") {
                    if let dir = chooseDirectory() { worktreeName = ""; worktreeDirectory = dir }
                }
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("New Claude session")
            Button {
                model.toggleDetails()
            } label: {
                Image(systemName: "sidebar.right")
                    .foregroundStyle(model.isDetailsVisible ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.borderless)
            .help(model.isDetailsVisible ? "Hide details panel" : "Show details panel")
            Button {
                model.toggleSidebar()
            } label: {
                Image(systemName: "sidebar.left")
            }
            .buttonStyle(.borderless)
            .help("Hide Claude Workbench sidebar")
            settingsMenu
        }
        .font(.system(size: 12))
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    /// Agent-status hook + notification preferences. The hook is what lets sessions
    /// push their real state (working / waiting on you) instead of Workbench
    /// inferring it from the transcript.
    private var settingsMenu: some View {
        Menu {
            let installed = model.isHookInstalled
            Section("Agent Status") {
                Button(installed ? "Remove Status Hook…" : "Install Status Hook…") {
                    Task { await model.setHookInstalled(!installed) }
                }
                Text(installed
                     ? "Installed — sessions report live state"
                     : "Not installed — status is inferred")
            }
            Section("Notifications") {
                Toggle("Notify When Task Completes", isOn: Binding(
                    get: { WorkbenchNotifier.notifyOnComplete },
                    set: { WorkbenchNotifier.notifyOnComplete = $0 }))
                Toggle("Notify When Awaiting Input", isOn: Binding(
                    get: { WorkbenchNotifier.notifyOnAwaitingInput },
                    set: { WorkbenchNotifier.notifyOnAwaitingInput = $0 }))
            }
            Divider()
            // Rarely needed now that FSEvents drives updates, so it lives here
            // instead of spending a slot in the header.
            Button("Refresh Sessions") { Task { await model.refresh() } }
        } label: {
            Image(systemName: "gearshape")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Workbench settings")
    }

    private var search: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search sessions  ·  ⏎ opens best match", text: $model.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .onSubmit {
                    if let top = model.topSearchMatch {
                        model.select(top)
                        onOpenSession(top)
                    }
                }
        }
        .padding(7)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    private var filterBar: some View {
        HStack(spacing: 4) {
            ForEach(WorkbenchSessionFilter.allCases, id: \.self) { option in
                let selected = model.filter == option
                let count = model.count(for: option)
                Button {
                    model.filter = option
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: option.systemImage).font(.caption2)
                        // Live count badge (skip on "All" to keep it quiet).
                        if option != .all && count > 0 {
                            Text("\(count)").font(.caption2).monospacedDigit()
                        }
                    }
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(selected ? Color.accentColor.opacity(0.18) : Color.clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(count > 0 && option != .all ? "\(option.label) (\(count))" : option.label)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    private var sessionList: some View {
        // The highlight tracks the FOCUSED terminal tab (set in
        // TerminalController.windowDidBecomeKey), not what was last clicked. No
        // `List(selection:)` — we highlight manually. Clicking a row opens/focuses
        // that session, which makes it the focused tab, so the highlight lands on it
        // and the list scrolls it into view via the ScrollViewReader below.
        ScrollViewReader { proxy in
            List {
                ForEach(model.worktreeGroups) { group in
                    Section {
                        if !model.isGroupCollapsed(group.id) {
                            ForEach(group.sessions) { session in
                                WorkbenchSessionRow(
                                    session: session,
                                    worktreePath: group.path,
                                    isSelected: model.selectedSessionID == session.id,
                                    onPin: { model.togglePinned(session) },
                                    onArchive: { model.toggleArchived(session) }
                                )
                                .id(session.id)
                                .contentShape(Rectangle())
                                // Double-click opens; a single click only selects, so
                                // you can inspect a session in the details panel
                                // without launching a Claude process for it.
                                .onTapGesture(count: 2) {
                                    model.select(session)
                                    onOpenSession(session)
                                }
                                .onTapGesture {
                                    model.select(session)
                                }
                                .contextMenu {
                                    Button("Resume") { model.select(session); onOpenSession(session) }
                                    Button("Fork") { onForkSession(session) }
                                    if session.status == .running {
                                        Button("End Session…", role: .destructive) { endTarget = session }
                                    }
                                    Divider()
                                    Button("Rename…") { renameText = session.localTitle ?? ""; renameTarget = session }
                                    Button(session.isPinned ? "Unpin" : "Pin") { model.togglePinned(session) }
                                    Button(session.isArchived ? "Unarchive" : "Archive") { model.toggleArchived(session) }
                                    Divider()
                                    if let cwd = session.cwd {
                                        Button("Reveal Folder in Finder") {
                                            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: cwd)
                                        }
                                    }
                                    if let transcriptPath = session.transcriptPath {
                                        Button("Reveal Transcript in Finder") {
                                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: transcriptPath)])
                                        }
                                        Button("Copy Transcript Path") {
                                            NSPasteboard.general.clearContents()
                                            NSPasteboard.general.setString(transcriptPath, forType: .string)
                                        }
                                    }
                                }
                            }
                        }
                    } header: {
                        WorkbenchWorktreeHeader(
                            group: group,
                            isCollapsed: model.isGroupCollapsed(group.id),
                            onToggle: { model.toggleGroupCollapsed(group.id) },
                            onLaunch: onLaunch
                        )
                    }
                }
            }
            .listStyle(.sidebar)
            .overlay {
                if model.worktreeGroups.isEmpty { emptyState }
            }
            .onReceive(model.$selectedSessionID) { id in
                guard let id else { return }
                // Defer to the next runloop so the List has laid out any just-changed
                // rows before we scroll — otherwise scrollTo can target stale layout.
                DispatchQueue.main.async {
                    model.expandGroupContaining(id) // reveal it if its group is collapsed
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: emptyIcon)
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
            Text(emptyTitle).font(.callout.weight(.medium))
            Text(emptySubtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyIcon: String {
        if !model.searchText.isEmpty { return "magnifyingglass" }
        if model.filter != .all { return model.filter.systemImage }
        return "sparkles"
    }
    private var emptyTitle: String {
        if !model.searchText.isEmpty { return "No matches" }
        if model.filter != .all { return "Nothing \(model.filter.label.lowercased())" }
        return "No sessions yet"
    }
    private var emptySubtitle: String {
        if !model.searchText.isEmpty { return "Try a different search." }
        if model.filter != .all { return "Switch back to All to see every session." }
        return "Use + to start one, or run claude in a terminal."
    }

    private var footer: some View {
        HStack(spacing: 4) {
            Text(model.statusMessage ?? "Workbench ready")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

}

private struct WorkbenchWorktreeHeader: View {
    let group: WorkbenchWorktreeGroup
    let isCollapsed: Bool
    let onToggle: () -> Void
    var onLaunch: (WorkbenchLaunchMode) -> Void = { _ in }

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                    .animation(.easeInOut(duration: 0.15), value: isCollapsed)
                Image(systemName: icon)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(group.repoName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let branch = group.branch {
                    // A pill keeps the branch from reading as part of the repo name.
                    Text(branch)
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.07)))
                }
                if let dirty = group.dirty, dirty > 0 {
                    Text("±\(dirty)")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.orange)
                }
                Spacer(minLength: 4)
                // Running count stays visible even when the group is collapsed.
                if group.runningCount > 0 {
                    Text("\(group.runningCount)")
                        .font(.system(size: 9.5, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.green)
                    Circle().fill(.green).frame(width: 5, height: 5)
                }
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isCollapsed ? "Expand" : "Collapse")
        .contextMenu {
            // Start work in this repo/worktree directly — no directory picker.
            if !group.path.isEmpty {
                Button("New Session Here") { onLaunch(.new(projectPath: group.path, prompt: nil)) }
                Button("Continue Latest Here") { onLaunch(.continueLatest(cwd: group.path)) }
            }
        }
    }

    private var icon: String {
        if !group.isGit { return "folder" }
        return group.isLinkedWorktree ? "arrow.triangle.branch" : "shippingbox"
    }
}

private struct WorkbenchSessionRow: View {
    let session: WorkbenchSessionRecord
    var worktreePath: String = ""
    var isSelected: Bool = false
    var onPin: () -> Void = {}
    var onArchive: () -> Void = {}
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            WorkbenchStatusDot(session: session)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(session.displayTitle)
                        .font(.system(size: 12.5, weight: isSelected ? .medium : .regular))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if session.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.blue)
                    }
                    if let badge = agentBadge {
                        Image(systemName: badge.icon)
                            .font(.caption2)
                            .foregroundStyle(badge.color)
                            .help(badge.help)
                    }
                    Spacer(minLength: 4)
                    // Reserved trailing area: relative time at rest, quick actions
                    // on hover (no layout shift; context menu still available).
                    ZStack(alignment: .trailing) {
                        if let relative = relativeTime {
                            Text(relative)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                                .opacity(hovering ? 0 : 1)
                        }
                        if hovering {
                            HStack(spacing: 8) {
                                Button(action: onPin) {
                                    Image(systemName: session.isPinned ? "pin.slash" : "pin")
                                }
                                .buttonStyle(.plain)
                                .help(session.isPinned ? "Unpin" : "Pin")
                                Button(action: onArchive) {
                                    Image(systemName: session.isArchived ? "tray.and.arrow.up" : "archivebox")
                                }
                                .buttonStyle(.plain)
                                .help(session.isArchived ? "Unarchive" : "Archive")
                            }
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }
                    }
                    .frame(minWidth: 40, alignment: .trailing)
                }
                // Only when it says something the group header doesn't already.
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .padding(.vertical, 5)
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected
                      ? Color.accentColor.opacity(0.16)
                      : (hovering ? Color.primary.opacity(0.055) : Color.clear))
        )
        // A leading accent bar makes the selected row readable at a glance even
        // against the terminal's own background tint.
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.accentColor)
                .frame(width: 2.5)
                .padding(.vertical, 3)
                .opacity(isSelected ? 1 : 0)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    /// Glyph describing what the agent is doing. Prefers the state the Claude Code
    /// hook pushed; falls back to the inferred `needsReview` for sessions with no
    /// hook data (which is why its wording is hedged).
    private var agentBadge: (icon: String, color: Color, help: String)? {
        switch session.agentState {
        case .awaitingInput:
            return ("hand.raised.fill", .orange, "Needs your approval")
        case .idle:
            return ("exclamationmark.bubble.fill", .orange, "Finished — waiting on you")
        case .working:
            return ("bolt.horizontal.fill", .blue, "Claude is working")
        case .ended:
            return nil
        case .none:
            guard session.needsReview else { return nil }
            return ("exclamationmark.bubble", .orange, "Claude replied last — may be waiting on you")
        }
    }

    /// Compact relative time (now / 5m / 3h / 2d) from last activity.
    private var relativeTime: String? {
        guard let date = session.lastModifiedAt else { return nil }
        let seconds = Date().timeIntervalSince(date)
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if seconds < 86400 { return "\(Int(seconds / 3600))h" }
        return "\(Int(seconds / 86400))d"
    }

    /// Second line, or nil when there's nothing to add. A session sitting at the
    /// group's own root has no extra location to show — it used to render a bare
    /// "·" on every such row, which was just noise.
    private var subtitle: String? {
        if let cwd = session.cwd {
            if !worktreePath.isEmpty, cwd == worktreePath { return nil }
            if !worktreePath.isEmpty, cwd.hasPrefix(worktreePath + "/") {
                return String(cwd.dropFirst(worktreePath.count + 1))
            }
            return (cwd as NSString).lastPathComponent
        }
        if let lastModifiedAt = session.lastModifiedAt {
            return lastModifiedAt.formatted(date: .abbreviated, time: .shortened)
        }
        return String(session.id.prefix(12))
    }
}

#endif
