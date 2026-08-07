#if os(macOS)
import AppKit
import SwiftUI

/// Right-hand panel with everything known about the selected session.
///
/// This replaces the cramped inspector strip that used to sit under the session
/// list: a session has more worth showing (a readable transcript, git state, ids
/// and paths) than fits in a few lines above the footer.
struct WorkbenchDetailsPanel: View {
    enum Tab: String, CaseIterable, Identifiable {
        case info = "Info"
        case transcript = "Transcript"
        case git = "Git"

        var id: String { rawValue }
    }

    @ObservedObject var model: WorkbenchViewModel
    let session: WorkbenchSessionRecord
    /// Launching needs the window/ghostty context the root view owns, so those two
    /// stay callbacks; everything else the panel drives through the model.
    var onResume: () -> Void
    var onFork: () -> Void

    @Environment(\.workbenchTheme) private var theme
    @State private var renameText = ""
    @State private var isRenaming = false
    @State private var isConfirmingEnd = false

    private var gitInfo: WorkbenchGitInfo? { model.gitInfo(for: session) }
    private var transcript: [WorkbenchTranscriptMessage] { model.transcript(for: session) }
    private var tab: Binding<Tab> { $model.detailsTab }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            WorkbenchTabBar(selection: tab)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            Divider()

            switch tab.wrappedValue {
            case .info: infoTab
            case .transcript: transcriptTab
            case .git: gitTab
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(WorkbenchChromeBackground())
        .foregroundStyle(theme.primary)
        .alert("Rename Session", isPresented: $isRenaming) {
            TextField("Display name", text: $renameText)
            Button("Save") { model.rename(session, to: renameText) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A local name for this session. Leave empty to use Claude's title.")
        }
        .alert("End Session?", isPresented: $isConfirmingEnd) {
            Button("End Session", role: .destructive) {
                Task { await model.endSession(session) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This terminates the running Claude process for “\(session.displayTitle)”. Any unsaved work in that session is lost.")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            WorkbenchStatusDot(session: session)
            Text(session.displayTitle)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
            Spacer(minLength: 4)
            Button { model.toggleDetails() } label: {
                Image(systemName: "sidebar.right")
            }
            .buttonStyle(.borderless)
            .help("Hide details")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Info

    private var infoTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                actions

                WorkbenchDetailSection("Session", rows: [
                    WorkbenchDetailRow("State", value: stateDescription),
                    session.messageCount.map { WorkbenchDetailRow("Messages", value: "\($0)") },
                    session.lastModifiedAt.map {
                        WorkbenchDetailRow("Last active", value: $0.formatted(date: .abbreviated, time: .shortened))
                    },
                    session.runningPID.map { WorkbenchDetailRow("Process", value: "pid \($0)") },
                    WorkbenchDetailRow("ID", value: session.id, monospaced: true, copyable: true),
                ])

                WorkbenchDetailSection("Location", rows: [
                    session.cwd.map { WorkbenchDetailRow("Directory", value: $0, monospaced: true, copyable: true) },
                    session.transcriptPath.map {
                        WorkbenchDetailRow("Transcript", value: $0, monospaced: true, copyable: true)
                    },
                ])

                if !session.tags.isEmpty {
                    WorkbenchDetailCard(title: "Tags") {
                        Text(session.tags.joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(theme.secondary)
                            .textSelection(.enabled)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                    }
                }
            }
            .padding(12)
        }
    }

    private var actions: some View {
        // Wraps on a narrow panel instead of clipping.
        HStack(spacing: 6) {
            // A session running outside Workbench can't be focused or resumed —
            // forking is the only way to pick up where it is.
            if model.isRunningElsewhere(session) {
                WorkbenchActionButton(icon: "arrow.triangle.branch", title: "Fork", action: onFork)
            } else {
                WorkbenchActionButton(
                    icon: session.status == .running ? "arrow.up.forward.app" : "play.fill",
                    title: session.status == .running ? "Open" : "Resume",
                    action: onResume)
                WorkbenchActionButton(icon: "arrow.triangle.branch", title: "Fork", action: onFork)
            }
            Menu {
                Button("Rename…") {
                    renameText = session.localTitle ?? ""
                    isRenaming = true
                }
                if let cwd = session.cwd {
                    Button("Reveal Folder") {
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: cwd)
                    }
                }
                if let path = session.transcriptPath {
                    Button("Reveal Transcript") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                    }
                }
                if session.status == .running {
                    Divider()
                    Button("End Session…", role: .destructive) { isConfirmingEnd = true }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.secondary)
                    .frame(width: 26, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(theme.elevatedFill))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            Spacer(minLength: 0)
        }
    }

    private var stateDescription: String {
        if let agentState = session.agentState {
            switch agentState {
            case .working: return "Claude is working"
            case .idle: return "Finished — waiting on you"
            case .awaitingInput: return "Needs your approval"
            case .ended: return "Ended"
            }
        }
        if model.isRunningElsewhere(session) { return "Running outside Workbench" }
        return session.status.rawValue.capitalized
    }

    // MARK: - Transcript

    private var transcriptTab: some View {
        Group {
            if transcript.isEmpty {
                WorkbenchPanelPlaceholder(
                    icon: "text.alignleft",
                    title: "No transcript yet",
                    message: "This session hasn't recorded any messages Workbench can read.")
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(transcript) { message in
                                WorkbenchTranscriptRow(message: message)
                                    .id(message.id)
                            }
                        }
                        .padding(12)
                    }
                    .onAppear {
                        // Land on the newest message — that's what you came to read.
                        if let last = transcript.last { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
        }
    }

    // MARK: - Git

    private var gitTab: some View {
        Group {
            if let gitInfo {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        WorkbenchDetailSection("Repository", rows: [
                            gitInfo.originName.map { WorkbenchDetailRow("Remote", value: $0) },
                            WorkbenchDetailRow("Root", value: gitInfo.toplevel, monospaced: true, copyable: true),
                            WorkbenchDetailRow(
                                "Checkout",
                                value: gitInfo.isLinkedWorktree ? "Linked worktree" : "Main working tree"),
                        ])
                        WorkbenchDetailSection("Working tree", rows: [
                            WorkbenchDetailRow("Branch", value: gitInfo.branch ?? "detached", monospaced: true),
                            gitInfo.dirty.map {
                                WorkbenchDetailRow("Changes", value: $0 == 0 ? "Clean" : "\($0) file(s) modified")
                            },
                        ])
                    }
                    .padding(12)
                }
            } else {
                WorkbenchPanelPlaceholder(
                    icon: "shippingbox",
                    title: "Not a git repository",
                    message: session.cwd ?? "This session has no working directory.")
            }
        }
    }
}

// MARK: - Building blocks

/// Status dot shared by the panel header and session rows, so one status never
/// renders two different colors in two places.
struct WorkbenchStatusDot: View {
    let session: WorkbenchSessionRecord

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .overlay(
                Circle().strokeBorder(color.opacity(0.35), lineWidth: 3).scaleEffect(1.8)
                    .opacity(session.agentState == .working ? 1 : 0))
    }

    private var color: Color {
        switch session.status {
        case .running: return session.agentState?.isWaitingOnUser == true ? .orange : .green
        case .launching: return .yellow
        case .failed: return .red
        case .archived: return .secondary
        case .unknown: return .orange
        case .indexed, .idle: return .gray
        }
    }
}

/// Tab strip for the panel. The stock segmented picker reads as a System Settings
/// control dropped into the terminal; this one is built from the same tokens as
/// the rest of the chrome so it belongs to the window.
private struct WorkbenchTabBar: View {
    @Binding var selection: WorkbenchDetailsPanel.Tab

    var body: some View {
        HStack(spacing: 2) {
            ForEach(WorkbenchDetailsPanel.Tab.allCases) { tab in
                WorkbenchTabButton(title: tab.rawValue, isSelected: selection == tab) {
                    selection = tab
                }
            }
            Spacer(minLength: 0)
        }
    }
}

private struct WorkbenchTabButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    @Environment(\.workbenchTheme) private var theme
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? theme.primary : theme.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isSelected ? theme.selectionFill : (isHovering ? theme.hoverFill : .clear)))
                // The label alone leaves dead space inside the pill.
                .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Icon + label button sized like a toolbar item rather than a dialog button, so
/// the actions sit inside the panel instead of looking like a sheet's footer.
private struct WorkbenchActionButton: View {
    let icon: String
    let title: String
    let action: () -> Void

    @Environment(\.workbenchTheme) private var theme
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 10, weight: .semibold))
                Text(title).font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(theme.primary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(theme.elevatedFill)
                    // Layered rather than swapped: the two fills are within 0.01
                    // alpha of each other, so replacing one with the other would
                    // read as no hover at all.
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(isHovering ? theme.hoverFill : .clear)))
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

/// Titled card: a raised surface holding related rows, so the info tab reads as
/// a few groups instead of one long `label: value` list.
private struct WorkbenchDetailCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    @Environment(\.workbenchTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(theme.tertiary)
                .kerning(0.6)
                .padding(.leading, 2)
            VStack(alignment: .leading, spacing: 0) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(theme.elevatedFill))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(theme.separator, lineWidth: 1))
        }
    }
}

private struct WorkbenchDetailSection: View {
    let title: String
    let rows: [WorkbenchDetailRow?]

    init(_ title: String, rows: [WorkbenchDetailRow?]) {
        self.title = title
        self.rows = rows
    }

    var body: some View {
        let visible = rows.compactMap { $0 }
        // An all-optional group (a session with neither cwd nor transcript) would
        // otherwise leave a titled empty card behind.
        return Group {
            if !visible.isEmpty {
                WorkbenchDetailCard(title: title) {
                    ForEach(visible.indices, id: \.self) { index in
                        if index > 0 { WorkbenchHairline() }
                        WorkbenchDetailRowView(row: visible[index])
                    }
                }
            }
        }
    }
}

/// Rows are data, not views, so the card can put separators *between* them
/// without a trailing line under the last one.
private struct WorkbenchDetailRow {
    let label: String
    let value: String
    var monospaced = false
    var copyable = false

    init(_ label: String, value: String, monospaced: Bool = false, copyable: Bool = false) {
        self.label = label
        self.value = value
        self.monospaced = monospaced
        self.copyable = copyable
    }
}

/// Hairline instead of `Divider()`: a divider paints a system separator color that
/// ignores the terminal theme and insets itself unpredictably inside a card.
private struct WorkbenchHairline: View {
    @Environment(\.workbenchTheme) private var theme

    var body: some View {
        Rectangle()
            .fill(theme.separator)
            .frame(height: 1)
            .padding(.leading, 10)
    }
}

private struct WorkbenchDetailRowView: View {
    let row: WorkbenchDetailRow

    @Environment(\.workbenchTheme) private var theme
    @State private var copied = false
    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(row.label)
                .font(.caption)
                .foregroundStyle(theme.secondary)
                .frame(width: 72, alignment: .leading)
            Text(copied ? "Copied" : row.value)
                .font(row.monospaced ? .system(size: 11, design: .monospaced) : .caption)
                .foregroundStyle(copied ? theme.accent : theme.primary)
                .textSelection(.enabled)
                .lineLimit(3)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            if row.copyable {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(row.value, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 9))
                        // Dimmed until the row is hovered rather than hidden: a
                        // card of paths shouldn't read as a column of icons, but
                        // the affordance still has to be findable without hover.
                        .foregroundStyle(copied ? theme.accent : (isHovering ? theme.secondary : theme.tertiary))
                }
                .buttonStyle(.plain)
                .help("Copy")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }
}

private struct WorkbenchTranscriptRow: View {
    let message: WorkbenchTranscriptMessage

    var body: some View {
        switch message.kind {
        case .tool:
            // Tool calls are the bulk of a transcript; keep them to one dim line so
            // the conversation stays readable but you can still see the work.
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.tertiary)
                Text(message.toolName ?? "tool")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(message.text)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        case .user, .assistant:
            VStack(alignment: .leading, spacing: 3) {
                Text(message.kind == .user ? "You" : "Claude")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(message.kind == .user ? Color.accentColor : Color.purple)
                Text(message.text)
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 2)
        }
    }
}

struct WorkbenchPanelPlaceholder: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .foregroundStyle(.tertiary)
            Text(title).font(.subheadline.weight(.medium))
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .truncationMode(.middle)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#endif
