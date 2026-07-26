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
            Picker("", selection: tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()

            switch tab.wrappedValue {
            case .info: infoTab
            case .transcript: transcriptTab
            case .git: gitTab
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .controlBackgroundColor))
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
            VStack(alignment: .leading, spacing: 14) {
                actions

                WorkbenchDetailSection("Session") {
                    WorkbenchDetailRow("State", value: stateDescription)
                    if let count = session.messageCount {
                        WorkbenchDetailRow("Messages", value: "\(count)")
                    }
                    if let last = session.lastModifiedAt {
                        WorkbenchDetailRow("Last active", value: last.formatted(date: .abbreviated, time: .shortened))
                    }
                    if let pid = session.runningPID {
                        WorkbenchDetailRow("Process", value: "pid \(pid)")
                    }
                    WorkbenchDetailRow("ID", value: session.id, monospaced: true, copyable: true)
                }

                WorkbenchDetailSection("Location") {
                    if let cwd = session.cwd {
                        WorkbenchDetailRow("Directory", value: cwd, monospaced: true, copyable: true)
                    }
                    if let path = session.transcriptPath {
                        WorkbenchDetailRow("Transcript", value: path, monospaced: true, copyable: true)
                    }
                }

                if !session.tags.isEmpty {
                    WorkbenchDetailSection("Tags") {
                        Text(session.tags.joined(separator: ", ")).font(.caption)
                    }
                }
            }
            .padding(12)
        }
    }

    private var actions: some View {
        // Wraps on a narrow panel instead of clipping.
        HStack(spacing: 8) {
            Button(session.status == .running ? "Open" : "Resume", action: onResume)
            Button("Fork", action: onFork)
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
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Spacer(minLength: 0)
        }
        .controlSize(.small)
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
                    VStack(alignment: .leading, spacing: 14) {
                        WorkbenchDetailSection("Repository") {
                            if let origin = gitInfo.originName {
                                WorkbenchDetailRow("Remote", value: origin)
                            }
                            WorkbenchDetailRow("Root", value: gitInfo.toplevel, monospaced: true, copyable: true)
                            WorkbenchDetailRow(
                                "Checkout",
                                value: gitInfo.isLinkedWorktree ? "Linked worktree" : "Main working tree")
                        }
                        WorkbenchDetailSection("Working tree") {
                            WorkbenchDetailRow("Branch", value: gitInfo.branch ?? "detached", monospaced: true)
                            if let dirty = gitInfo.dirty {
                                WorkbenchDetailRow(
                                    "Changes",
                                    value: dirty == 0 ? "Clean" : "\(dirty) file(s) modified")
                            }
                        }
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

private struct WorkbenchDetailSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .kerning(0.6)
            VStack(alignment: .leading, spacing: 5) { content }
        }
    }
}

private struct WorkbenchDetailRow: View {
    let label: String
    let value: String
    var monospaced = false
    var copyable = false
    @State private var copied = false

    init(_ label: String, value: String, monospaced: Bool = false, copyable: Bool = false) {
        self.label = label
        self.value = value
        self.monospaced = monospaced
        self.copyable = copyable
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)
            Text(copied ? "Copied" : value)
                .font(monospaced ? .system(size: 11, design: .monospaced) : .caption)
                .foregroundStyle(copied ? Color.accentColor : Color.primary)
                .textSelection(.enabled)
                .lineLimit(3)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            if copyable {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                } label: {
                    Image(systemName: "doc.on.doc").font(.system(size: 9))
                }
                .buttonStyle(.borderless)
                .help("Copy")
            }
        }
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
