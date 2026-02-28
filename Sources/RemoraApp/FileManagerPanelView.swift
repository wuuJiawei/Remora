import AppKit
import SwiftUI
import RemoraCore

struct FileManagerPanelView: View {
    @ObservedObject var viewModel: FileTransferViewModel

    @AppStorage("file-manager-path-width") private var remotePathFieldWidth: Double = 420
    @State private var selectedRemotePaths: Set<String> = []
    @State private var hoveredRemotePath: String?
    @State private var hoveredTransferID: UUID?
    @State private var remotePathDraft = "/"
    @State private var pathWidthDragStart: Double?
    @State private var lastTappedRemotePath: String?
    @State private var lastRemoteTapAt = Date.distantPast
    @State private var isMoveSheetPresented = false
    @State private var moveTargetPath = "/"
    @State private var moveSourcePaths: [String] = []
    @State private var isRenameSheetPresented = false
    @State private var renameTargetPath: String?
    @State private var renameDraft = ""
    @State private var editorTargetPath: String?
    @State private var propertiesTargetPath: String?
    @State private var isUploadPanelPresented = false
    @State private var uploadTargetDirectory = "/"

    private var selectedRemoteEntries: [RemoteFileEntry] {
        viewModel.remoteEntries.filter { selectedRemotePaths.contains($0.path) }
    }

    private var selectedRemoteFiles: [RemoteFileEntry] {
        selectedRemoteEntries.filter { !$0.isDirectory }
    }

    private var hasRetryableTransfers: Bool {
        viewModel.transferQueue.contains { $0.status == .failed || $0.status == .skipped }
    }

    private var currentDestinationDirectoryForPaste: String {
        viewModel.remoteDirectoryPath
    }

    private var clampedPathFieldWidth: CGFloat {
        CGFloat(min(max(remotePathFieldWidth, 180), 1200))
    }

    var body: some View {
        VStack(spacing: 8) {
            remotePanel
                .frame(minHeight: 150, maxHeight: 220, alignment: .top)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Button {
                        viewModel.performContextAction(.download(paths: Array(selectedRemotePaths)))
                    } label: {
                        Label("Download", systemImage: "arrow.down.circle.fill")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(selectedRemoteFiles.isEmpty)
                    .accessibilityIdentifier("file-manager-download")

                    Button(role: .destructive) {
                        viewModel.performContextAction(.delete(paths: Array(selectedRemotePaths)))
                        selectedRemotePaths.removeAll()
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(selectedRemotePaths.isEmpty)
                    .accessibilityIdentifier("file-manager-delete")

                    Button {
                        moveSourcePaths = Array(selectedRemotePaths)
                        moveTargetPath = viewModel.remoteDirectoryPath
                        isMoveSheetPresented = true
                    } label: {
                        Label("Move To", systemImage: "folder")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(selectedRemotePaths.isEmpty)
                    .accessibilityIdentifier("file-manager-move")

                    Button("Retry Failed") {
                        viewModel.retryFailedTransfers()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!hasRetryableTransfers)
                    .accessibilityIdentifier("file-manager-retry-failed")

                    Button("Paste") {
                        viewModel.performContextAction(.paste(destinationDirectory: currentDestinationDirectoryForPaste))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!viewModel.canPaste(into: currentDestinationDirectoryForPaste))
                    .accessibilityIdentifier("file-manager-paste")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            transferQueuePanel
        }
        .animation(.easeInOut(duration: 0.2), value: viewModel.transferQueue.map(\.status))
        .onAppear {
            remotePathDraft = viewModel.remoteDirectoryPath
        }
        .onChange(of: viewModel.remoteDirectoryPath) {
            remotePathDraft = viewModel.remoteDirectoryPath
            selectedRemotePaths.removeAll()
        }
        .sheet(isPresented: $isMoveSheetPresented) {
            moveSheet
        }
        .sheet(isPresented: $isRenameSheetPresented) {
            renameSheet
        }
        .sheet(
            isPresented: Binding(
                get: { editorTargetPath != nil },
                set: { isPresented in
                    if !isPresented {
                        editorTargetPath = nil
                    }
                }
            )
        ) {
            if let editorTargetPath {
                RemoteTextEditorSheet(path: editorTargetPath, fileTransfer: viewModel)
            }
        }
        .sheet(
            isPresented: Binding(
                get: { propertiesTargetPath != nil },
                set: { isPresented in
                    if !isPresented {
                        propertiesTargetPath = nil
                    }
                }
            )
        ) {
            if let propertiesTargetPath {
                RemoteFilePropertiesSheet(path: propertiesTargetPath, fileTransfer: viewModel)
            }
        }
    }

    private var remotePanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            remoteToolbar

            ScrollViewReader { proxy in
                List {
                    ForEach(viewModel.remoteEntries, id: \.path) { entry in
                        let isSelected = selectedRemotePaths.contains(entry.path)
                        HStack {
                            Image(systemName: entry.isDirectory ? "folder" : "doc")
                            Text(entry.name)
                                .lineLimit(1)
                                .foregroundStyle(VisualStyle.textPrimary)
                            Spacer()
                            if !entry.isDirectory {
                                Text("\(entry.size)")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(VisualStyle.textSecondary)
                            }
                        }
                        .padding(.vertical, 3)
                        .padding(.horizontal, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(
                                    isSelected
                                        ? VisualStyle.leftSelectedBackground
                                        : (hoveredRemotePath == entry.path ? VisualStyle.leftHoverBackground : Color.clear)
                                )
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(isSelected ? VisualStyle.borderStrong : Color.clear, lineWidth: 1)
                        )
                        .contentShape(Rectangle())
                        .listRowBackground(Color.clear)
                        .tag(entry.path)
                        .accessibilityIdentifier(remoteRowIdentifier(entry.path))
                        .onTapGesture {
                            handleRemoteRowTap(entry)
                        }
                        .onHover { hovering in
                            hoveredRemotePath = hovering ? entry.path : nil
                        }
                        .dropDestination(for: URL.self) { items, _ in
                            guard entry.isDirectory, !items.isEmpty else { return false }
                            viewModel.enqueueUpload(localFileURLs: items, toRemoteDirectory: entry.path)
                            return true
                        }
                        .contextMenu {
                            rowContextMenu(for: entry)
                        }
                    }
                }
                .onChange(of: viewModel.remoteDirectoryPath) {
                    guard let firstPath = viewModel.remoteEntries.first?.path else {
                        return
                    }
                    DispatchQueue.main.async {
                        proxy.scrollTo(firstPath, anchor: .top)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .scrollContentBackground(.hidden)
                .background(VisualStyle.rightPanelBackground)
                .listStyle(.plain)
                .accessibilityIdentifier("file-manager-remote-list")
                .dropDestination(for: URL.self) { items, _ in
                    guard !items.isEmpty else { return false }
                    viewModel.enqueueUpload(localFileURLs: items, toRemoteDirectory: viewModel.remoteDirectoryPath)
                    return true
                }
                .contextMenu {
                    panelContextMenu
                }
                .overlay(alignment: .center) {
                    if viewModel.isRemoteLoading {
                        VStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Loading directory...")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.black.opacity(0.04))
                        )
                        .padding(16)
                        .accessibilityIdentifier("file-manager-remote-loading")
                    } else if viewModel.remoteEntries.isEmpty,
                              let message = viewModel.remoteLoadErrorMessage,
                              !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    {
                        VStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                            Text("Failed to load remote directory")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(message)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .lineLimit(4)
                        }
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.black.opacity(0.04))
                        )
                        .padding(16)
                        .accessibilityIdentifier("file-manager-remote-error")
                    }
                }
            }
        }
    }

    private var remoteToolbar: some View {
        HStack(spacing: 8) {
            toolbarIconButton(
                "chevron.backward",
                accessibilityIdentifier: "file-manager-back",
                helpText: "Back",
                disabled: !viewModel.canNavigateRemoteBack
            ) {
                viewModel.navigateRemoteBack()
            }

            toolbarIconButton(
                "chevron.forward",
                accessibilityIdentifier: "file-manager-forward",
                helpText: "Forward",
                disabled: !viewModel.canNavigateRemoteForward
            ) {
                viewModel.navigateRemoteForward()
            }

            toolbarIconButton(
                "house",
                accessibilityIdentifier: "file-manager-root",
                helpText: "Go to Root",
                disabled: viewModel.remoteDirectoryPath == "/"
            ) {
                navigateToRoot()
            }

            toolbarIconButton(
                "arrow.clockwise",
                accessibilityIdentifier: "file-manager-refresh",
                helpText: "Refresh",
                disabled: false
            ) {
                viewModel.performContextAction(.refresh)
            }

            Label("Remote", systemImage: "externaldrive")
                .font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: true, vertical: false)
                .padding(.leading, 4)

            TextField("/path/to/dir", text: $remotePathDraft)
                .textFieldStyle(.roundedBorder)
                .font(.caption.monospaced())
                .frame(minWidth: 180, maxWidth: min(clampedPathFieldWidth, 520))
                .onSubmit {
                    jumpToRemotePath()
                }
                .accessibilityIdentifier("file-manager-path-field")

            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(VisualStyle.borderStrong)
                .frame(width: 4, height: 18)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            if pathWidthDragStart == nil {
                                pathWidthDragStart = remotePathFieldWidth
                            }
                            let start = pathWidthDragStart ?? remotePathFieldWidth
                            remotePathFieldWidth = min(max(start + value.translation.width, 180), 1200)
                        }
                        .onEnded { _ in
                            pathWidthDragStart = nil
                        }
                )
                .accessibilityIdentifier("file-manager-path-resize")

            toolbarIconButton(
                "arrow.right.circle",
                accessibilityIdentifier: "file-manager-go",
                helpText: "Go",
                disabled: false
            ) {
                jumpToRemotePath()
            }

            Spacer(minLength: 8)

            Toggle("Sync Terminal", isOn: $viewModel.isTerminalDirectorySyncEnabled)
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(.caption)
                .accessibilityIdentifier("file-manager-sync-toggle")
                .fixedSize()
        }
        .padding(.top, 4)
    }

    private var transferQueuePanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Transfer Queue")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if let overallProgress = viewModel.overallTransferProgress {
                    Text("\(Int(overallProgress * 100))%")
                        .font(.caption.monospaced())
                        .foregroundStyle(VisualStyle.textSecondary)
                }
            }

            if let overallProgress = viewModel.overallTransferProgress {
                ProgressView(value: overallProgress)
                    .progressViewStyle(.linear)
                    .controlSize(.small)
            }

            if viewModel.transferQueue.isEmpty {
                Text("No transfer tasks")
                    .monoMetaStyle()
            } else {
                List(viewModel.transferQueue) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(item.direction.rawValue)
                                .font(.caption.monospaced())
                                .frame(width: 70, alignment: .leading)
                                .foregroundStyle(VisualStyle.textSecondary)
                            Text(item.name)
                                .lineLimit(1)
                                .foregroundStyle(VisualStyle.textPrimary)
                            Spacer()
                            Text(item.status.rawValue)
                                .font(.caption.monospaced())
                                .foregroundStyle(statusColor(item.status))
                        }

                        if let progress = item.fractionCompleted {
                            ProgressView(value: progress)
                                .progressViewStyle(.linear)
                                .controlSize(.small)
                        }
                    }
                    .padding(.vertical, 2)
                    .padding(.horizontal, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(hoveredTransferID == item.id ? VisualStyle.leftInteractiveBackground : Color.clear)
                    )
                    .onHover { hovering in
                        hoveredTransferID = hovering ? item.id : nil
                    }
                }
                .frame(minHeight: 80, maxHeight: 120)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .scrollContentBackground(.hidden)
                .background(VisualStyle.rightPanelBackground)
                .listStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var panelContextMenu: some View {
        Button("Refresh") {
            viewModel.performContextAction(.refresh)
        }

        if viewModel.canPaste(into: viewModel.remoteDirectoryPath) {
            Button("Paste") {
                viewModel.performContextAction(.paste(destinationDirectory: viewModel.remoteDirectoryPath))
            }
        }

        Button("Upload To Current Directory") {
            presentUploadPanel(targetDirectory: viewModel.remoteDirectoryPath)
        }
    }

    @ViewBuilder
    private func rowContextMenu(for entry: RemoteFileEntry) -> some View {
        Button("Refresh") {
            viewModel.performContextAction(.refresh)
        }

        Divider()

        Button("Delete", role: .destructive) {
            viewModel.performContextAction(.delete(paths: [entry.path]))
            selectedRemotePaths.remove(entry.path)
        }

        Button("Rename") {
            beginRename(path: entry.path)
        }

        Button("Copy") {
            viewModel.performContextAction(.copy(paths: [entry.path]))
        }

        Button("Cut") {
            viewModel.performContextAction(.cut(paths: [entry.path]))
        }

        if viewModel.canPaste(into: entry.isDirectory ? entry.path : viewModel.remoteDirectoryPath) {
            Button("Paste") {
                let destination = entry.isDirectory ? entry.path : viewModel.remoteDirectoryPath
                viewModel.performContextAction(.paste(destinationDirectory: destination))
            }
        }

        Button("Download") {
            viewModel.performContextAction(.download(paths: [entry.path]))
        }
        .disabled(entry.isDirectory)

        Button("Move To") {
            moveSourcePaths = [entry.path]
            moveTargetPath = viewModel.remoteDirectoryPath
            isMoveSheetPresented = true
        }

        Divider()

        if !entry.isDirectory {
            Button("Edit") {
                editorTargetPath = entry.path
            }
        }

        Button("Copy Path") {
            copyToPasteboard(entry.path)
        }

        Button("Copy Name") {
            copyToPasteboard(entry.name)
        }

        Button("Properties") {
            propertiesTargetPath = entry.path
        }

        if entry.isDirectory {
            Divider()
            Button("Upload To Current Directory") {
                presentUploadPanel(targetDirectory: entry.path)
            }
        }
    }

    private func statusColor(_ status: TransferStatus) -> Color {
        switch status {
        case .queued:
            return .secondary
        case .running:
            return .orange
        case .success:
            return .green
        case .failed:
            return .red
        case .skipped:
            return .gray
        }
    }

    @ViewBuilder
    private func toolbarIconButton(
        _ systemImage: String,
        accessibilityIdentifier: String,
        helpText: String,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 14, height: 14)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .frame(width: 30, height: 28)
        .help(helpText)
        .disabled(disabled)
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private func handleRemoteRowTap(_ entry: RemoteFileEntry) {
        if NSEvent.modifierFlags.contains(.command) {
            if selectedRemotePaths.contains(entry.path) {
                selectedRemotePaths.remove(entry.path)
            } else {
                selectedRemotePaths.insert(entry.path)
            }
        } else {
            selectedRemotePaths = [entry.path]
        }

        let now = Date()
        if entry.isDirectory,
           lastTappedRemotePath == entry.path,
           now.timeIntervalSince(lastRemoteTapAt) < 0.32
        {
            viewModel.openRemote(entry)
            selectedRemotePaths.removeAll()
            lastTappedRemotePath = nil
            lastRemoteTapAt = .distantPast
            return
        }

        lastTappedRemotePath = entry.path
        lastRemoteTapAt = now
    }

    private func jumpToRemotePath() {
        viewModel.navigateRemote(to: remotePathDraft)
        selectedRemotePaths.removeAll()
    }

    private func navigateToRoot() {
        viewModel.navigateRemote(to: "/")
        selectedRemotePaths.removeAll()
    }

    private func beginRename(path: String) {
        renameTargetPath = path
        renameDraft = URL(fileURLWithPath: path).lastPathComponent
        isRenameSheetPresented = true
    }

    private func commitRename() {
        let sourcePath = renameTargetPath
        isRenameSheetPresented = false
        renameTargetPath = nil
        guard let sourcePath else { return }
        viewModel.performContextAction(.rename(path: sourcePath, newName: renameDraft))
    }

    private func copyToPasteboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    private func presentUploadPanel(targetDirectory: String) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.canCreateDirectories = false

        if panel.runModal() == .OK {
            let urls = panel.urls
            guard !urls.isEmpty else { return }
            viewModel.enqueueUpload(localFileURLs: urls, toRemoteDirectory: targetDirectory)
        }
    }

    private var renameSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename")
                .font(.headline)

            TextField("New name", text: $renameDraft)
                .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    isRenameSheetPresented = false
                }
                Button("Save") {
                    commitRename()
                }
                .buttonStyle(.borderedProminent)
                .disabled(renameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 360)
    }

    private var moveSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Move Selected Files")
                .font(.headline)

            Text("Destination Directory")
                .font(.subheadline)
                .foregroundStyle(VisualStyle.textSecondary)

            TextField("/target/path", text: $moveTargetPath)
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())

            HStack(spacing: 8) {
                Text("Conflict")
                    .font(.subheadline.weight(.semibold))

                Picker("Conflict", selection: $viewModel.conflictStrategy) {
                    ForEach(TransferConflictStrategy.allCases) { strategy in
                        Text(strategy.title).tag(strategy)
                    }
                }
                .pickerStyle(.menu)
                .frame(minWidth: 140)
                .labelsHidden()
                .accessibilityIdentifier("file-manager-move-conflict")
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    moveSourcePaths.removeAll()
                    isMoveSheetPresented = false
                }
                Button("Move") {
                    viewModel.moveRemoteEntries(
                        paths: moveSourcePaths,
                        toDirectory: moveTargetPath
                    )
                    moveSourcePaths.removeAll()
                    selectedRemotePaths.removeAll()
                    isMoveSheetPresented = false
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 360)
    }

    private func remoteRowIdentifier(_ path: String) -> String {
        let sanitized = path.replacingOccurrences(of: "/", with: "_")
        return "file-manager-remote-row\(sanitized)"
    }
}
