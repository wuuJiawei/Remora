import SwiftUI
import RemoraCore

struct TerminalPaneView: View {
    @ObservedObject var pane: TerminalPaneModel
    @ObservedObject private var runtime: TerminalRuntime
    @ObservedObject private var aiAssistant: TerminalAIAssistantCoordinator
    var quickCommands: [HostQuickCommand]
    var isContentVisible: Bool
    var isFocused: Bool
    var canClose: Bool
    var onSelect: () -> Void
    var onToggleCollapse: () -> Void
    var onReconnect: () -> Void
    var onClose: () -> Void
    var onRunQuickCommand: (HostQuickCommand) -> Void
    var onManageQuickCommands: () -> Void
    @RemoraStored(\.aiEnabled) private var aiEnabled: Bool

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
        isContentVisible: Bool = true,
        isFocused: Bool,
        canClose: Bool = false,
        onSelect: @escaping () -> Void,
        onToggleCollapse: @escaping () -> Void = {},
        onReconnect: @escaping () -> Void = {},
        onClose: @escaping () -> Void = {},
        onRunQuickCommand: @escaping (HostQuickCommand) -> Void = { _ in },
        onManageQuickCommands: @escaping () -> Void = {}
    ) {
        self.pane = pane
        self._runtime = ObservedObject(wrappedValue: pane.runtime)
        self._aiAssistant = ObservedObject(wrappedValue: pane.aiAssistant)
        self.quickCommands = quickCommands
        self.isContentVisible = isContentVisible
        self.isFocused = isFocused
        self.canClose = canClose
        self.onSelect = onSelect
        self.onToggleCollapse = onToggleCollapse
        self.onReconnect = onReconnect
        self.onClose = onClose
        self.onRunQuickCommand = onRunQuickCommand
        self.onManageQuickCommands = onManageQuickCommands
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    onToggleCollapse()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: isContentVisible ? "chevron.down" : "chevron.right")
                            .font(.caption.weight(.semibold))

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

                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(VisualStyle.textSecondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isContentVisible ? tr("Collapse Terminal") : tr("Expand Terminal"))
                .accessibilityIdentifier("terminal-collapse-toggle")

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
                        onReconnect()
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

                if aiEnabled {
                    Button {
                        pane.isAIAssistantVisible.toggle()
                        aiAssistant.refreshSmartAssist()
                    } label: {
                        Image(systemName: pane.isAIAssistantVisible ? "sparkles.rectangle.stack.fill" : "sparkles.rectangle.stack")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(pane.isAIAssistantVisible ? Color.accentColor : VisualStyle.textSecondary)
                    .help(tr("Toggle Terminal AI"))
                    .accessibilityIdentifier("terminal-ai-toggle")
                }

                if canClose {
                    Button {
                        onClose()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(VisualStyle.textSecondary)
                    .help(tr("Close Pane"))
                    .accessibilityIdentifier("terminal-close-pane")
                }

                Image(systemName: isFocused ? "cursorarrow.motionlines" : "cursorarrow")
                    .font(.caption)
                    .foregroundStyle(VisualStyle.textSecondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(VisualStyle.rightPanelBackground)

            Divider()
                .overlay(VisualStyle.borderSoft)

            if aiEnabled, !pane.isAIAssistantVisible, let smartAssist = aiAssistant.smartAssist {
                smartAssistBanner(smartAssist)
                Divider()
                    .overlay(VisualStyle.borderSoft)
            }

            if isContentVisible {
                HStack(spacing: 0) {
                    ZStack {
                        VisualStyle.terminalBackground

                        TerminalViewRepresentable(pane: pane, runtime: runtime, onFocus: onSelect)
                            .padding(VisualStyle.terminalContentInset)
                            .simultaneousGesture(
                                TapGesture().onEnded {
                                    onSelect()
                                }
                            )
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if aiEnabled, pane.isAIAssistantVisible {
                        Divider()
                            .overlay(VisualStyle.borderSoft)
                        TerminalAIAssistantView(coordinator: aiAssistant, runtime: runtime)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
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
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: isContentVisible)
        .animation(.easeInOut(duration: 0.18), value: pane.isAIAssistantVisible)
        .onAppear {
            aiAssistant.bind(to: pane.id)
            aiAssistant.refreshSmartAssist()
        }
        .onChange(of: runtime.transcriptSnapshot) {
            aiAssistant.refreshSmartAssist()
        }
        .onChange(of: aiEnabled) {
            if !aiEnabled {
                pane.isAIAssistantVisible = false
            }
            aiAssistant.refreshSmartAssist()
        }
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

    private func smartAssistBanner(_ smartAssist: TerminalAISmartAssist) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .foregroundStyle(Color.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(tr("Terminal AI noticed a likely shell issue."))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(VisualStyle.textPrimary)
                Text(localizedSmartAssistTitle(smartAssist.kind))
                    .font(.system(size: 11))
                    .foregroundStyle(VisualStyle.textSecondary)
            }

            Spacer(minLength: 8)

            Button(tr("Explain")) {
                pane.isAIAssistantVisible = true
                Task { try? await aiAssistant.submit(smartAssist.prompt) }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(VisualStyle.settingsSubtleBackground)
        .accessibilityIdentifier("terminal-ai-smart-assist")
    }

    private func localizedSmartAssistTitle(_ kind: TerminalAISmartAssistKind) -> String {
        switch kind {
        case .permissionDenied:
            return tr("Permission denied")
        case .commandNotFound:
            return tr("Command not found")
        case .missingPath:
            return tr("Missing file or path")
        }
    }
}
