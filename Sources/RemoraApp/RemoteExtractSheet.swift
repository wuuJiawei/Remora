import SwiftUI

struct RemoteExtractSheet: View {
    @Environment(\.dismiss) private var dismiss

    let archivePath: String
    @ObservedObject var fileTransfer: FileTransferViewModel
    @Binding var destinationPath: String
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(tr("Extract Archive"))
                .font(.headline)

            Text(archivePath)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)

            VStack(alignment: .leading, spacing: 8) {
                Text(tr("Destination Directory"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField(tr("Destination Directory"), text: $destinationPath)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .accessibilityIdentifier("remote-extract-destination")
            }

            if let progress = fileTransfer.archiveOperationProgress {
                VStack(alignment: .leading, spacing: 6) {
                    if let statusText = fileTransfer.archiveOperationStatusText {
                        Text(statusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .accessibilityIdentifier("remote-extract-progress")
                }
            }

            HStack {
                Spacer()
                Button(tr("Cancel")) { dismiss() }
                    .buttonStyle(.bordered)
                Button(tr("Extract")) {
                    onConfirm()
                }
                .buttonStyle(.borderedProminent)
                .disabled(fileTransfer.archiveOperationProgress != nil || destinationPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 460)
    }
}
