import AppKit
import SwiftUI

struct RemoteTextEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: RemoteTextEditorViewModel
    @State private var toastMessage: String?
    @State private var toastHideTask: Task<Void, Never>?

    init(path: String, fileTransfer: FileTransferViewModel) {
        _viewModel = StateObject(wrappedValue: RemoteTextEditorViewModel(path: path, fileTransfer: fileTransfer))
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(tr("Edit File"))
                        .font(.headline)
                    HStack(spacing: 6) {
                        Text(viewModel.path)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        Button {
                            copyPathToPasteboard()
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.borderless)
                        .help(tr("Copy Path"))
                        .accessibilityLabel(tr("Copy Path"))
                        .accessibilityIdentifier("remote-text-editor-copy-path")
                    }
                }
                Spacer()
                Text(viewModel.encodingLabel)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }

            ZStack(alignment: .topLeading) {
                TextEditor(text: $viewModel.text)
                    .font(.body.monospaced())
                    .disabled(viewModel.isLoading || viewModel.isReadOnly)
                if viewModel.isLoading {
                    ProgressView("Loading...")
                        .padding(8)
                }
            }
            .frame(minHeight: 320)

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                if viewModel.isReadOnly {
                    Text(tr("Read-only"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if viewModel.hasUnsavedChanges {
                    Text(tr("Unsaved changes"))
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                Spacer()

                Button(tr("Close")) {
                    dismiss()
                }
                .buttonStyle(.bordered)

                Button(tr("Save")) {
                    Task { await viewModel.save() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isLoading || viewModel.isSaving || viewModel.isReadOnly || !viewModel.hasUnsavedChanges)
            }
        }
        .padding(16)
        .frame(minWidth: 720, minHeight: 460)
        .overlay(alignment: .bottom) {
            if let toastMessage {
                toastView(message: toastMessage)
                    .padding(.bottom, 10)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .accessibilityIdentifier("remote-text-editor-toast")
            }
        }
        .task {
            await viewModel.load()
        }
        .onDisappear {
            toastHideTask?.cancel()
            toastHideTask = nil
            toastMessage = nil
        }
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
