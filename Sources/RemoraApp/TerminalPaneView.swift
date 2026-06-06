import SwiftUI
import RemoraCore

struct TerminalPaneView: View {
    private enum AuthPromptKind {
        case hostKey
        case otp
        case password
    }

    @ObservedObject var pane: TerminalPaneModel
    @ObservedObject private var runtime: TerminalRuntime
    @ObservedObject private var aiAssistant: TerminalAIAssistantCoordinator
    var quickCommands: [HostQuickCommand]
    var isContentVisible: Bool
    var isFocused: Bool
    var isInFocusMode: Bool
    var canClose: Bool
    var onSelect: () -> Void
    var onToggleCollapse: () -> Void
    var onToggleFocusMode: () -> Void
    var onReconnect: () -> Void
    var onClose: () -> Void
    var onRunQuickCommand: (HostQuickCommand) -> Void
    var onManageQuickCommands: () -> Void
    var onOpenFileManagerWorkspace: () -> Void
    var onOpenDockerWorkspace: () -> Void
    @RemoraStored(\.aiEnabled) private var aiEnabled: Bool
    @State private var smartAssistNotificationState = TerminalSmartAssistNotificationState()
    @State private var otpInputCode: String = ""
    @State private var passwordInput: String = ""
    @State private var hoveredToolbarItem: String?

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

    private var otpPromptBinding: Binding<Bool> {
        Binding(
            get: { runtime.otpPromptMessage != nil },
            set: { isPresented in
                if !isPresented {
                    runtime.dismissOTPPrompt()
                }
            }
        )
    }

    private var passwordPromptBinding: Binding<Bool> {
        Binding(
            get: { runtime.passwordPromptMessage != nil },
            set: { isPresented in
                if !isPresented {
                    runtime.dismissPasswordPrompt()
                }
            }
        )
    }

    private var activeAuthPrompt: AuthPromptKind? {
        if runtime.hostKeyPromptMessage != nil { return .hostKey }
        if runtime.otpPromptMessage != nil { return .otp }
        if runtime.passwordPromptMessage != nil { return .password }
        return nil
    }

    init(
        pane: TerminalPaneModel,
        quickCommands: [HostQuickCommand] = [],
        isContentVisible: Bool = true,
        isFocused: Bool,
        isInFocusMode: Bool = false,
        canClose: Bool = false,
        onSelect: @escaping () -> Void,
        onToggleCollapse: @escaping () -> Void = {},
        onToggleFocusMode: @escaping () -> Void = {},
        onReconnect: @escaping () -> Void = {},
        onClose: @escaping () -> Void = {},
        onRunQuickCommand: @escaping (HostQuickCommand) -> Void = { _ in },
        onManageQuickCommands: @escaping () -> Void = {},
        onOpenFileManagerWorkspace: @escaping () -> Void = {},
        onOpenDockerWorkspace: @escaping () -> Void = {}
    ) {
        self.pane = pane
        self._runtime = ObservedObject(wrappedValue: pane.runtime)
        self._aiAssistant = ObservedObject(wrappedValue: pane.aiAssistant)
        self.quickCommands = quickCommands
        self.isContentVisible = isContentVisible
        self.isFocused = isFocused
        self.isInFocusMode = isInFocusMode
        self.canClose = canClose
        self.onSelect = onSelect
        self.onToggleCollapse = onToggleCollapse
        self.onToggleFocusMode = onToggleFocusMode
        self.onReconnect = onReconnect
        self.onClose = onClose
        self.onRunQuickCommand = onRunQuickCommand
        self.onManageQuickCommands = onManageQuickCommands
        self.onOpenFileManagerWorkspace = onOpenFileManagerWorkspace
        self.onOpenDockerWorkspace = onOpenDockerWorkspace
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Group {
                    if isInFocusMode {
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

                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(VisualStyle.textSecondary)
                    } else {
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
                        .accessibilityLabel(isContentVisible ? tr("Collapse Terminal") : tr("Expand Terminal"))
                        .accessibilityIdentifier("terminal-collapse-toggle")
                    }
                }

                terminalToolbarItems
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(minHeight: 24, alignment: .center)
            .background(VisualStyle.rightPanelBackground)

            Divider()
                .overlay(VisualStyle.borderSoft)

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
                .overlay(alignment: .topTrailing) {
                    if let smartAssist = visibleSmartAssistNotification {
                        smartAssistNotification(smartAssist)
                            .padding(.top, 12)
                            .padding(.trailing, 12)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
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
            smartAssistNotificationState.sync(currentSmartAssist: aiAssistant.smartAssist, aiEnabled: aiEnabled)
        }
        .onChange(of: runtime.transcriptSnapshot) {
            aiAssistant.refreshSmartAssist()
        }
        .onChange(of: aiEnabled) {
            if !aiEnabled {
                pane.isAIAssistantVisible = false
            }
            smartAssistNotificationState.sync(currentSmartAssist: aiAssistant.smartAssist, aiEnabled: aiEnabled)
            aiAssistant.refreshSmartAssist()
        }
        .onChange(of: aiAssistant.smartAssist) {
            smartAssistNotificationState.sync(currentSmartAssist: aiAssistant.smartAssist, aiEnabled: aiEnabled)
        }
        .onChange(of: pane.isAIAssistantVisible) {
            guard pane.isAIAssistantVisible, let smartAssist = aiAssistant.smartAssist else { return }
            smartAssistNotificationState.dismiss(smartAssist)
        }
        .alert(
            activeAuthPrompt == .hostKey ? tr("Trust SSH Host Key?")
                : activeAuthPrompt == .otp ? tr("OTP Verification")
                : tr("SSH Password"),
            isPresented: Binding(
                get: { activeAuthPrompt != nil },
                set: { isPresented in
                    guard !isPresented else { return }
                    switch activeAuthPrompt {
                    case .hostKey:
                        runtime.dismissHostKeyPrompt()
                    case .otp:
                        runtime.dismissOTPPrompt()
                    case .password:
                        runtime.dismissPasswordPrompt()
                    case nil:
                        break
                    }
                }
            )
        ) {
            switch activeAuthPrompt {
            case .hostKey:
                Button(tr("Reject"), role: .destructive) {
                    runtime.respondToHostKeyPrompt(accept: false)
                }
                Button(tr("Trust")) {
                    runtime.respondToHostKeyPrompt(accept: true)
                }
            case .otp:
                TextField(tr("Enter code"), text: $otpInputCode)
                Button(tr("Cancel"), role: .cancel) {
                    otpInputCode = ""
                    runtime.dismissOTPPrompt()
                }
                Button(tr("OK")) {
                    runtime.respondToOTPPrompt(code: otpInputCode)
                    otpInputCode = ""
                }
            case .password:
                SecureField(tr("Enter password"), text: $passwordInput)
                Button(tr("Cancel"), role: .cancel) {
                    passwordInput = ""
                    runtime.dismissPasswordPrompt()
                }
                Button(tr("OK")) {
                    runtime.respondToPasswordPrompt(password: passwordInput)
                    passwordInput = ""
                }
            case nil:
                EmptyView()
            }
        } message: {
            switch activeAuthPrompt {
            case .hostKey:
                Text(runtime.hostKeyPromptMessage ?? tr("The server requested host key confirmation."))
            case .otp:
                if let host = runtime.otpPromptMessage, !host.isEmpty {
                    Text(host)
                }
            case .password:
                if let host = runtime.passwordPromptMessage, !host.isEmpty {
                    Text(host)
                }
            case nil:
                EmptyView()
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

    private var visibleSmartAssistNotification: TerminalAISmartAssist? {
        smartAssistNotificationState.visibleSmartAssist(
            aiEnabled: aiEnabled,
            isAIAssistantVisible: pane.isAIAssistantVisible,
            smartAssist: aiAssistant.smartAssist
        )
    }

    @ViewBuilder
    private var dockerToolbarIcon: some View {
        if let url = Bundle.module.url(forResource: "docker-mark-ocean-blue", withExtension: "png", subdirectory: "ToolbarIcons"),
           let image = renderedDockerToolbarImage(from: url) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .antialiased(true)
                .frame(width: 16, height: 16)
        } else {
            Image(systemName: "cube")
                .terminalToolbarIcon()
        }
    }

    private func renderedDockerToolbarImage(from url: URL) -> NSImage? {
        LogManager.debug(.app, "docker toolbar icon url=\(url.path)")
        guard let image = NSImage(contentsOf: url) else { return nil }
        let rendered = image.copy() as? NSImage ?? image
        rendered.isTemplate = false
        return rendered
    }

    private func smartAssistNotification(_ smartAssist: TerminalAISmartAssist) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.accentColor)

                VStack(alignment: .leading, spacing: 3) {
                    Text(tr("Terminal AI noticed a likely shell issue."))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(VisualStyle.textPrimary)
                    Text(localizedSmartAssistTitle(smartAssist.kind))
                        .font(.system(size: 11))
                        .foregroundStyle(VisualStyle.textSecondary)
                }

                Spacer(minLength: 6)

                Button {
                    smartAssistNotificationState.dismiss(smartAssist)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(VisualStyle.textSecondary)
                }
                .buttonStyle(.plain)
                .help(tr("Close"))
                .accessibilityLabel(tr("Close"))
                .accessibilityIdentifier("terminal-ai-smart-assist-dismiss")
            }

            HStack(spacing: 8) {
                Spacer(minLength: 0)

                Button(tr("Explain")) {
                    smartAssistNotificationState.dismiss(smartAssist)
                    pane.isAIAssistantVisible = true
                    Task { try? await aiAssistant.submit(smartAssist.prompt) }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .accessibilityIdentifier("terminal-ai-smart-assist-explain")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: 320, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(VisualStyle.overlayBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(VisualStyle.borderSoft, lineWidth: 1)
        )
        .shadow(color: VisualStyle.shadowColor, radius: 8, y: 3)
        .accessibilityIdentifier("terminal-ai-smart-assist-notification")
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

    @ViewBuilder
    private var terminalToolbarItems: some View {
        HStack(spacing: 6) {
            if runtime.connectionMode == .ssh {
                Button {
                    onSelect()
                    onOpenFileManagerWorkspace()
                } label: {
                    Image(systemName: "folder")
                        .terminalToolbarIcon()
                }
                .buttonStyle(TerminalToolbarIconButtonStyle(isHovering: hoveredToolbarItem == "files"))
                .onHover { hoveredToolbarItem = $0 ? "files" : (hoveredToolbarItem == "files" ? nil : hoveredToolbarItem) }
                .accessibilityLabel(tr("Open File Manager Workspace"))
                .accessibilityIdentifier("terminal-open-file-manager-workspace")

                Button {
                    onSelect()
                    onOpenDockerWorkspace()
                } label: {
                    dockerToolbarIcon
                }
                .buttonStyle(TerminalToolbarIconButtonStyle(isHovering: hoveredToolbarItem == "docker"))
                .onHover { hoveredToolbarItem = $0 ? "docker" : (hoveredToolbarItem == "docker" ? nil : hoveredToolbarItem) }
                .accessibilityLabel(tr("Open Docker Workspace"))
                .accessibilityIdentifier("terminal-open-docker-workspace")

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
                    Image(systemName: "bolt")
                        .terminalToolbarIcon()
                }
                .menuStyle(.borderlessButton)
                .modifier(TerminalToolbarMenuChrome(isHovering: hoveredToolbarItem == "quick", isActive: false))
                .onHover { hoveredToolbarItem = $0 ? "quick" : (hoveredToolbarItem == "quick" ? nil : hoveredToolbarItem) }
                .accessibilityLabel(tr("Run SSH quick command"))
                .accessibilityIdentifier("terminal-quick-commands")

                Button {
                    onSelect()
                    onToggleFocusMode()
                } label: {
                    Image(systemName: isInFocusMode ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        .terminalToolbarIcon()
                }
                .buttonStyle(TerminalToolbarIconButtonStyle(isActive: isInFocusMode, isHovering: hoveredToolbarItem == "focus"))
                .onHover { hoveredToolbarItem = $0 ? "focus" : (hoveredToolbarItem == "focus" ? nil : hoveredToolbarItem) }
                .accessibilityLabel(isInFocusMode ? tr("Exit Terminal Focus") : tr("Focus Terminal"))
                .accessibilityIdentifier("terminal-focus-toggle")

                Button {
                    onSelect()
                    onReconnect()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .terminalToolbarIcon()
                }
                .buttonStyle(TerminalToolbarIconButtonStyle(isDisabled: !canReconnect, isHovering: hoveredToolbarItem == "reconnect"))
                .onHover { hoveredToolbarItem = $0 ? "reconnect" : (hoveredToolbarItem == "reconnect" ? nil : hoveredToolbarItem) }
                .disabled(!canReconnect)
                .accessibilityLabel(tr("Reconnect SSH"))
                .accessibilityIdentifier("terminal-reconnect")
            }

            if aiEnabled {
                Button {
                    pane.isAIAssistantVisible.toggle()
                    aiAssistant.refreshSmartAssist()
                } label: {
                    Image(systemName: "sparkles")
                        .terminalToolbarIcon()
                }
                .buttonStyle(TerminalToolbarIconButtonStyle(isActive: pane.isAIAssistantVisible, isHovering: hoveredToolbarItem == "ai"))
                .onHover { hoveredToolbarItem = $0 ? "ai" : (hoveredToolbarItem == "ai" ? nil : hoveredToolbarItem) }
                .accessibilityLabel(tr("Toggle Terminal AI"))
                .accessibilityIdentifier("terminal-ai-toggle")
            }

            if canClose {
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .terminalToolbarIcon()
                }
                .buttonStyle(TerminalToolbarIconButtonStyle(isHovering: hoveredToolbarItem == "close"))
                .onHover { hoveredToolbarItem = $0 ? "close" : (hoveredToolbarItem == "close" ? nil : hoveredToolbarItem) }
                .accessibilityLabel(tr("Close Pane"))
                .accessibilityIdentifier("terminal-close-pane")
            }
        }
    }
}

private struct TerminalToolbarIconButtonStyle: ButtonStyle {
    var isActive = false
    var isDisabled = false
    var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(foregroundColor(configuration: configuration))
            .frame(width: 24, height: 24)
            .background(background(configuration: configuration))
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .animation(.easeInOut(duration: 0.12), value: configuration.isPressed)
    }

    @ViewBuilder
    private func background(configuration: Configuration) -> some View {
        let fillColor: Color = {
            if configuration.isPressed {
                return VisualStyle.borderSoft.opacity(0.9)
            }
            if isActive {
                return VisualStyle.borderSoft.opacity(0.75)
            }
            if isHovering && !isDisabled {
                return VisualStyle.borderSoft.opacity(0.35)
            }
            return .clear
        }()

        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(fillColor)
    }

    private func foregroundColor(configuration: Configuration) -> Color {
        if isDisabled {
            return VisualStyle.textTertiary
        }
        if isActive {
            return VisualStyle.textPrimary
        }
        if configuration.isPressed {
            return VisualStyle.textPrimary
        }
        return VisualStyle.textSecondary
    }
}

private struct TerminalToolbarMenuChrome: ViewModifier {
    var isHovering: Bool
    var isActive: Bool

    func body(content: Content) -> some View {
        content
            .foregroundStyle(isActive ? VisualStyle.textPrimary : VisualStyle.textSecondary)
            .frame(width: 24, height: 24)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(backgroundFill)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private var backgroundFill: Color {
        if isActive {
            return VisualStyle.borderSoft.opacity(0.75)
        }
        if isHovering {
            return VisualStyle.borderSoft.opacity(0.35)
        }
        return .clear
    }
}

private extension Image {
    func terminalToolbarIcon() -> some View {
        self
            .font(.system(size: 15, weight: .regular))
            .scaleEffect(0.88)
            .symbolRenderingMode(.hierarchical)
            .imageScale(.medium)
    }
}
