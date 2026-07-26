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
    // Mirrored into @State rather than read straight from UserDefaults so the
    // list re-renders the moment the menu changes it.
    @State private var density: WorkbenchDensity = WorkbenchFeature.density
    @Environment(\.workbenchTheme) private var theme

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
        .background(WorkbenchChromeBackground())
        .foregroundStyle(theme.primary)
        .onChange(of: density) { newValue in WorkbenchFeature.density = newValue }
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
                    .foregroundStyle(model.isDetailsVisible ? Color.accentColor : theme.secondary)
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
            Section("Appearance") {
                Picker("Row Density", selection: $density) {
                    ForEach(WorkbenchDensity.allCases, id: \.self) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.inline)
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
                .foregroundStyle(theme.secondary)
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
        .background(RoundedRectangle(cornerRadius: 7).fill(theme.elevatedFill))
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
                    .foregroundStyle(selected ? Color.accentColor : theme.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(selected ? theme.selectionFill : Color.clear)
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
                                    density: density,
                                    onPin: { model.togglePinned(session) },
                                    onArchive: { model.toggleArchived(session) }
                                )
                                .id(session.id)
                                // Filtering/searching rewrites the list wholesale;
                                // a fade keeps rows from snapping in and out.
                                .transition(.opacity)
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
                transcriptMatches
            }
            .listStyle(.sidebar)
            // Keyed on the two things that rewrite the list, never on the refresh
            // tick — otherwise every FSEvents poll would re-animate the sidebar.
            .animation(.easeInOut(duration: 0.18), value: model.filter)
            .animation(.easeInOut(duration: 0.18), value: model.searchText)
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
                .foregroundStyle(theme.secondary)
            Text(emptyTitle).font(.callout.weight(.medium))
            Text(emptySubtitle)
                .font(.caption)
                .foregroundStyle(theme.secondary)
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

    /// Sessions found by transcript content rather than title. Kept in its own
    /// section so it's clear these matched on what was said inside them, and shown
    /// only for sessions the title filter didn't already list.
    @ViewBuilder
    private var transcriptMatches: some View {
        let matches = model.contentOnlyHits
        if model.isSearchingContent || !matches.isEmpty {
            Section {
                if matches.isEmpty {
                    Text("Searching…")
                        .font(.system(size: 10.5))
                        .foregroundStyle(theme.tertiary)
                } else {
                    ForEach(matches, id: \.hit.id) { match in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                WorkbenchStatusDot(session: match.session)
                                Text(match.session.displayTitle)
                                    .font(.system(size: 12))
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                                Text("\(match.hit.matchCount)")
                                    .font(.system(size: 9.5))
                                    .monospacedDigit()
                                    .foregroundStyle(theme.tertiary)
                            }
                            Text(match.hit.snippet)
                                .font(.system(size: 10))
                                .foregroundStyle(theme.tertiary)
                                .lineLimit(2)
                        }
                        .padding(.vertical, 3)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            model.select(match.session)
                            onOpenSession(match.session)
                        }
                        .onTapGesture { model.select(match.session) }
                    }
                }
            } header: {
                HStack(spacing: 5) {
                    Image(systemName: "text.magnifyingglass").font(.caption2)
                    Text("In transcripts")
                        .font(.system(size: 11, weight: .semibold))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(theme.secondary)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 4) {
            Text(model.statusMessage ?? "Workbench ready")
                .font(.system(size: 10.5))
                .foregroundStyle(theme.tertiary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

}

private struct WorkbenchWorktreeHeader: View {
    @Environment(\.workbenchTheme) private var theme
    let group: WorkbenchWorktreeGroup
    let isCollapsed: Bool
    let onToggle: () -> Void
    var onLaunch: (WorkbenchLaunchMode) -> Void = { _ in }

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(theme.secondary)
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                    .animation(.easeInOut(duration: 0.15), value: isCollapsed)
                Image(systemName: icon)
                    .font(.caption2)
                    .foregroundStyle(hue)
                Text(group.repoName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let branch = group.branch {
                    // A pill keeps the branch from reading as part of the repo name.
                    Text(branch)
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(theme.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 3)
                            .fill(hue.opacity(theme.isDark ? 0.20 : 0.13)))
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

    /// Keyed on `repoKey` rather than the group id so every worktree of one repo
    /// shares a color — the branch pill is what distinguishes them.
    private var hue: Color { workbenchGroupColor(group.repoKey, isDark: theme.isDark) }
}

/// A muted, stable per-repo color so a long list of groups can be scanned by
/// eye. Swift's `hashValue` is seeded per process and would hand a repo a
/// different color on every launch, so this hashes explicitly (FNV-1a).
/// Saturation and brightness are pinned per appearance — a free-floating hue at
/// full saturation reads as a rainbow and loses contrast at both extremes.
private func workbenchGroupColor(_ key: String, isDark: Bool) -> Color {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in key.utf8 {
        hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
    }
    return Color(
        hue: Double(hash % 360) / 360,
        saturation: isDark ? 0.42 : 0.55,
        brightness: isDark ? 0.86 : 0.62)
}

private struct WorkbenchSessionRow: View {
    @Environment(\.workbenchTheme) private var theme
    let session: WorkbenchSessionRecord
    var worktreePath: String = ""
    var isSelected: Bool = false
    var density: WorkbenchDensity = .comfortable
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
                                .foregroundStyle(theme.secondary)
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
                            .foregroundStyle(theme.secondary)
                        }
                    }
                    .frame(minWidth: 40, alignment: .trailing)
                }
                // Only when it says something the group header doesn't already.
                if density.showsSubtitle, let subtitle {
                    Text(subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(theme.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .padding(.vertical, density.rowPadding)
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected
                      ? theme.selectionFill
                      : (hovering ? theme.hoverFill : Color.clear))
                // Only on selection: hover should stay instant, and a spring keyed
                // on the whole row would replay on every refresh tick.
                .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isSelected)
        )
        // A leading accent bar makes the selected row readable at a glance even
        // against the terminal's own background tint.
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.accentColor)
                .frame(width: 2.5)
                .padding(.vertical, 3)
                .opacity(isSelected ? 1 : 0)
                .scaleEffect(y: isSelected ? 1 : 0.4, anchor: .center)
                .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isSelected)
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
