import SwiftUI
import RemoraCore

struct TerminalPaneView: View {
    @ObservedObject var pane: TerminalPaneModel
    @ObservedObject private var runtime: TerminalRuntime
    @StateObject private var aiCoordinator: SessionAIAssistantCoordinator
    @State private var aiInputText = ""
    @State private var isAISidecarExpanded = true
    @State private var aiErrorMessage: String?
    @AppStorage(AppSettings.aiEnabledKey) private var isAIEnabled = AppSettings.defaultAIEnabled
    var quickCommands: [HostQuickCommand]
    var isFocused: Bool
    var onSelect: () -> Void
    var onRunQuickCommand: (HostQuickCommand) -> Void
    var onManageQuickCommands: () -> Void

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

    init(
        pane: TerminalPaneModel,
        quickCommands: [HostQuickCommand] = [],
        isFocused: Bool,
        onSelect: @escaping () -> Void,
        onRunQuickCommand: @escaping (HostQuickCommand) -> Void = { _ in },
        onManageQuickCommands: @escaping () -> Void = {}
    ) {
        self.pane = pane
        self._runtime = ObservedObject(wrappedValue: pane.runtime)
        self._aiCoordinator = StateObject(wrappedValue: SessionAIAssistantCoordinator())
        self.quickCommands = quickCommands
        self.isFocused = isFocused
        self.onSelect = onSelect
        self.onRunQuickCommand = onRunQuickCommand
        self.onManageQuickCommands = onManageQuickCommands
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar

            Divider()
                .overlay(VisualStyle.borderSoft)

            terminalAndAISidecar
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
        .alert(tr("Trust SSH Host Key?"), isPresented: hostKeyPromptBinding) {
            Button(tr("Reject"), role: .destructive) {
                runtime.respondToHostKeyPrompt(accept: false)
            }
            Button(tr("Trust")) {
                runtime.respondToHostKeyPrompt(accept: true)
            }
        } message: {
            Text(runtime.hostKeyPromptMessage ?? tr("The server requested host key confirmation."))
        }
        .onAppear {
            bindAISessionIfNeeded()
        }
        .onChange(of: pane.id) { _, _ in
            bindAISessionIfNeeded()
        }
        .onChange(of: isAIEnabled) { _, enabled in
            if !enabled {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isAISidecarExpanded = false
                }
                aiInputText = ""
                aiErrorMessage = nil
            }
        }
    }

    private var headerBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            Text(localizedConnectionState(runtime.connectionState))
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

            if runtime.connectionMode == .ssh {
                Menu {
                    if quickCommands.isEmpty {
                        Text(tr("No quick commands"))
                    } else {
                        ForEach(quickCommands) { quickCommand in
                            Button(quickCommand.name) {
                                onRunQuickCommand(quickCommand)
                            }
                        }
                    }
                    Divider()
                    Button(tr("Manage quick commands")) {
                        onManageQuickCommands()
                    }
                } label: {
                    Image(systemName: "bolt.circle")
                        .font(.caption.weight(.semibold))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .foregroundStyle(VisualStyle.textSecondary)
                .help(tr("Run SSH quick command"))
                .accessibilityIdentifier("terminal-quick-commands")

                Button {
                    onSelect()
                    runtime.reconnectSSHSession()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(canReconnect ? VisualStyle.textSecondary : VisualStyle.textTertiary)
                .disabled(!canReconnect)
                .help(tr("Reconnect SSH"))
                .accessibilityIdentifier("terminal-reconnect")
            }

            if isAIEnabled {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isAISidecarExpanded.toggle()
                    }
                } label: {
                    Image(systemName: isAISidecarExpanded ? "sparkles.rectangle.stack.fill" : "sparkles.rectangle.stack")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(VisualStyle.textSecondary)
                .help(tr("Toggle AI sidecar"))
                .accessibilityIdentifier("terminal-ai-toggle")
            }

            Image(systemName: isFocused ? "cursorarrow.motionlines" : "cursorarrow")
                .font(.caption)
                .foregroundStyle(VisualStyle.textSecondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(VisualStyle.rightPanelBackground)
    }

    private var terminalAndAISidecar: some View {
        HStack(spacing: 0) {
            TerminalViewRepresentable(runtime: runtime, onFocus: onSelect)
                .background(VisualStyle.terminalBackground)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if isAIEnabled && isAISidecarExpanded {
                Divider()
                    .overlay(VisualStyle.borderSoft)

                AISidecarPanel(
                    coordinator: aiCoordinator,
                    inputText: $aiInputText,
                    errorMessage: aiErrorMessage,
                    onSubmit: submitAIMessage
                )
                .frame(width: 280)
                .background(VisualStyle.rightPanelBackground)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
    }

    private var statusColor: Color {
        if runtime.connectionState.hasPrefix(TerminalRuntime.connectedPrefix) {
            return .green
        }
        if runtime.connectionState.hasPrefix(TerminalRuntime.failedPrefix) {
            return .red
        }
        if runtime.connectionState == TerminalRuntime.connectingState || runtime.connectionState.hasPrefix(TerminalRuntime.waitingPrefix) {
            return .orange
        }
        return .secondary
    }

    private var canReconnect: Bool {
        guard runtime.reconnectableSSHHost != nil else { return false }
        if runtime.connectionState == TerminalRuntime.connectingState || runtime.connectionState.hasPrefix(TerminalRuntime.waitingPrefix) {
            return false
        }
        return true
    }

    private var canSubmitAIInput: Bool {
        !aiInputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !aiCoordinator.isResponding
    }

    @MainActor
    private func bindAISessionIfNeeded() {
        guard aiCoordinator.boundSessionID != pane.id else { return }
        aiCoordinator.bind(to: pane.id)
    }

    @MainActor
    private func submitAIMessage() {
        guard canSubmitAIInput else { return }
        let text = aiInputText.trimmingCharacters(in: .whitespacesAndNewlines)
        aiInputText = ""
        aiErrorMessage = nil

        Task {
            do {
                try await aiCoordinator.sendUserMessage(text)
            } catch {
                await MainActor.run {
                    aiErrorMessage = error.localizedDescription
                    if aiInputText.isEmpty {
                        aiInputText = text
                    }
                }
            }
        }
    }
}

private struct AISidecarPanel: View {
    @ObservedObject var coordinator: SessionAIAssistantCoordinator
    @Binding var inputText: String
    let errorMessage: String?
    let onSubmit: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(tr("AI Assistant"), systemImage: "sparkles")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(VisualStyle.textPrimary)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(VisualStyle.rightPanelBackground)

            Divider()
                .overlay(VisualStyle.borderSoft)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(coordinator.messages) { message in
                        HStack {
                            if message.role == .assistant {
                                bubble(message.content, isUser: false)
                                Spacer(minLength: 24)
                            } else {
                                Spacer(minLength: 24)
                                bubble(message.content, isUser: true)
                            }
                        }
                    }

                    if coordinator.isResponding {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text(tr("AI is thinking..."))
                                .font(.caption)
                                .foregroundStyle(VisualStyle.textSecondary)
                            Spacer()
                        }
                        .padding(.horizontal, 6)
                    }
                }
                .padding(10)
            }
            .accessibilityIdentifier("terminal-ai-sidecar")

            if let errorMessage, !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.top, 4)
            }

            HStack(spacing: 8) {
                TextField(tr("Ask AI about this session"), text: $inputText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(onSubmit)
                    .accessibilityIdentifier("terminal-ai-input")

                Button(action: onSubmit) {
                    Image(systemName: "paperplane.fill")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || coordinator.isResponding)
                .accessibilityIdentifier("terminal-ai-send")
            }
            .padding(10)
            .background(VisualStyle.rightPanelBackground)
        }
    }

    private func bubble(_ text: String, isUser: Bool) -> some View {
        Text(text)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(isUser ? Color.white : VisualStyle.textPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isUser ? Color.accentColor : VisualStyle.rightPanelBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(VisualStyle.borderSoft, lineWidth: isUser ? 0 : 1)
            )
    }
}
