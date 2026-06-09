import SwiftUI

struct RemoteCompressSheet: View {
    @Environment(\.dismiss) private var dismiss

    let sourcePaths: [String]
    @ObservedObject var fileTransfer: FileTransferViewModel
    @Binding var archiveName: String
    @Binding var format: ArchiveFormat
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(tr("Compress Files"))
                .font(.headline)

            Text(String(format: tr("Selected items: %d"), sourcePaths.count))
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                Text(tr("Archive Name"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField(tr("Archive Name"), text: $archiveName)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("remote-compress-name")
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(tr("Format"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker(tr("Format"), selection: $format) {
                    Text("ZIP").tag(ArchiveFormat.zip)
                    Text("TAR").tag(ArchiveFormat.tar)
                    Text("TAR.GZ").tag(ArchiveFormat.tarGz)
                    Text("7Z").tag(ArchiveFormat.sevenZip)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("remote-compress-format")
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
                        .accessibilityIdentifier("remote-compress-progress")
                }
            }

            HStack {
                Spacer()
                Button(tr("Cancel")) { dismiss() }
                    .buttonStyle(.bordered)
                Button(tr("Compress")) {
                    onConfirm()
                }
                .buttonStyle(.borderedProminent)
                .disabled(fileTransfer.archiveOperationProgress != nil || archiveName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 420)
    }
}
