#if os(macOS)
import AppKit
import SwiftUI

struct WorkbenchInspectorView: View {
    let session: WorkbenchSessionRecord?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Session Inspector")
                .font(.headline)
            if let session {
                GroupBox("Session") {
                    LabeledContent("ID", value: session.id)
                    LabeledContent("Status", value: session.status.rawValue)
                    if let transcriptPath = session.transcriptPath {
                        LabeledContent("Transcript", value: transcriptPath)
                    }
                    if let lastExitCode = session.lastExitCode {
                        LabeledContent("Last exit", value: String(lastExitCode))
                    }
                }
                GroupBox("Launch") {
                    LabeledContent("Command", value: "claude --resume \(session.id)")
                    LabeledContent("Working directory", value: session.cwd ?? "Unknown")
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "sidebar.left")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("No Session Selected")
                        .font(.headline)
                    Text("Select a Claude Code session in the sidebar.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Spacer()
        }
        .padding(12)
        .frame(minWidth: 260, idealWidth: 300, maxWidth: 360)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

#endif
