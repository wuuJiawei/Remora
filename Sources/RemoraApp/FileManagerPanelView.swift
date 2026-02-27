import AppKit
import SwiftUI
import RemoraCore

struct FileManagerPanelView: View {
    @ObservedObject var viewModel: FileTransferViewModel

    @State private var selectedRemotePaths: Set<String> = []
    @State private var hoveredRemotePath: String?
    @State private var hoveredTransferID: UUID?
    @State private var remotePathDraft = "/"
    @State private var isMoveSheetPresented = false
    @State private var moveTargetPath = "/"

    private var selectedRemoteEntries: [RemoteFileEntry] {
        viewModel.remoteEntries.filter { selectedRemotePaths.contains($0.path) }
    }

    private var selectedRemoteFiles: [RemoteFileEntry] {
        selectedRemoteEntries.filter { !$0.isDirectory }
    }

    private var hasRetryableTransfers: Bool {
        viewModel.transferQueue.contains { $0.status == .failed || $0.status == .skipped }
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Button {
                    viewModel.goUpRemoteDirectory()
                } label: {
                    Label("Back", systemImage: "arrow.up.left")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("file-manager-back")

                Spacer()

                Button("Refresh") {
                    viewModel.refreshAll()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("file-manager-refresh")
            }
            .padding(.top, 4)

            remotePanel
                .frame(minHeight: 150, maxHeight: 220)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Button {
                        for entry in selectedRemoteFiles {
                            viewModel.enqueueDownload(remoteEntry: entry)
                        }
                    } label: {
                        Label("Download", systemImage: "arrow.down.circle.fill")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(selectedRemoteFiles.isEmpty)
                    .accessibilityIdentifier("file-manager-download")

                    Button(role: .destructive) {
                        viewModel.deleteRemoteEntries(paths: Array(selectedRemotePaths))
                        selectedRemotePaths.removeAll()
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(selectedRemotePaths.isEmpty)
                    .accessibilityIdentifier("file-manager-delete")

                    Button {
                        moveTargetPath = viewModel.remoteDirectoryPath
                        isMoveSheetPresented = true
                    } label: {
                        Label("Move To", systemImage: "folder")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(selectedRemotePaths.isEmpty)
                    .accessibilityIdentifier("file-manager-move")

                    Text("Conflict")
                        .font(.subheadline.weight(.semibold))

                    Picker("", selection: $viewModel.conflictStrategy) {
                        ForEach(TransferConflictStrategy.allCases) { strategy in
                            Text(strategy.title).tag(strategy)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(minWidth: 140)
                    .accessibilityIdentifier("file-manager-conflict")

                    Button("Retry Failed") {
                        viewModel.retryFailedTransfers()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!hasRetryableTransfers)
                    .accessibilityIdentifier("file-manager-retry-failed")
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
    }

    private var remotePanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Label("Remote", systemImage: "externaldrive")
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: true, vertical: false)

                Button("/") {
                    navigateToRoot()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                TextField("/path/to/dir", text: $remotePathDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption.monospaced())
                    .onSubmit {
                        jumpToRemotePath()
                    }
                    .accessibilityIdentifier("file-manager-path-field")

                Button("Go") {
                    jumpToRemotePath()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("file-manager-go")
            }

            List(viewModel.remoteEntries, id: \.path, selection: $selectedRemotePaths) { entry in
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
                        .fill(hoveredRemotePath == entry.path ? VisualStyle.leftInteractiveBackground : Color.clear)
                )
                .contentShape(Rectangle())
                .tag(entry.path)
                .accessibilityIdentifier(remoteRowIdentifier(entry.path))
                .onTapGesture {
                    if NSEvent.modifierFlags.contains(.command) {
                        if selectedRemotePaths.contains(entry.path) {
                            selectedRemotePaths.remove(entry.path)
                        } else {
                            selectedRemotePaths.insert(entry.path)
                        }
                    } else {
                        selectedRemotePaths = [entry.path]
                    }
                }
                .onTapGesture(count: 2) {
                    guard entry.isDirectory else { return }
                    viewModel.openRemote(entry)
                    selectedRemotePaths.removeAll()
                }
                .onHover { hovering in
                    hoveredRemotePath = hovering ? entry.path : nil
                }
                .dropDestination(for: URL.self) { items, _ in
                    guard entry.isDirectory, !items.isEmpty else { return false }
                    viewModel.enqueueUpload(localFileURLs: items, toRemoteDirectory: entry.path)
                    return true
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
        }
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

    private func jumpToRemotePath() {
        viewModel.navigateRemote(to: remotePathDraft)
        selectedRemotePaths.removeAll()
    }

    private func navigateToRoot() {
        viewModel.navigateRemote(to: "/")
        selectedRemotePaths.removeAll()
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

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    isMoveSheetPresented = false
                }
                Button("Move") {
                    viewModel.moveRemoteEntries(
                        paths: Array(selectedRemotePaths),
                        toDirectory: moveTargetPath
                    )
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
