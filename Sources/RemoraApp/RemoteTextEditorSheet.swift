import SwiftUI

struct RemoteTextEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: RemoteTextEditorViewModel

    init(path: String, fileTransfer: FileTransferViewModel) {
        _viewModel = StateObject(wrappedValue: RemoteTextEditorViewModel(path: path, fileTransfer: fileTransfer))
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(tr("Edit File"))
                        .font(.headline)
                    Text(viewModel.path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
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
        .task {
            await viewModel.load()
        }
    }
}
