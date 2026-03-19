import AppKit
import SwiftUI

struct RemoteLogViewerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: RemoteLogViewerViewModel
    @State private var lineCountDraft: String
    @State private var toastMessage: String?
    @State private var toastHideTask: Task<Void, Never>?

    init(path: String, fileTransfer: FileTransferViewModel) {
        _viewModel = StateObject(
            wrappedValue: RemoteLogViewerViewModel(path: path, fileTransfer: fileTransfer)
        )
        _lineCountDraft = State(initialValue: "\(FileTransferViewModel.defaultRemoteLogTailLineCount)")
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(tr("Live View"))
                        .font(.headline)
                    HStack(spacing: 6) {
                        Text(viewModel.path)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        Button {
                            Task {
                                let queued = await viewModel.queueDownload()
                                if queued {
                                    showToast(tr("Download queued."))
                                }
                            }
                        } label: {
                            Image(systemName: "arrow.down.circle")
                                .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.borderless)
                        .help(tr("Download File"))
                        .accessibilityLabel(tr("Download File"))
                        .accessibilityIdentifier("remote-log-viewer-download")

                        Button {
                            copyPathToPasteboard()
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.borderless)
                        .help(tr("Copy Path"))
                        .accessibilityLabel(tr("Copy Path"))
                        .accessibilityIdentifier("remote-log-viewer-copy-path")
                    }
                }
                Spacer()
                Text(tr("Read-only"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Toggle(tr("Follow"), isOn: Binding(
                    get: { viewModel.isFollowing },
                    set: { viewModel.setFollowing($0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .fixedSize()

                HStack(spacing: 6) {
                    Text(tr("Lines"))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    TextField(tr("Lines"), text: $lineCountDraft)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 72)
                        .font(.caption.monospaced())
                        .onSubmit {
                            applyLineCountDraft()
                        }
                        .accessibilityIdentifier("remote-log-viewer-lines")

                    Stepper("", value: Binding(
                        get: { viewModel.lineCount },
                        set: { newValue in
                            lineCountDraft = "\(newValue)"
                            Task { await viewModel.applyLineCount(newValue) }
                        }
                    ), in: 1 ... FileTransferViewModel.maxRemoteLogTailLineCount)
                    .labelsHidden()

                    Button(tr("Apply")) {
                        applyLineCountDraft()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Spacer()

                Button(tr("Refresh")) {
                    Task { await viewModel.refresh(showLoading: true) }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(viewModel.isRefreshing)
                .accessibilityIdentifier("remote-log-viewer-refresh")
            }

            ZStack(alignment: .topLeading) {
                RemoteTextEditorRepresentable(
                    text: Binding(
                        get: { viewModel.text },
                        set: { _ in }
                    ),
                    isEditable: false,
                    autoScrollToBottom: viewModel.isFollowing
                )
                if viewModel.isLoading {
                    ProgressView("Loading...")
                        .padding(8)
                }
            }
            .frame(minHeight: 360)

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Spacer()
                Button(tr("Close")) {
                    dismiss()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(16)
        .frame(minWidth: 760, minHeight: 520)
        .overlay(alignment: .bottom) {
            if let toastMessage {
                toastView(message: toastMessage)
                    .padding(.bottom, 10)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .accessibilityIdentifier("remote-log-viewer-toast")
            }
        }
        .task {
            await viewModel.load()
            lineCountDraft = "\(viewModel.lineCount)"
        }
        .onDisappear {
            viewModel.stop()
            toastHideTask?.cancel()
            toastHideTask = nil
            toastMessage = nil
        }
    }

    private func applyLineCountDraft() {
        let parsed = Int(lineCountDraft) ?? viewModel.lineCount
        let clamped = min(max(parsed, 1), FileTransferViewModel.maxRemoteLogTailLineCount)
        lineCountDraft = "\(clamped)"
        Task { await viewModel.applyLineCount(clamped) }
    }

    private func copyPathToPasteboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(viewModel.path, forType: .string)
        showToast(tr("Path copied to clipboard."))
    }

    private func showToast(_ message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        toastHideTask?.cancel()
        withAnimation(.easeInOut(duration: 0.18)) {
            toastMessage = trimmed
        }
        toastHideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.18)) {
                toastMessage = nil
            }
            toastHideTask = nil
        }
    }

    @ViewBuilder
    private func toastView(message: String) -> some View {
        Text(message)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.primary)
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.regularMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.primary.opacity(0.12), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.12), radius: 6, y: 2)
    }
}
