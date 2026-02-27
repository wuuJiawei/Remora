import SwiftUI

struct TerminalPaneView: View {
    @ObservedObject var pane: TerminalPaneModel
    @ObservedObject private var runtime: TerminalRuntime
    var isFocused: Bool
    var onSelect: () -> Void

    private var hostKeyPromptBinding: Binding<Bool> {
        Binding(
            get: { runtime.hostKeyPromptMessage != nil },
            set: { isPresented in
                if !isPresented {
                    runtime.dismissHostKeyPrompt()
                }
            }
        )
    }

    init(pane: TerminalPaneModel, isFocused: Bool, onSelect: @escaping () -> Void) {
        self.pane = pane
        self._runtime = ObservedObject(wrappedValue: pane.runtime)
        self.isFocused = isFocused
        self.onSelect = onSelect
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)

                Text(runtime.connectionState)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .foregroundStyle(VisualStyle.textPrimary)

                Text(runtime.transcriptSnapshot.isEmpty ? " " : runtime.transcriptSnapshot)
                    .font(.system(size: 1))
                    .foregroundStyle(.clear)
                    .opacity(0.01)
                    .frame(width: 12, height: 12)
                    .accessibilityLabel(runtime.transcriptSnapshot.isEmpty ? " " : runtime.transcriptSnapshot)
                    .accessibilityHidden(false)
                    .accessibilityIdentifier("terminal-transcript")

                Spacer()

                Image(systemName: isFocused ? "cursorarrow.motionlines" : "cursorarrow")
                    .font(.caption)
                    .foregroundStyle(VisualStyle.textSecondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(VisualStyle.rightPanelBackground)

            Divider()
                .overlay(VisualStyle.borderSoft)

            TerminalViewRepresentable(runtime: runtime, onFocus: onSelect)
                .background(VisualStyle.terminalBackground)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(VisualStyle.rightPanelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isFocused ? VisualStyle.borderStrong : VisualStyle.borderSoft, lineWidth: isFocused ? 2 : 1)
        )
        .padding(6)
        .contentShape(Rectangle())
        .animation(.spring(response: 0.24, dampingFraction: 0.85), value: isFocused)
        .animation(.easeInOut(duration: 0.18), value: runtime.connectionState)
        .alert("Trust SSH Host Key?", isPresented: hostKeyPromptBinding) {
            Button("Reject", role: .destructive) {
                runtime.respondToHostKeyPrompt(accept: false)
            }
            Button("Trust") {
                runtime.respondToHostKeyPrompt(accept: true)
            }
        } message: {
            Text(runtime.hostKeyPromptMessage ?? "The server requested host key confirmation.")
        }
    }

    private var statusColor: Color {
        if runtime.connectionState.hasPrefix("Connected") {
            return .green
        }
        if runtime.connectionState.hasPrefix("Failed") {
            return .red
        }
        if runtime.connectionState == "Connecting" || runtime.connectionState.hasPrefix("Waiting") {
            return .orange
        }
        return .secondary
    }
}
