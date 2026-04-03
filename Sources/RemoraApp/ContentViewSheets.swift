import AppKit
import Foundation
import SwiftUI
import RemoraCore

struct HostImportSourceSheet: View {
    let onCancel: () -> Void
    let onSelect: (HostConnectionImportSource) -> Void
    @State private var selectedSource = HostConnectionImportSource.supportedCases.first ?? .remoraJSONCSV

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(tr("Choose Import Source"))
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(VisualStyle.textPrimary)

                Text(tr("Choose a source from the list, then import a file in that format."))
                    .font(.subheadline)
                    .foregroundStyle(VisualStyle.textSecondary)
            }
            .padding(20)

            Divider()

            HStack(alignment: .top, spacing: 18) {
                HostImportSourcePicker(selectedSource: $selectedSource)
                    .frame(width: 250)
                    .frame(maxHeight: .infinity, alignment: .top)

                HostImportSourceDetailPane(source: selectedSource)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            Divider()

            HStack {
                Spacer()

                Button(tr("Cancel"), action: onCancel)
                    .buttonStyle(.bordered)

                Button(tr("Choose File")) {
                    onSelect(selectedSource)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(20)
        }
        .frame(width: 760, height: 560)
    }
}

struct HostImportSourcePicker: View {
    @Binding var selectedSource: HostConnectionImportSource

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HostImportSourcePickerSection(title: tr("Supported Now")) {
                    ForEach(HostConnectionImportSource.supportedCases) { source in
                        HostImportSourcePickerRow(
                            source: source,
                            isSelected: selectedSource == source,
                            onSelect: { selectedSource = source }
                        )
                    }
                }

                HostImportSourcePickerSection(title: tr("Coming Soon")) {
                    ForEach(HostConnectionImportSource.upcomingCases) { source in
                        HostImportSourceUpcomingRow(source: source)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glassCard(
            radius: 14,
            fill: VisualStyle.inputFieldBackground,
            border: VisualStyle.borderSoft,
            showsShadow: false
        )
    }
}

struct HostImportSourcePickerSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(VisualStyle.textSecondary)
                .padding(.horizontal, 6)

            VStack(spacing: 4) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct HostImportSourcePickerRow: View {
    let source: HostConnectionImportSource
    let isSelected: Bool
    let onSelect: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                HostImportSourceListIcon(
                    source: source,
                    tint: isSelected ? Color.accentColor : VisualStyle.textSecondary
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text(source.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(VisualStyle.textPrimary)

                    Text(source.isSupported ? tr("Ready to import") : tr("Coming Soon"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(VisualStyle.textSecondary)
                }

                Spacer(minLength: 8)

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(rowBackground)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovering = hovering
            }
        }
    }

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(isSelected ? VisualStyle.leftSelectedBackground : (isHovering ? VisualStyle.leftHoverBackground : Color.clear))
    }
}

struct HostImportSourceUpcomingRow: View {
    let source: HostConnectionImportSource

    var body: some View {
        HStack(spacing: 10) {
            HostImportSourceListIcon(
                source: source,
                tint: VisualStyle.textTertiary
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(source.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(VisualStyle.textSecondary)

                Text(tr("Coming Soon"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(VisualStyle.textTertiary)
            }

            Spacer(minLength: 8)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(VisualStyle.mutedSurfaceBackground.opacity(0.55))
        )
        .contentShape(Rectangle())
    }
}

struct HostImportSourceDetailPane: View {
    let source: HostConnectionImportSource

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .center, spacing: 14) {
                    HostImportSourceDetailIcon(source: source)

                    VStack(alignment: .leading, spacing: 5) {
                        Text(source.title)
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(VisualStyle.textPrimary)

                        Text(tr("Ready to import"))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                }

                Text(source.detail)
                    .font(.system(size: 14))
                    .foregroundStyle(VisualStyle.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                HostImportSourceFactCard(
                    title: tr("Supported Formats"),
                    value: source.importFormatsSummary
                )

                Text(tr("Select the export or config file for this source to begin importing."))
                    .font(.system(size: 13))
                    .foregroundStyle(VisualStyle.textSecondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(VisualStyle.mutedSurfaceBackground)
                    )
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glassCard(
            radius: 14,
            fill: VisualStyle.inputFieldBackground,
            border: VisualStyle.borderSoft,
            showsShadow: false
        )
    }
}

struct HostImportSourceFactCard: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(VisualStyle.textSecondary)

            Text(value)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(VisualStyle.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(VisualStyle.mutedSurfaceBackground)
        )
    }
}

struct HostImportSourceListIcon: View {
    let source: HostConnectionImportSource
    let tint: Color

    var body: some View {
        Image(systemName: source.importSymbolName)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 18)
    }
}

struct HostImportSourceDetailIcon: View {
    let source: HostConnectionImportSource

    var body: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(VisualStyle.leftHoverBackground)
            .frame(width: 72, height: 72)
            .overlay {
                if source == .remoraJSONCSV, let appIconImage = ContentView.resolveWelcomeAppIconImage() {
                    Image(nsImage: appIconImage)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 56, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                } else {
                    Image(systemName: source.importSymbolName)
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
    }
}

private extension HostConnectionImportSource {
    var importSymbolName: String {
        switch self {
        case .remoraJSONCSV:
            return "fish"
        case .openSSH:
            return "terminal"
        case .windTerm:
            return "wind"
        case .electerm:
            return "bolt.horizontal.circle"
        case .xshell:
            return "shippingbox"
        case .puTTYRegistry:
            return "externaldrive.badge.timemachine"
        case .shellSessions:
            return "apple.terminal"
        case .finalShell:
            return "server.rack"
        case .termius:
            return "rectangle.3.group.bubble.left"
        }
    }

    var importFormatsSummary: String {
        switch self {
        case .remoraJSONCSV:
            return "JSON, CSV"
        case .openSSH:
            return "config, ssh_config"
        case .windTerm:
            return "JSON"
        case .electerm:
            return "JSON"
        case .xshell:
            return ".xsh, .xts, .zip"
        case .puTTYRegistry:
            return ".reg, .txt"
        case .shellSessions:
            return "Shell session data"
        case .finalShell:
            return "FinalShell export"
        case .termius:
            return "Termius export"
        }
    }
}

struct HostExportSheet: View {
    @Binding var draft: HostExportDraft
    let isExporting: Bool
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tr("Export SSH Connections"))
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(VisualStyle.textPrimary)

            Text(draft.scope.label)
                .font(.system(size: 12))
                .foregroundStyle(VisualStyle.textSecondary)

            Picker(tr("Format"), selection: $draft.format) {
                ForEach(HostExportFormat.allCases) { format in
                    Text(format == .json ? tr("Export as JSON") : tr("Export as CSV"))
                        .tag(format)
                }
            }
            .pickerStyle(.segmented)

            Toggle(tr("Include saved passwords (plaintext)"), isOn: $draft.includeSavedPasswords)
                .toggleStyle(.checkbox)

            if draft.includeSavedPasswords {
                Text(tr("Saved passwords will be written to the export file in plaintext. Only continue if you understand the risk and control where the file will be stored."))
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
            }

            HStack {
                Spacer()
                Button(tr("Cancel"), action: onCancel)
                Button(tr("Export"), action: onConfirm)
                    .buttonStyle(.borderedProminent)
                    .disabled(isExporting)
            }
        }
        .padding(16)
        .frame(width: 420)
    }
}

enum SidebarGroupEditorMode {
    case create
    case edit

    var title: String {
        switch self {
        case .create:
            return tr("New Thread Group")
        case .edit:
            return tr("Edit Thread Group")
        }
    }

    var confirmTitle: String {
        switch self {
        case .create:
            return tr("Create")
        case .edit:
            return tr("Save")
        }
    }
}

enum SidebarHostEditorMode {
    case create
    case edit(UUID)

    var title: String {
        switch self {
        case .create:
            return tr("New SSH Connection")
        case .edit:
            return tr("Edit SSH Connection")
        }
    }

    var confirmTitle: String {
        switch self {
        case .create:
            return tr("Create")
        case .edit:
            return tr("Save")
        }
    }
}

enum SidebarHostAuthMethod: String, CaseIterable, Identifiable {
    case agent = "SSH Agent"
    case privateKey = "Private Key"
    case password = "Password"

    var id: String { rawValue }
}

struct SidebarHostEditorDraft {
    var connectionName: String
    var hostAddress: String
    var portText: String
    var usernameText: String
    var groupText: String
    var authMethod: SidebarHostAuthMethod
    var privateKeyPath: String
    var password: String
    var savePassword: Bool

    init(preferredGroup: String = "") {
        self.connectionName = ""
        self.hostAddress = "127.0.0.1"
        self.portText = "22"
        self.usernameText = "root"
        self.groupText = preferredGroup
        self.authMethod = .password
        self.privateKeyPath = ""
        self.password = ""
        self.savePassword = false
    }

    init(host: RemoraCore.Host) {
        self.connectionName = host.name
        self.hostAddress = host.address
        self.portText = "\(host.port)"
        self.usernameText = host.username
        self.groupText = host.group == HostCatalogStore.ungroupedGroupIdentifier ? "" : host.group
        self.privateKeyPath = host.auth.keyReference ?? ""
        self.password = ""
        self.savePassword = host.auth.passwordReference != nil

        switch host.auth.method {
        case .agent:
            self.authMethod = .agent
        case .privateKey:
            self.authMethod = .privateKey
        case .password:
            self.authMethod = .password
        }
    }

    var name: String {
        let trimmedName = connectionName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedName.isEmpty {
            return trimmedName
        }
        let trimmedAddress = hostAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedAddress.isEmpty ? "new-ssh" : trimmedAddress
    }

    var address: String {
        hostAddress.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var username: String {
        let trimmed = usernameText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "root" : trimmed
    }

    var groupName: String {
        let trimmed = groupText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? HostCatalogStore.ungroupedGroupIdentifier : trimmed
    }

    var port: Int? {
        guard let port = Int(portText.trimmingCharacters(in: .whitespacesAndNewlines)),
              (1...65_535).contains(port)
        else {
            return nil
        }
        return port
    }

    var canSave: Bool {
        !address.isEmpty && port != nil
    }

    var canTestConnection: Bool {
        !address.isEmpty && port != nil
    }
}

enum HostConnectionTestState: Equatable {
    case idle
    case testing
    case success(String)
    case failure(String)

    var isTesting: Bool {
        if case .testing = self { return true }
        return false
    }

    var message: String? {
        switch self {
        case .idle, .testing:
            return nil
        case .success(let message), .failure(let message):
            return message
        }
    }

    var symbolName: String {
        switch self {
        case .idle:
            return ""
        case .testing:
            return "hourglass"
        case .success:
            return "checkmark.circle.fill"
        case .failure:
            return "xmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .idle:
            return VisualStyle.textTertiary
        case .testing:
            return VisualStyle.textSecondary
        case .success:
            return .green
        case .failure:
            return .red
        }
    }
}

enum HostConnectionTester {
    static func testTCPReachability(host: String, port: Int, timeout: Int) async -> HostConnectionTestState {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
                process.arguments = ["-z", "-G", "\(max(1, timeout))", host, "\(port)"]

                let errorPipe = Pipe()
                process.standardOutput = Pipe()
                process.standardError = errorPipe

                do {
                    try process.run()
                    process.waitUntilExit()
                    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    let errorText = String(data: errorData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                    if process.terminationStatus == 0 {
                        continuation.resume(returning: .success("\(tr("Connection test passed")) (\(host):\(port))."))
                    } else if !errorText.isEmpty {
                        continuation.resume(returning: .failure(errorText))
                    } else {
                        continuation.resume(returning: .failure("\(tr("Cannot reach")) \(host):\(port)."))
                    }
                } catch {
                    continuation.resume(returning: .failure("\(tr("Connection test failed")): \(error.localizedDescription)"))
                }
            }
        }
    }
}

struct SidebarGroupEditorSheet: View {
    let mode: SidebarGroupEditorMode
    @Binding var value: String
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(mode.title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(VisualStyle.textPrimary)

            TextField(tr("Group name"), text: $value)
                .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button(tr("Cancel"), action: onCancel)
                Button(mode.confirmTitle, action: onConfirm)
                    .buttonStyle(.borderedProminent)
                    .disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 360)
    }
}

struct SidebarGroupDeletionSheet: View {
    let groupName: String
    let hostCount: Int
    @Binding var deleteHosts: Bool
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(tr("Delete group"))
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(VisualStyle.textPrimary)

            Text(
                String(
                    format: tr("Delete the group \"%@\"?"),
                    groupName
                )
            )
            .font(.system(size: 13))
            .foregroundStyle(VisualStyle.textSecondary)

            if hostCount > 0 {
                Toggle(
                    String(
                        format: tr("Also delete %d SSH connection(s) in this group"),
                        hostCount
                    ),
                    isOn: $deleteHosts
                )
                .toggleStyle(.checkbox)

                Text(
                    deleteHosts
                    ? tr("If enabled, every SSH connection in this group will be deleted permanently.")
                    : tr("If disabled, SSH connections in this group will be moved to Ungrouped.")
                )
                .font(.system(size: 12))
                .foregroundStyle(VisualStyle.textSecondary)
            }

            HStack {
                Spacer()
                Button(tr("Cancel"), action: onCancel)
                Button(tr("Delete"), role: .destructive, action: onConfirm)
            }
        }
        .padding(16)
        .frame(width: 420)
    }
}

struct SidebarHostEditorSheet: View {
    let mode: SidebarHostEditorMode
    @Binding var draft: SidebarHostEditorDraft
    let testState: HostConnectionTestState
    let onCancel: () -> Void
    let onTestConnection: () -> Void
    let onConfirm: () -> Void
    @State private var isPasswordVisible = false

    init(
        mode: SidebarHostEditorMode,
        draft: Binding<SidebarHostEditorDraft>,
        testState: HostConnectionTestState,
        onCancel: @escaping () -> Void,
        onTestConnection: @escaping () -> Void,
        onConfirm: @escaping () -> Void
    ) {
        self.mode = mode
        self._draft = draft
        self.testState = testState
        self.onCancel = onCancel
        self.onTestConnection = onTestConnection
        self.onConfirm = onConfirm
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(mode.title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(VisualStyle.textPrimary)
                .accessibilityIdentifier("host-editor-title")

            Group {
                TextField(tr("Connection name"), text: $draft.connectionName)
                TextField(tr("Host"), text: $draft.hostAddress)

                HStack(spacing: 10) {
                    TextField(tr("Port"), text: $draft.portText)
                        .frame(width: 90)
                    TextField(tr("Username"), text: $draft.usernameText)
                }

                TextField(tr("Group"), text: $draft.groupText)

                Picker(tr("Auth"), selection: $draft.authMethod) {
                    ForEach(SidebarHostAuthMethod.allCases) { method in
                        Text(method.rawValue).tag(method)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("host-editor-auth")

                if draft.authMethod == .privateKey {
                    HStack(spacing: 8) {
                        TextField(tr("Private key path"), text: $draft.privateKeyPath)
                            .accessibilityIdentifier("host-editor-private-key-path")

                        Button(tr("Choose…")) {
                            choosePrivateKeyPath()
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("host-editor-private-key-choose")
                    }
                }

                if draft.authMethod == .password {
                    HStack(spacing: 8) {
                        Group {
                            if isPasswordVisible {
                                TextField(tr("Password"), text: $draft.password)
                            } else {
                                SecureField(tr("Password"), text: $draft.password)
                            }
                        }

                        Button {
                            isPasswordVisible.toggle()
                        } label: {
                            Image(systemName: isPasswordVisible ? "eye.slash" : "eye")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(VisualStyle.textSecondary)
                                .frame(width: 18, height: 18)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(isPasswordVisible ? tr("Hide password") : tr("Show password"))
                        .help(isPasswordVisible ? tr("Hide password") : tr("Show password"))
                    }
                    Toggle(
                        tr("Save password in ~/.config/remora"),
                        isOn: $draft.savePassword
                    )
                    .toggleStyle(.checkbox)
                    .accessibilityIdentifier("host-editor-save-password")
                }
            }
            .textFieldStyle(.roundedBorder)

            HStack(spacing: 8) {
                Button(tr("Test Connection"), action: onTestConnection)
                    .disabled(!draft.canTestConnection || testState.isTesting)

                if testState.isTesting {
                    ProgressView()
                        .controlSize(.small)
                }

                if let message = testState.message {
                    Label(message, systemImage: testState.symbolName)
                        .font(.system(size: 12))
                        .foregroundStyle(testState.color)
                }
            }

            HStack {
                Spacer()
                Button(tr("Cancel"), action: onCancel)
                Button(mode.confirmTitle, action: onConfirm)
                    .buttonStyle(.borderedProminent)
                    .disabled(!draft.canSave)
            }
        }
        .padding(16)
        .frame(width: 420)
        .onChange(of: draft.authMethod) {
            if draft.authMethod != .password {
                isPasswordVisible = false
            }
        }
    }

    private func choosePrivateKeyPath() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = tr("Choose…")

        let trimmedPath = draft.privateKeyPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let fileManager = FileManager.default

        if !trimmedPath.isEmpty {
            let expandedURL = URL(fileURLWithPath: (trimmedPath as NSString).expandingTildeInPath)
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: expandedURL.path, isDirectory: &isDirectory) {
                if isDirectory.boolValue {
                    panel.directoryURL = expandedURL.standardizedFileURL
                } else {
                    panel.directoryURL = expandedURL.deletingLastPathComponent().standardizedFileURL
                    panel.nameFieldStringValue = expandedURL.lastPathComponent
                }
            } else {
                let parentURL = expandedURL.deletingLastPathComponent().standardizedFileURL
                if fileManager.fileExists(atPath: parentURL.path, isDirectory: &isDirectory),
                   isDirectory.boolValue
                {
                    panel.directoryURL = parentURL
                }
            }
        }

        if panel.directoryURL == nil {
            let defaultSSHDirectory = fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent(".ssh", isDirectory: true)
                .standardizedFileURL
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: defaultSSHDirectory.path, isDirectory: &isDirectory),
               isDirectory.boolValue
            {
                panel.directoryURL = defaultSSHDirectory
            }
        }

        guard panel.runModal() == .OK, let selectedURL = panel.url else {
            return
        }

        draft.privateKeyPath = selectedURL.standardizedFileURL.path
    }
}

struct SidebarRenameSheet: View {
    let title: String
    let fieldTitle: String
    let hintText: String
    @Binding var value: String
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(VisualStyle.textPrimary)

            TextField(fieldTitle, text: $value)
                .textFieldStyle(.roundedBorder)

            Label(hintText, systemImage: "info.circle")
                .font(.system(size: 12))
                .foregroundStyle(VisualStyle.textSecondary)
                .labelStyle(.titleAndIcon)

            HStack {
                Spacer()
                Button(tr("Cancel")) {
                    onCancel()
                }
                Button(tr("Save")) {
                    onConfirm()
                }
                .buttonStyle(.borderedProminent)
                .disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 360)
    }
}

struct SessionRenameMenuLabel: View {
    let title: String
    let hint: String

    var body: some View {
        HStack(spacing: 8) {
            Text(title)

            Spacer(minLength: 12)

            Image(systemName: "info.circle")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(VisualStyle.textTertiary)
                .help(hint)
                .accessibilityLabel(hint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct HostQuickCommandEditorSheet: View {
    let host: RemoraCore.Host
    let commands: [HostQuickCommand]
    let editingCommandID: UUID?
    @Binding var nameDraft: String
    @Binding var commandDraft: String
    let validationMessage: String?
    let onClose: () -> Void
    let onSave: () -> Void
    let onStartEdit: (HostQuickCommand) -> Void
    let onDelete: (UUID) -> Void
    let onCancelEdit: () -> Void

    private var isEditing: Bool {
        editingCommandID != nil
    }

    private var canSaveDraft: Bool {
        !commandDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(tr("Quick commands")) · \(host.name)")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(VisualStyle.textPrimary)

            Group {
                if commands.isEmpty {
                    Text(tr("No quick commands yet."))
                        .font(.system(size: 12))
                        .foregroundStyle(VisualStyle.textTertiary)
                        .frame(maxWidth: .infinity, minHeight: 96, alignment: .center)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(VisualStyle.mutedSurfaceBackground)
                        )
                } else {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(commands) { command in
                                HStack(spacing: 8) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(command.name)
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundStyle(VisualStyle.textPrimary)
                                            .lineLimit(1)
                                        Text(command.command)
                                            .font(.system(size: 12, design: .monospaced))
                                            .foregroundStyle(VisualStyle.textSecondary)
                                            .lineLimit(1)
                                    }

                                    Spacer(minLength: 8)

                                    Button(tr("Edit")) {
                                        onStartEdit(command)
                                    }
                                    .buttonStyle(.borderless)

                                    Button(tr("Delete"), role: .destructive) {
                                        onDelete(command.id)
                                    }
                                    .buttonStyle(.borderless)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(VisualStyle.elevatedSurfaceBackground)
                                )
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .frame(minHeight: 96, maxHeight: 220)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(isEditing ? tr("Edit command") : tr("New command"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(VisualStyle.textSecondary)

                TextField(tr("Name"), text: $nameDraft)
                    .textFieldStyle(.roundedBorder)

                TextField(tr("Command"), text: $commandDraft)
                    .font(.system(size: 12, design: .monospaced))
                    .textFieldStyle(.roundedBorder)

                if let validationMessage {
                    Text(validationMessage)
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                }
            }

            HStack {
                if isEditing {
                    Button(tr("Cancel edit")) {
                        onCancelEdit()
                    }
                }
                Spacer()
                Button(tr("Close")) {
                    onClose()
                }
                Button(isEditing ? tr("Save") : tr("Add")) {
                    onSave()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSaveDraft)
            }
        }
        .padding(16)
        .frame(width: 560)
    }
}

struct HostQuickPathEditorSheet: View {
    let host: RemoraCore.Host
    let quickPaths: [HostQuickPath]
    let editingPathID: UUID?
    @Binding var nameDraft: String
    @Binding var pathDraft: String
    let validationMessage: String?
    let onClose: () -> Void
    let onSave: () -> Void
    let onStartEdit: (HostQuickPath) -> Void
    let onDelete: (UUID) -> Void
    let onCancelEdit: () -> Void

    private var isEditing: Bool {
        editingPathID != nil
    }

    private var canSaveDraft: Bool {
        !pathDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(tr("Quick paths")) · \(host.name)")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(VisualStyle.textPrimary)

            Group {
                if quickPaths.isEmpty {
                    Text(tr("No quick paths yet."))
                        .font(.system(size: 12))
                        .foregroundStyle(VisualStyle.textTertiary)
                        .frame(maxWidth: .infinity, minHeight: 96, alignment: .center)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(VisualStyle.mutedSurfaceBackground)
                        )
                } else {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(quickPaths) { quickPath in
                                HStack(spacing: 8) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(quickPath.name)
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundStyle(VisualStyle.textPrimary)
                                            .lineLimit(1)
                                        Text(quickPath.path)
                                            .font(.system(size: 12, design: .monospaced))
                                            .foregroundStyle(VisualStyle.textSecondary)
                                            .lineLimit(1)
                                    }

                                    Spacer(minLength: 8)

                                    Button(tr("Edit")) {
                                        onStartEdit(quickPath)
                                    }
                                    .buttonStyle(.borderless)

                                    Button(tr("Delete"), role: .destructive) {
                                        onDelete(quickPath.id)
                                    }
                                    .buttonStyle(.borderless)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(VisualStyle.elevatedSurfaceBackground)
                                )
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .frame(minHeight: 96, maxHeight: 220)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(isEditing ? tr("Edit path") : tr("New path"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(VisualStyle.textSecondary)

                TextField(tr("Name"), text: $nameDraft)
                    .textFieldStyle(.roundedBorder)

                TextField("/path/to/dir", text: $pathDraft)
                    .font(.system(size: 12, design: .monospaced))
                    .textFieldStyle(.roundedBorder)

                if let validationMessage {
                    Text(validationMessage)
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                }
            }

            HStack {
                if isEditing {
                    Button(tr("Cancel edit")) {
                        onCancelEdit()
                    }
                }
                Spacer()
                Button(tr("Close")) {
                    onClose()
                }
                Button(isEditing ? tr("Save") : tr("Add")) {
                    onSave()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSaveDraft)
            }
        }
        .padding(16)
        .frame(width: 560)
    }
}
