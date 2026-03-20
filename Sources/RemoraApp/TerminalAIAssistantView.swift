import AppKit
import SwiftUI

struct TerminalAIAssistantView: View {
    @ObservedObject var coordinator: TerminalAIAssistantCoordinator
    @ObservedObject var runtime: TerminalRuntime

    @State private var promptDraft = ""
    @State private var submissionError: String?
    @State private var pendingRunCommand: TerminalAICommandSuggestion?
    @State private var isNearBottom = true
    @State private var viewportBottomGlobal: CGFloat = 0
    @State private var bottomMarkerMaxY: CGFloat = 0
    @AppStorage(AppSettings.aiRequireRunConfirmationKey)
    private var aiRequireRunConfirmation = AppSettings.defaultAIRequireRunConfirmation

    private let bottomAnchorID = "terminal-ai-bottom-anchor"

    var body: some View {
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 0) {
                header
                Divider()
                    .overlay(VisualStyle.borderSoft)

                quickActions

                if let submissionError {
                    Text(submissionError)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.orange)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                }

                if !coordinator.queuedPrompts.isEmpty {
                    queuedPromptStrip
                }

                transcriptScrollView(proxy: proxy)

                Divider()
                    .overlay(VisualStyle.borderSoft)

                composer
            }
            .frame(minWidth: 280, idealWidth: 340, maxWidth: 380, maxHeight: .infinity, alignment: .topLeading)
            .background(VisualStyle.settingsSurfaceBackground)
            .accessibilityIdentifier("terminal-ai-drawer")
            .onAppear {
                scrollToBottom(proxy, animated: false)
            }
            .onChange(of: coordinator.messages) { _, _ in
                if isNearBottom {
                    scrollToBottom(proxy)
                }
            }
            .alert(tr("Run AI command?"), isPresented: Binding(
                get: { pendingRunCommand != nil },
                set: { isPresented in
                    if !isPresented {
                        pendingRunCommand = nil
                    }
                }
            )) {
                Button(tr("Cancel"), role: .cancel) {
                    pendingRunCommand = nil
                }
                Button(tr("Always Run")) {
                    aiRequireRunConfirmation = false
                    if let command = pendingRunCommand?.command {
                        runtime.runAssistantCommand(command)
                    }
                    pendingRunCommand = nil
                }
                Button(tr("Run")) {
                    if let command = pendingRunCommand?.command {
                        runtime.runAssistantCommand(command)
                    }
                    pendingRunCommand = nil
                }
            } message: {
                Text(pendingRunCommand?.command ?? tr("This command will be sent to the current terminal session."))
            }
        }
    }

    private func transcriptScrollView(proxy: ScrollViewProxy) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if coordinator.messages.isEmpty {
                            emptyState
                        } else {
                            ForEach(coordinator.messages) { message in
                                messageCard(message)
                            }
                        }

                        Color.clear
                            .frame(height: 1)
                            .id(bottomAnchorID)
                            .background(
                                GeometryReader { markerProxy in
                                    Color.clear.preference(
                                        key: TerminalAIBottomMarkerPreferenceKey.self,
                                        value: markerProxy.frame(in: .global).maxY
                                    )
                                }
                            )
                    }
                    .padding(12)
                }
                .coordinateSpace(name: "terminal-ai-scroll")
                .background(
                    Color.clear.onAppear {
                        viewportBottomGlobal = geometry.frame(in: .global).maxY
                    }
                    .onChange(of: geometry.frame(in: .global)) { _, frame in
                        viewportBottomGlobal = frame.maxY
                    }
                )
                .onPreferenceChange(TerminalAIBottomMarkerPreferenceKey.self) { maxY in
                    bottomMarkerMaxY = maxY
                    updateScrollPosition()
                }

                if shouldShowScrollToLatest {
                    bottomOverlay

                    Button {
                        scrollToBottom(proxy)
                    } label: {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 22, weight: .semibold))
                            .symbolRenderingMode(.hierarchical)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                        .padding(.trailing, 14)
                        .padding(.bottom, 14)
                        .help(tr("Jump to latest message"))
                    .accessibilityIdentifier("terminal-ai-scroll-to-bottom")
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(tr("Terminal AI"))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(VisualStyle.textPrimary)

            if let workingDirectory = runtime.workingDirectory, !workingDirectory.isEmpty {
                Text(workingDirectory)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(VisualStyle.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var quickActions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(tr("Quick Actions"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(VisualStyle.textSecondary)

            HStack(spacing: 8) {
                actionButton(title: tr("Explain Output"), prompt: "Explain the latest terminal output in plain language.")
                actionButton(title: tr("Suggest Next Command"), prompt: "Suggest the safest next command for this terminal session.")
            }

            actionButton(
                title: tr("Fix Last Error"),
                prompt: coordinator.smartAssist?.prompt ?? "Explain the latest terminal error and suggest the safest next command."
            )
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    private var queuedPromptStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(tr("Queued Messages"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(VisualStyle.textSecondary)

            ForEach(coordinator.queuedPrompts) { item in
                TerminalAIQueuedPromptRow(item: item) {
                    coordinator.removeQueuedPrompt(id: item.id)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func actionButton(title: String, prompt: String) -> some View {
        Button(title) {
            submit(prompt)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(tr("No AI messages yet."))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(VisualStyle.textPrimary)

            Text(tr("Ask Terminal AI about terminal output, next commands, or the safest way to recover from an error."))
                .font(.system(size: 12))
                .foregroundStyle(VisualStyle.textSecondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(VisualStyle.settingsSubtleBackground)
        )
    }

    @ViewBuilder
    private func messageCard(_ message: TerminalAIAssistantMessage) -> some View {
        if let prompt = message.prompt {
            VStack(alignment: .leading, spacing: 6) {
                Text(tr("You"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text(prompt)
                    .font(.system(size: 13))
                    .foregroundStyle(VisualStyle.textPrimary)
                    .textSelection(.enabled)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(VisualStyle.settingsSubtleBackground.opacity(0.92))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(VisualStyle.borderSoft.opacity(0.8), lineWidth: 1)
            )
        } else {
            assistantCard(message)
        }
    }

    private func assistantCard(_ message: TerminalAIAssistantMessage) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if message.isThinking {
                    TerminalAIThinkingHaloView()
                        .frame(width: 14, height: 14)
                }

                Text(tr("Terminal AI"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }

            if message.isThinking {
                HStack(spacing: 8) {
                    Text(tr("Thinking…"))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(VisualStyle.textPrimary)

                    TerminalAIThinkingDotsView()
                }
            }

            if let streamedText = message.streamedText, !streamedText.isEmpty {
                Text(message.isStreaming ? streamedText + "▌" : streamedText)
                    .font(.system(size: 13))
                    .foregroundStyle(VisualStyle.textPrimary)
                    .textSelection(.enabled)
            }

            if let response = message.response {
                Text(response.summary)
                    .font(.system(size: 13))
                    .foregroundStyle(VisualStyle.textPrimary)
                    .textSelection(.enabled)

                if !response.commands.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(response.commands.enumerated()), id: \.offset) { _, command in
                            TerminalAICommandCardView(
                                suggestion: command,
                                onInsert: { runtime.insertAssistantCommand(command.command) },
                                onRun: {
                                    if aiRequireRunConfirmation {
                                        pendingRunCommand = command
                                    } else {
                                        runtime.runAssistantCommand(command.command)
                                    }
                                },
                                onCopy: {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(command.command, forType: .string)
                                }
                            )
                        }
                    }
                }

                if !response.warnings.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(tr("Warnings"))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.orange)

                        ForEach(response.warnings, id: \.self) { warning in
                            Text("• \(warning)")
                                .font(.system(size: 12))
                                .foregroundStyle(VisualStyle.textSecondary)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(message.isThinking || message.isStreaming ? Color.accentColor.opacity(0.35) : VisualStyle.borderSoft, lineWidth: 1)
        )
        .shadow(color: Color.accentColor.opacity(message.isThinking ? 0.12 : 0), radius: 18, y: 8)
        .animation(.easeInOut(duration: 0.18), value: message.isThinking)
        .animation(.easeInOut(duration: 0.18), value: message.isStreaming)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                if promptDraft.isEmpty {
                    Text(tr("Ask Terminal AI"))
                        .font(.system(size: 13))
                        .foregroundStyle(VisualStyle.textSecondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .allowsHitTesting(false)
                }

                TerminalAIComposerInputView(
                    text: $promptDraft,
                    isEnabled: true,
                    onSubmit: { submit(promptDraft) }
                )
                .frame(minHeight: 52, idealHeight: 62, maxHeight: 84)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(VisualStyle.inputFieldBackground)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(VisualStyle.borderSoft, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityIdentifier("terminal-ai-input")
            }

            HStack {
                Text(tr("Enter to send • Shift+Enter for newline"))
                    .font(.system(size: 11))
                    .foregroundStyle(VisualStyle.textSecondary)

                Spacer()

                Button(tr("Send")) {
                    submit(promptDraft)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(promptDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("terminal-ai-send")
            }
        }
        .padding(12)
    }

    private var bottomOverlay: some View {
        LinearGradient(
            colors: [
                VisualStyle.settingsSurfaceBackground.opacity(0),
                VisualStyle.settingsSurfaceBackground.opacity(0.92),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: 64)
        .allowsHitTesting(false)
    }

    private var shouldShowScrollToLatest: Bool {
        viewportBottomGlobal > 0 && bottomMarkerMaxY > viewportBottomGlobal + 20
    }

    private func updateScrollPosition() {
        isNearBottom = bottomMarkerMaxY <= viewportBottomGlobal + 20
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        let action = {
            proxy.scrollTo(bottomAnchorID, anchor: .bottom)
            isNearBottom = true
        }

        if animated {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                action()
            }
        } else {
            action()
        }
    }

    private func submit(_ prompt: String) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        Task {
            do {
                try await coordinator.submit(trimmed)
                await MainActor.run {
                    promptDraft = ""
                    submissionError = nil
                }
            } catch let error as TerminalAIAssistantCoordinatorError {
                await MainActor.run {
                    submissionError = errorMessage(for: error)
                }
            } catch {
                await MainActor.run {
                    submissionError = tr("Terminal AI request failed.")
                }
            }
        }
    }

    private func errorMessage(for error: TerminalAIAssistantCoordinatorError) -> String {
        switch error {
        case .sessionNotBound:
            return tr("Terminal AI is not attached to a session yet.")
        case .aiDisabled:
            return tr("Enable Terminal AI in Settings before sending requests.")
        case .emptyPrompt:
            return tr("Enter a prompt before sending it to Terminal AI.")
        case .missingAPIKey:
            return tr("Add an AI API key in Settings before using Terminal AI.")
        }
    }

    private func riskLabel(for risk: TerminalAICommandRisk) -> String {
        switch risk {
        case .safe:
            return tr("Safe")
        case .review:
            return tr("Review")
        case .danger:
            return tr("Danger")
        }
    }

    private func riskColor(for risk: TerminalAICommandRisk) -> Color {
        switch risk {
        case .safe:
            return .green
        case .review:
            return .orange
        case .danger:
            return .red
        }
    }

    private func tr(_ key: String) -> String {
        L10n.tr(key, fallback: key)
    }

    static func trStatic(_ key: String) -> String {
        L10n.tr(key, fallback: key)
    }
}

private struct TerminalAIBottomMarkerPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct TerminalAIThinkingHaloView: View {
    @State private var animate = false

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.accentColor.opacity(0.18))
                .scaleEffect(animate ? 1.8 : 0.9)
                .opacity(animate ? 0.08 : 0.24)

            Circle()
                .fill(Color.accentColor.opacity(0.3))
                .scaleEffect(animate ? 1.15 : 0.7)

            Circle()
                .fill(Color.accentColor)
                .frame(width: 6, height: 6)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.05).repeatForever(autoreverses: true)) {
                animate = true
            }
        }
    }
}

private struct TerminalAIThinkingDotsView: View {
    @State private var animate = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Color.accentColor.opacity(0.85))
                    .frame(width: 5, height: 5)
                    .offset(y: animate ? -2 : 2)
                    .animation(
                        .easeInOut(duration: 0.45)
                        .repeatForever(autoreverses: true)
                        .delay(Double(index) * 0.08),
                        value: animate
                    )
            }
        }
        .onAppear { animate = true }
    }
}

private struct TerminalAIQueuedPromptRow: View {
    let item: TerminalAIQueuedPrompt
    var onRemove: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.accentColor)

            Text(item.text)
                .font(.system(size: 12))
                .foregroundStyle(VisualStyle.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 6)

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(isHovered ? VisualStyle.textPrimary : VisualStyle.textSecondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(VisualStyle.settingsSubtleBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(isHovered ? Color.accentColor.opacity(0.35) : VisualStyle.borderSoft, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(isHovered ? 0.08 : 0), radius: 10, y: 4)
        .offset(y: isHovered ? -1 : 0)
        .animation(.easeInOut(duration: 0.14), value: isHovered)
        .onHover { isHovered = $0 }
    }
}

private struct TerminalAICommandCardView: View {
    let suggestion: TerminalAICommandSuggestion
    var onInsert: () -> Void
    var onRun: () -> Void
    var onCopy: () -> Void

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                Text(suggestion.command)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(VisualStyle.textPrimary)
                    .textSelection(.enabled)

                Spacer(minLength: 8)

                Text(riskLabel)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(riskColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(riskColor.opacity(0.14), in: Capsule())
            }

            Text(suggestion.purpose)
                .font(.system(size: 12))
                .foregroundStyle(VisualStyle.textSecondary)
                .textSelection(.enabled)

            HStack(spacing: 8) {
                Button(TerminalAIAssistantView.trStatic("Insert"), action: onInsert)
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                Button(TerminalAIAssistantView.trStatic("Run"), action: onRun)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                Button(TerminalAIAssistantView.trStatic("Copy"), action: onCopy)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(VisualStyle.settingsSubtleBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isHovered ? Color.accentColor.opacity(0.35) : VisualStyle.borderSoft, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(isHovered ? 0.08 : 0), radius: 12, y: 6)
        .offset(y: isHovered ? -1 : 0)
        .animation(.easeInOut(duration: 0.14), value: isHovered)
        .onHover { isHovered = $0 }
    }

    private var riskLabel: String {
        switch suggestion.risk {
        case .safe:
            return TerminalAIAssistantView.trStatic("Safe")
        case .review:
            return TerminalAIAssistantView.trStatic("Review")
        case .danger:
            return TerminalAIAssistantView.trStatic("Danger")
        }
    }

    private var riskColor: Color {
        switch suggestion.risk {
        case .safe:
            return .green
        case .review:
            return .orange
        case .danger:
            return .red
        }
    }
}
