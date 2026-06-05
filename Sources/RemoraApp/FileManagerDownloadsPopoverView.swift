import SwiftUI
import AppKit

struct FileManagerDownloadsPopoverView: View {
    @ObservedObject var viewModel: FileTransferViewModel
    let onOpenDownloadSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(tr("Transfers"))
                    .font(.headline)
                Spacer()
                statusBadge
            }

            if let progress = viewModel.overallTransferProgress {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
            }

            actionBar

            if viewModel.transferQueue.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text(tr("No transfers yet."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(viewModel.transferQueue.reversed())) { item in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(item.name)
                                        .font(.callout)
                                        .lineLimit(1)
                                    Spacer()
                                    Text(item.status.rawValue)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Text(item.destinationPath)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                if let progress = item.fractionCompleted {
                                    ProgressView(value: progress)
                                        .progressViewStyle(.linear)
                                }
                                rowActions(for: item)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 420, height: 340)
    }

    private var aggregateStatus: TransferQueueAggregateStatus {
        TransferQueueAggregateSnapshot.resolve(
            items: viewModel.transferQueue,
            currentBatchID: viewModel.currentTransferBatchID,
            runningFallbackProgress: 0.1
        ).status
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch aggregateStatus {
        case .idle:
            EmptyView()
        case .transferring:
            if let progress = viewModel.overallTransferProgress {
                Text(progress.formatted(.percent.precision(.fractionLength(0))))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.blue)
            }
        case .completed:
            Label(tr("Completed"), systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .finishedWithIssues:
            Label(tr("Finished With Issues"), systemImage: "exclamationmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    private var actionBar: some View {
        HStack(spacing: 8) {
            Button(tr("Clear Finished")) {
                clearFinished()
            }
            .disabled(!viewModel.transferQueue.contains { $0.status.isTerminal })

            Button(tr("Download Directory")) {
                onOpenDownloadSettings()
            }

            Spacer()
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private func rowActions(for item: TransferItem) -> some View {
        HStack(spacing: 8) {
            if item.status == .failed || item.status == .skipped || item.status == .stopped {
                Button(tr("Retry")) {
                    viewModel.retryTransfer(itemID: item.id)
                }
            }

            if item.status == .queued || item.status == .running {
                Button(tr("Stop")) {
                    viewModel.stopTransfer(itemID: item.id)
                }
            }

            if item.status == .success {
                Button(tr("Reveal in Finder")) {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.destinationPath)])
                }
            }
        }
        .buttonStyle(.link)
        .font(.caption)
    }

    private func clearFinished() {
        viewModel.clearFinishedTransfers()
    }
}
