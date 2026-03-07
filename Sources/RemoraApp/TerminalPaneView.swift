import SwiftUI
import RemoraCore

enum TerminalPaneSection: Equatable {
    case commandComposer
    case terminal
}

struct TerminalPaneLayout: Equatable {
    var sections: [TerminalPaneSection]
    var terminalAllowsKeyboardInput: Bool
    var terminalPrefersInitialFocus: Bool

    static func resolve(
        isCommandComposerVisible: Bool,
        placement: TerminalCommandComposerPlacement,
        isPaneFocused: Bool
    ) -> TerminalPaneLayout {
        if isCommandComposerVisible {
            let sections: [TerminalPaneSection] = placement == .top
                ? [.commandComposer, .terminal]
                : [.terminal, .commandComposer]
            return TerminalPaneLayout(
                sections: sections,
                terminalAllowsKeyboardInput: false,
                terminalPrefersInitialFocus: false
            )
        }

        return TerminalPaneLayout(
            sections: [.terminal],
            terminalAllowsKeyboardInput: true,
            terminalPrefersInitialFocus: isPaneFocused
        )
    }
}

struct TerminalPaneView: View {
    @ObservedObject var pane: TerminalPaneModel
    @ObservedObject private var runtime: TerminalRuntime
    @AppStorage(AppSettings.terminalCommandComposerPlacementKey)
    private var commandComposerPlacementRawValue = AppSettings.defaultTerminalCommandComposerPlacement.rawValue
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
        self.quickCommands = quickCommands
        self.isFocused = isFocused
        self.onSelect = onSelect
        self.onRunQuickCommand = onRunQuickCommand
        self.onManageQuickCommands = onManageQuickCommands
    }

    var body: some View {
        VStack(spacing: 0) {
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

                Image(systemName: isFocused ? "cursorarrow.motionlines" : "cursorarrow")
                    .font(.caption)
                    .foregroundStyle(VisualStyle.textSecondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(VisualStyle.rightPanelBackground)

            Divider()
                .overlay(VisualStyle.borderSoft)

            VStack(spacing: 0) {
                ForEach(Array(paneLayout.sections.enumerated()), id: \.offset) { _, section in
                    paneSectionView(section)
                }
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

    private var commandComposerPlacement: TerminalCommandComposerPlacement {
        TerminalCommandComposerPlacement(rawValue: commandComposerPlacementRawValue)
            ?? AppSettings.defaultTerminalCommandComposerPlacement
    }

    private var paneLayout: TerminalPaneLayout {
        TerminalPaneLayout.resolve(
            isCommandComposerVisible: runtime.isCommandComposerVisible,
            placement: commandComposerPlacement,
            isPaneFocused: isFocused
        )
    }

    @ViewBuilder
    private func paneSectionView(_ section: TerminalPaneSection) -> some View {
        switch section {
        case .commandComposer:
            commandComposerSection
        case .terminal:
            terminalSection
        }
    }

    private var terminalSection: some View {
        TerminalViewRepresentable(
            runtime: runtime,
            allowsKeyboardInput: paneLayout.terminalAllowsKeyboardInput,
            prefersInitialFocus: paneLayout.terminalPrefersInitialFocus,
            onFocus: onSelect
        )
        .background(VisualStyle.terminalBackground)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("terminal-pane-terminal")
    }

    private var commandComposerSection: some View {
        VStack(spacing: 0) {
            Divider()
                .overlay(Color.white.opacity(0.08))
            CommandComposerView(
                text: runtime.commandComposerText,
                selection: runtime.commandComposerSelection,
                isFocused: isFocused && runtime.isCommandComposerVisible,
                onSubmit: runtime.submitCommandComposer,
                onRequestShellCompletion: runtime.requestCommandComposerCompletion,
                onEditorStateChange: { text, selection, isComposing in
                    runtime.updateCommandComposer(
                        text: text,
                        selection: selection,
                        isComposing: isComposing
                    )
                },
                onSelectionChange: { selection, isComposing in
                    runtime.updateCommandComposerSelection(
                        selection,
                        isComposing: isComposing
                    )
                }
            )
            .frame(minHeight: 48, idealHeight: 72, maxHeight: 144)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(VisualStyle.terminalBackground)
            .accessibilityIdentifier("terminal-command-composer")
        }
        .background(VisualStyle.terminalBackground)
    }
}
