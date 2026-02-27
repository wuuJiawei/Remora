import SwiftUI
import RemoraCore

struct FileManagerPanelView: View {
    @ObservedObject var viewModel: FileTransferViewModel

    @State private var selectedRemotePath: String?
    @State private var hoveredRemotePath: String?
    @State private var hoveredTransferID: UUID?
    @State private var remotePathDraft = "/"

    private var selectedRemoteEntry: RemoteFileEntry? {
        guard let selectedRemotePath else { return nil }
        return viewModel.remoteEntries.first(where: { $0.path == selectedRemotePath })
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
                    if let selectedRemoteEntry {
                        viewModel.enqueueDownload(remoteEntry: selectedRemoteEntry)
                    }
                } label: {
                    Label("Download", systemImage: "arrow.down.circle.fill")
                }
                .buttonStyle(.bordered)
                .disabled(selectedRemoteEntry == nil || selectedRemoteEntry?.isDirectory == true)

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

            List(viewModel.remoteEntries, id: \.path) { entry in
                Button {
                    if entry.isDirectory {
                        viewModel.openRemote(entry)
                        selectedRemotePath = nil
                    } else {
                        selectedRemotePath = entry.path
                    }
                } label: {
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
                            .fill(selectedRemotePath == entry.path || hoveredRemotePath == entry.path ? VisualStyle.leftInteractiveBackground : Color.clear)
                    )
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    hoveredRemotePath = hovering ? entry.path : nil
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .scrollContentBackground(.hidden)
            .background(VisualStyle.rightPanelBackground)
            .listStyle(.plain)
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
        selectedRemotePath = nil
    }

    private func navigateToBreadcrumb(prefixCount: Int) {
        if prefixCount == 0 {
            viewModel.navigateRemote(to: "/")
        } else {
            let path = "/" + pathComponents.prefix(prefixCount).joined(separator: "/")
            viewModel.navigateRemote(to: path)
        }
        selectedRemotePath = nil
    }
}
