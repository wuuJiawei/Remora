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

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Button {
                    viewModel.goUpRemoteDirectory()
                } label: {
                    Label("Back", systemImage: "arrow.up.left")
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("Refresh") {
                    viewModel.refreshAll()
                }
                .buttonStyle(.bordered)
            }
            .padding(.bottom, 2)

            remotePanel
                .frame(minHeight: 250)

            HStack {
                Button {
                    for entry in selectedRemoteFiles {
                        viewModel.enqueueDownload(remoteEntry: entry)
                    }
                } label: {
                    Label("Download", systemImage: "arrow.down.circle.fill")
                }
                .buttonStyle(.bordered)
                .disabled(selectedRemoteFiles.isEmpty)

                Button(role: .destructive) {
                    viewModel.deleteRemoteEntries(paths: Array(selectedRemotePaths))
                    selectedRemotePaths.removeAll()
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .disabled(selectedRemotePaths.isEmpty)

                Button {
                    moveTargetPath = viewModel.remoteDirectoryPath
                    isMoveSheetPresented = true
                } label: {
                    Label("Move To", systemImage: "folder")
                }
                .buttonStyle(.bordered)
                .disabled(selectedRemotePaths.isEmpty)

                Spacer()

                Text("Server Files")
                    .monoMetaStyle()
            }

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
            HStack {
                Label("Remote", systemImage: "externaldrive")
                    .font(.subheadline.weight(.semibold))
                Spacer()
            }

            breadcrumbBar

            HStack(spacing: 8) {
                TextField("/path/to/dir", text: $remotePathDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption.monospaced())
                    .onSubmit {
                        jumpToRemotePath()
                    }

                Button("Go") {
                    jumpToRemotePath()
                }
                .buttonStyle(.bordered)
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
            .dropDestination(for: URL.self) { items, _ in
                guard !items.isEmpty else { return false }
                viewModel.enqueueUpload(localFileURLs: items, toRemoteDirectory: viewModel.remoteDirectoryPath)
                return true
            }
        }
    }

    private var breadcrumbBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Button("/") {
                    navigateToBreadcrumb(prefixCount: 0)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                ForEach(Array(pathComponents.enumerated()), id: \.offset) { index, component in
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(VisualStyle.textSecondary)
                    Button(component) {
                        navigateToBreadcrumb(prefixCount: index + 1)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
    }

    private var transferQueuePanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Transfer Queue")
                .font(.subheadline.weight(.semibold))

            if viewModel.transferQueue.isEmpty {
                Text("No transfer tasks")
                    .monoMetaStyle()
            } else {
                List(viewModel.transferQueue) { item in
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
                .frame(minHeight: 120)
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
        }
    }

    private var pathComponents: [String] {
        viewModel.remoteDirectoryPath
            .split(separator: "/")
            .map(String.init)
    }

    private func jumpToRemotePath() {
        viewModel.navigateRemote(to: remotePathDraft)
        selectedRemotePaths.removeAll()
    }

    private func navigateToBreadcrumb(prefixCount: Int) {
        if prefixCount == 0 {
            viewModel.navigateRemote(to: "/")
        } else {
            let path = "/" + pathComponents.prefix(prefixCount).joined(separator: "/")
            viewModel.navigateRemote(to: path)
        }
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
}
