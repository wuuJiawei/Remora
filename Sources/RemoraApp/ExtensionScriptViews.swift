import SwiftUI
import RemoraCore

struct ExtensionScriptManagementView: View {
    @ObservedObject var store: ExtensionScriptAppStore
    var hosts: [RemoraCore.Host] = []
    var selectedHost: RemoraCore.Host?
    var onRun: (ExtensionScript, RemoraCore.Host?) -> Void = { _, _ in }

    @State private var selectedScriptID: UUID?
    @State private var draft = ExtensionScriptDraft()
    @State private var validationMessage: String?
    @State private var insertionSequence = 0
    @State private var pendingInsertion: EditorTextInsertion?

    private var selectedScript: ExtensionScript? {
        guard let selectedScriptID else { return nil }
        return store.scripts.first(where: { $0.id == selectedScriptID })
    }

    var body: some View {
        HSplitView {
            scriptList
                .frame(minWidth: 170, idealWidth: 200, maxWidth: 240)

            editor
                .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            if selectedScriptID == nil {
                select(store.scripts.first)
            }
        }
        .onChange(of: store.scripts) {
            if let selectedScriptID, store.scripts.contains(where: { $0.id == selectedScriptID }) {
                return
            }
            select(store.scripts.first)
        }
    }

    private var scriptList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(tr("Extension Scripts"))
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button {
                    createScript()
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.borderless)
                .help(tr("New Script"))
            }

            if store.scripts.isEmpty {
                ContentUnavailableView(
                    tr("No scripts yet"),
                    systemImage: "scroll",
                    description: Text(tr("Create a script to run local automation from Remora."))
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selectedScriptID) {
                    ForEach(store.scripts) { script in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(script.name.isEmpty ? tr("Untitled Script") : script.name)
                                .font(.system(size: 12, weight: .semibold))
                                .lineLimit(1)
                            Text("\(languageTitle(script.language)) · \(scopeTitle(script.scope))")
                                .font(.system(size: 11))
                                .foregroundStyle(VisualStyle.textSecondary)
                                .lineLimit(1)
                        }
                        .tag(script.id)
                        .contextMenu {
                            Button(tr("Duplicate")) {
                                store.duplicate(script)
                            }
                            Button(tr("Delete"), role: .destructive) {
                                store.delete(id: script.id)
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                .onChange(of: selectedScriptID) {
                    select(selectedScript)
                }
            }

            if let errorMessage = store.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.orange)
                    .lineLimit(2)
            }
        }
        .padding(10)
        .background(VisualStyle.settingsSurfaceBackground)
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        TextField(tr("Script name"), text: $draft.name)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("extension-script-name")

                        Toggle(tr("Enabled"), isOn: $draft.isEnabled)
                            .toggleStyle(.checkbox)
                            .fixedSize()
                    }

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], alignment: .leading, spacing: 8) {
                        compactPicker(title: tr("Language")) {
                            Picker(tr("Language"), selection: $draft.language) {
                                ForEach(ExtensionScriptLanguage.allCases) { language in
                                    Text(languageTitle(language)).tag(language)
                                }
                            }
                            .labelsHidden()
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        compactPicker(title: tr("Scope")) {
                            Picker(tr("Scope"), selection: $draft.scopeSelection) {
                                Text(tr("Global")).tag(ExtensionScriptDraft.ScopeSelection.global)
                                ForEach(hosts) { host in
                                    Text(host.name).tag(ExtensionScriptDraft.ScopeSelection.host(host.id.uuidString))
                                }
                            }
                            .labelsHidden()
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        compactPicker(title: tr("Timeout")) {
                            Stepper(value: $draft.timeoutSeconds, in: ExtensionScript.minimumTimeoutSeconds...ExtensionScript.maximumTimeoutSeconds, step: 10) {
                                Text(String(format: tr("%d sec"), draft.timeoutSeconds))
                                    .font(.system(size: 12, design: .monospaced))
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    Toggle(tr("Confirm before running"), isOn: $draft.requireConfirmation)
                        .toggleStyle(.checkbox)

                    MirroredRemoraEditorView(
                        text: $draft.body,
                        documentID: editorDocumentID,
                        language: editorLanguage,
                        isEditable: true,
                        lineWrapping: false,
                        insertion: pendingInsertion
                    )
                    .frame(minHeight: 170)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(VisualStyle.elevatedSurfaceBackground)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(VisualStyle.borderSoft, lineWidth: 1)
                    )
                        .accessibilityIdentifier("extension-script-body")

                    builtinVariablesPanel

                    VStack(alignment: .leading, spacing: 4) {
                        Text(tr("Example"))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(VisualStyle.textSecondary)
                        ScrollView(.horizontal) {
                            Text(exampleText)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(VisualStyle.textSecondary)
                                .textSelection(.enabled)
                                .lineLimit(4)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(VisualStyle.settingsSubtleBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                    if let validationMessage {
                        Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.orange)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }

            HStack(spacing: 8) {
                Button(tr("Delete"), role: .destructive) {
                    if let selectedScriptID {
                        store.delete(id: selectedScriptID)
                    }
                }
                .disabled(selectedScriptID == nil)

                Button(tr("Duplicate")) {
                    if let selectedScript {
                        store.duplicate(selectedScript)
                    }
                }
                .disabled(selectedScript == nil)

                Spacer()

                Button(tr("Run")) {
                    guard let script = draft.makeScript(existing: selectedScript) else { return }
                    onRun(script, hostForScope(script.scope))
                }
                .disabled(!draft.isRunnable)

                Button(tr("Save")) {
                    saveDraft()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(VisualStyle.settingsPaneBackground)
    }

    private func compactPicker<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(VisualStyle.textSecondary)
            content()
        }
    }

    private var builtinVariablesPanel: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                Text(tr("Variables are injected as environment variables when a script runs from a host context. Passwords, tokens, and private key contents are not injected."))
                    .font(.system(size: 11))
                    .foregroundStyle(VisualStyle.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(scriptBuiltinVariables) { variable in
                        builtinVariableRow(variable)
                    }
                }
            }
            .padding(.top, 6)
        } label: {
            Label(tr("Built-in Variables"), systemImage: "curlybraces")
                .font(.system(size: 12, weight: .semibold))
        }
        .padding(8)
        .background(VisualStyle.settingsSubtleBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func builtinVariableRow(_ variable: ExtensionScriptBuiltinVariable) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(variable.name)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .textSelection(.enabled)
                Text(variable.description)
                    .font(.system(size: 11))
                    .foregroundStyle(VisualStyle.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            Button(tr("Insert")) {
                insertBuiltinVariable(variable)
            }
            .controlSize(.small)
        }
        .padding(8)
        .background(VisualStyle.inputFieldBackground, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(VisualStyle.borderSoft, lineWidth: 1)
        )
    }

    private func insertBuiltinVariable(_ variable: ExtensionScriptBuiltinVariable) {
        insertionSequence += 1
        pendingInsertion = EditorTextInsertion(
            id: insertionSequence,
            text: variable.referenceSnippet(for: draft.language)
        )
    }

    private func createScript() {
        let now = Date()
        let script = ExtensionScript(
            name: tr("New Script"),
            language: .shell,
            body: "#!/bin/zsh\nset -euo pipefail\n\necho \"Hello from Remora\"\n",
            scope: selectedHost.map { .host($0.id.uuidString) } ?? .global,
            timeoutSeconds: ExtensionScript.defaultTimeoutSeconds,
            createdAt: now,
            updatedAt: now
        )
        store.upsert(script)
        select(script)
    }

    private func select(_ script: ExtensionScript?) {
        selectedScriptID = script?.id
        draft = ExtensionScriptDraft(script: script, selectedHost: selectedHost)
        pendingInsertion = nil
        validationMessage = nil
    }

    private func saveDraft() {
        guard draft.isRunnable, var script = draft.makeScript(existing: selectedScript) else {
            validationMessage = tr("Script name and body are required.")
            return
        }
        script.timeoutSeconds = ExtensionScript.clampedTimeoutSeconds(script.timeoutSeconds)
        store.upsert(script)
        selectedScriptID = script.id
        validationMessage = nil
    }

    private func hostForScope(_ scope: ExtensionScriptScope) -> RemoraCore.Host? {
        switch scope {
        case .global:
            return selectedHost
        case .host(let hostID):
            return hosts.first(where: { $0.id.uuidString == hostID }) ?? selectedHost
        }
    }

    private var exampleText: String {
        switch draft.language {
        case .python:
            return """
            import os, subprocess
            host = os.environ["REMORA_HOST"]
            user = os.environ["REMORA_USER"]
            subprocess.run(["ssh", f"{user}@{host}", "cd ~/my-project && git pull --ff-only"], check=True)
            """
        case .shell:
            return """
            repo="$HOME/src/my-project"
            if [ -d "$repo/.git" ]; then git -C "$repo" pull --ff-only; else git clone git@github.com:me/my-project.git "$repo"; fi
            """
        case .javascript:
            return """
            const { spawnSync } = require("node:child_process");
            spawnSync("git", ["-C", process.env.HOME + "/src/my-project", "pull", "--ff-only"], { stdio: "inherit" });
            """
        case .swift:
            return """
            import Foundation
            print(ProcessInfo.processInfo.environment["REMORA_HOST"] ?? "local")
            """
        }
    }

    private var editorDocumentID: String {
        "extension-script-\(selectedScriptID?.uuidString ?? "new")-\(draft.language.rawValue)"
    }

    private var editorLanguage: EditorLanguage {
        switch draft.language {
        case .shell:
            return .shell
        case .python:
            return .python
        case .javascript:
            return .javascript
        case .swift:
            return .plain
        }
    }
}

struct ExtensionScriptRunSheet: View {
    @ObservedObject var viewModel: ExtensionScriptRunnerViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: statusIcon)
                    .foregroundStyle(statusColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(viewModel.script?.name ?? tr("Extension Script"))
                        .font(.system(size: 15, weight: .semibold))
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(VisualStyle.textSecondary)
                }
                Spacer()
                if viewModel.isRunning {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if viewModel.state == .awaitingConfirmation {
                Text(tr("This script runs locally on your Mac and can access files and network resources available to your user account. Only run scripts you trust."))
                    .font(.system(size: 12))
                    .foregroundStyle(VisualStyle.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let result = viewModel.result {
                resultSummary(result)
                outputSection(title: tr("stdout"), text: result.stdout)
                outputSection(title: tr("stderr"), text: result.stderr.isEmpty ? (result.errorMessage ?? "") : result.stderr)
            }

            HStack {
                Spacer()
                if viewModel.state == .awaitingConfirmation {
                    Button(tr("Cancel")) {
                        viewModel.dismiss()
                    }
                    Button(tr("Run")) {
                        viewModel.start()
                    }
                    .buttonStyle(.borderedProminent)
                } else if viewModel.isRunning {
                    Button(tr("Cancel")) {
                        viewModel.cancel()
                    }
                } else {
                    Button(tr("Close")) {
                        viewModel.dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(16)
        .frame(width: 720)
        .frame(minHeight: 360)
    }

    private var subtitle: String {
        if let host = viewModel.host {
            return String(format: tr("Host: %@"), host.name)
        }
        return tr("Global or local context")
    }

    private var statusIcon: String {
        guard let status = viewModel.result?.status else {
            return viewModel.isRunning ? "play.circle" : "exclamationmark.shield"
        }
        switch status {
        case .success:
            return "checkmark.circle.fill"
        case .failed, .interpreterMissing:
            return "xmark.circle.fill"
        case .timedOut:
            return "clock.badge.exclamationmark"
        case .cancelled:
            return "stop.circle.fill"
        }
    }

    private var statusColor: Color {
        guard let status = viewModel.result?.status else {
            return viewModel.isRunning ? Color.accentColor : Color.orange
        }
        switch status {
        case .success:
            return Color.green
        case .failed, .interpreterMissing, .timedOut:
            return Color.orange
        case .cancelled:
            return VisualStyle.textSecondary
        }
    }

    private func resultSummary(_ result: ExtensionScriptRunResult) -> some View {
        HStack(spacing: 12) {
            Text(statusTitle(result.status))
            Text("\(tr("Exit Code")): \(result.exitCode.map(String.init) ?? tr("N/A"))")
            Text(String(format: tr("Duration: %.2fs"), result.duration))
        }
        .font(.system(size: 12, design: .monospaced))
        .foregroundStyle(VisualStyle.textSecondary)
    }

    private func outputSection(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(VisualStyle.textSecondary)
            ScrollView {
                Text(text.isEmpty ? tr("No output") : text)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(text.isEmpty ? VisualStyle.textTertiary : VisualStyle.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(minHeight: 80, maxHeight: 150)
            .background(VisualStyle.inputFieldBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(VisualStyle.borderSoft, lineWidth: 1)
            )
        }
    }
}

private struct ExtensionScriptDraft: Equatable {
    enum ScopeSelection: Hashable {
        case global
        case host(String)
    }

    var name = ""
    var language = ExtensionScriptLanguage.shell
    var body = ""
    var scopeSelection = ScopeSelection.global
    var timeoutSeconds = ExtensionScript.defaultTimeoutSeconds
    var requireConfirmation = true
    var isEnabled = true

    init() {}

    init(script: ExtensionScript?, selectedHost: RemoraCore.Host?) {
        guard let script else {
            self.scopeSelection = selectedHost.map { .host($0.id.uuidString) } ?? .global
            return
        }
        name = script.name
        language = script.language
        body = script.body
        timeoutSeconds = script.timeoutSeconds
        requireConfirmation = script.requireConfirmation
        isEnabled = script.isEnabled
        switch script.scope {
        case .global:
            scopeSelection = .global
        case .host(let hostID):
            scopeSelection = .host(hostID)
        }
    }

    var isRunnable: Bool {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            && body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    func makeScript(existing: ExtensionScript?) -> ExtensionScript? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedBody.isEmpty else { return nil }

        return ExtensionScript(
            id: existing?.id ?? UUID(),
            name: trimmedName,
            language: language,
            body: trimmedBody,
            scope: scope,
            timeoutSeconds: timeoutSeconds,
            requireConfirmation: requireConfirmation,
            createdAt: existing?.createdAt ?? Date(),
            updatedAt: Date(),
            isEnabled: isEnabled
        )
    }

    private var scope: ExtensionScriptScope {
        switch scopeSelection {
        case .global:
            return .global
        case .host(let hostID):
            return .host(hostID)
        }
    }
}

private struct ExtensionScriptBuiltinVariable: Identifiable {
    let name: String
    let description: String

    var id: String { name }

    func referenceSnippet(for language: ExtensionScriptLanguage) -> String {
        switch language {
        case .shell:
            return "$\(name)"
        case .python:
            return "os.environ.get(\"\(name)\", \"\")"
        case .javascript:
            return "process.env.\(name) ?? \"\""
        case .swift:
            return "ProcessInfo.processInfo.environment[\"\(name)\"] ?? \"\""
        }
    }
}

private let scriptBuiltinVariables: [ExtensionScriptBuiltinVariable] = [
    .init(name: "REMORA_HOST_ID", description: tr("Stable host identifier.")),
    .init(name: "REMORA_HOST_NAME", description: tr("Host display name in Remora.")),
    .init(name: "REMORA_HOST", description: tr("SSH host name or IP address.")),
    .init(name: "REMORA_PORT", description: tr("SSH port, usually 22.")),
    .init(name: "REMORA_USER", description: tr("SSH username.")),
    .init(name: "REMORA_AUTH_METHOD", description: tr("Authentication method, such as password, key, or agent.")),
    .init(name: "REMORA_KEY_PATH", description: tr("Private key file path when key authentication is configured.")),
    .init(name: "REMORA_LOCAL_DOWNLOAD_DIR", description: tr("Local download directory configured in Remora.")),
    .init(name: "REMORA_CONTEXT_JSON", description: tr("Path to a temporary JSON file with the full safe run context."))
]

func languageTitle(_ language: ExtensionScriptLanguage) -> String {
    switch language {
    case .shell:
        return tr("Shell")
    case .python:
        return "Python"
    case .javascript:
        return "JavaScript"
    case .swift:
        return "Swift"
    }
}

func scopeTitle(_ scope: ExtensionScriptScope) -> String {
    switch scope {
    case .global:
        return tr("Global")
    case .host:
        return tr("Host")
    }
}

func statusTitle(_ status: ExtensionScriptRunStatus) -> String {
    switch status {
    case .success:
        return tr("Success")
    case .failed:
        return tr("Failed")
    case .timedOut:
        return tr("Timed Out")
    case .cancelled:
        return tr("Cancelled")
    case .interpreterMissing:
        return tr("Interpreter Missing")
    }
}
