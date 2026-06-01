import AppKit
import SwiftUI
import RemoraCore

extension FileManagerPanelView {
    static let remoteDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.doesRelativeDateFormatting = true
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    var remoteListHeader: some View {
        HStack(spacing: 10) {
            sortHeaderButton(
                isShowingSearchResults ? tr("Path") : tr("Name"),
                column: .name,
                width: nil,
                alignment: .leading
            )
            Divider()
                .frame(height: 14)
            sortHeaderButton(tr("Permission"), column: .permission, width: 120, alignment: .leading)
            Divider()
                .frame(height: 14)
            sortHeaderButton(tr("Date"), column: .date, width: 170, alignment: .leading)
            Divider()
                .frame(height: 14)
            sortHeaderButton(tr("Size"), column: .size, width: 90, alignment: .trailing)
            Divider()
                .frame(height: 14)
            sortHeaderButton(tr("Kind"), column: .kind, width: 90, alignment: .leading)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(VisualStyle.textSecondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    func sortHeaderButton(
        _ title: String,
        column: FileManagerRemoteSortColumn,
        width: CGFloat?,
        alignment: Alignment
    ) -> some View {
        Button {
            guard !isShowingSearchResults else { return }
            if remoteSortColumn == column {
                isRemoteSortAscending.toggle()
            } else {
                remoteSortColumn = column
                isRemoteSortAscending = true
            }
        } label: {
            HStack(spacing: 3) {
                if alignment == .trailing {
                    Spacer(minLength: 0)
                }
                Text(title)
                    .lineLimit(1)
                if remoteSortColumn == column {
                    Image(systemName: isRemoteSortAscending ? "chevron.up" : "chevron.down")
                        .font(.caption2.weight(.semibold))
                }
                if alignment != .trailing {
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity, alignment: alignment)
            .foregroundStyle(VisualStyle.textSecondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isShowingSearchResults)
        .frame(maxWidth: width == nil ? .infinity : nil)
        .frame(width: width, alignment: alignment)
        .contentShape(Rectangle())
        .accessibilityIdentifier("file-manager-sort-\(column.rawValue)")
    }

    func remoteDateText(for date: Date?) -> String {
        guard let date else { return "—" }
        let formatter = Self.remoteDateFormatter
        formatter.locale = AppLanguageMode.preferredLocale()
        return formatter.string(from: date)
    }

    func permissionString(for entry: RemoteFileEntry) -> String {
        guard let permission = entry.permissions else {
            return entry.isDirectory ? "d---------" : "----------"
        }
        return permissionString(mode: permission, isDirectory: entry.isDirectory)
    }

    func permissionString(mode: UInt16, isDirectory: Bool) -> String {
        let prefix = isDirectory ? "d" : "-"
        let owner = permissionTriad((mode >> 6) & 0b111)
        let group = permissionTriad((mode >> 3) & 0b111)
        let other = permissionTriad(mode & 0b111)
        return "\(prefix)\(owner)\(group)\(other)"
    }

    func permissionTriad(_ value: UInt16) -> String {
        let readable = (value & 0b100) != 0 ? "r" : "-"
        let writable = (value & 0b010) != 0 ? "w" : "-"
        let executable = (value & 0b001) != 0 ? "x" : "-"
        return "\(readable)\(writable)\(executable)"
    }

    func remoteSizeText(for size: Int64?) -> String {
        guard let size else { return "—" }
        return ByteSizeFormatter.format(size)
    }

    func kindString(for entry: RemoteFileEntry) -> String {
        entry.isDirectory ? tr("Folder") : tr("File")
    }

    func cachedRemoteAttributes(for path: String) -> RemoteFileAttributes? {
        guard let entry = remoteListPresentation.itemsByPath[path]?.sourceEntry else {
            return nil
        }
        return RemoteFileAttributes(
            permissions: entry.permissions,
            owner: entry.owner,
            group: entry.group,
            size: entry.size,
            modifiedAt: entry.modifiedAt,
            isDirectory: entry.isDirectory
        )
    }

    var remoteSearchStatusStrip: some View {
        let searchStatus = viewModel.remoteSearchStatus

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(compactRemoteSearchSummary(searchStatus))
                    .font(.caption)
                    .foregroundStyle(VisualStyle.textSecondary)
                    .lineLimit(1)

                Spacer(minLength: 8)

                if searchStatus.isResultTruncated {
                    Text(String(format: tr("Showing the first %d matches."), FileTransferViewModel.maxRemoteSearchResults))
                        .font(.caption)
                        .foregroundStyle(VisualStyle.textSecondary)
                        .lineLimit(1)
                }
            }

            if searchStatus.isRunning {
                ProgressView()
                    .progressViewStyle(.linear)
                    .controlSize(.small)
                    .accessibilityIdentifier("file-manager-search-progress")
            }

            if searchStatus.isRunning, !searchStatus.activity.isEmpty {
                FileManagerRemoteSearchActivityTicker(activities: searchStatus.activity)
                    .accessibilityIdentifier("file-manager-search-activity")
            }

            if let errorMessage = searchStatus.errorMessage,
               !errorMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.72))
        )
    }

    func compactRemoteSearchSummary(_ status: RemoteSearchStatus) -> String {
        if let statusText = status.statusText,
           !statusText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return "\(remoteSearchScopeDescription(status))  ·  \(statusText)"
        }
        return remoteSearchScopeDescription(status)
    }
}
