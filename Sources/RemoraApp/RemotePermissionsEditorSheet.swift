import SwiftUI
import RemoraCore

struct RemotePermissionsEditorSheet: View {
    @StateObject private var viewModel: RemotePermissionsEditorViewModel
    private let onClose: () -> Void

    init(
        path: String,
        fileTransfer: FileTransferViewModel,
        onClose: @escaping () -> Void,
        initialAttributes: RemoteFileAttributes? = nil
    ) {
        self.onClose = onClose
        _viewModel = StateObject(
            wrappedValue: RemotePermissionsEditorViewModel(
                path: path,
                fileTransfer: fileTransfer,
                initialAttributes: initialAttributes
            )
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(tr("Edit Permissions"))
                .font(.headline)

            Text(viewModel.path)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)

            permissionRow(title: tr("Owner"), scope: .owner, triad: viewModel.ownerPermissions)
            permissionRow(title: tr("Group"), scope: .group, triad: viewModel.groupPermissions)
            permissionRow(title: tr("Public"), scope: .other, triad: viewModel.otherPermissions)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text(tr("Permissions"))
                    TextField("0777", text: Binding(
                        get: { viewModel.permissionsText },
                        set: { viewModel.updatePermissionsText($0) }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .accessibilityIdentifier("remote-permissions-mode")
                }
                GridRow {
                    Text(tr("User"))
                    TextField(tr("User"), text: $viewModel.ownerText)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("remote-permissions-owner")
                }
                GridRow {
                    Text(tr("Group"))
                    TextField(tr("Group"), text: $viewModel.groupText)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("remote-permissions-group")
                }
            }

            Toggle(tr("Apply changes recursively"), isOn: $viewModel.applyRecursively)
                .toggleStyle(.checkbox)
                .accessibilityIdentifier("remote-permissions-recursive")

            if let successMessage = viewModel.successMessage {
                Text(successMessage)
                    .font(.caption)
                    .foregroundStyle(.green)
            }

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button(tr("Close")) { onClose() }
                    .buttonStyle(.bordered)
                Button(tr("Save")) {
                    Task { await viewModel.save() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isLoading || viewModel.isSaving)
            }
        }
        .padding(16)
        .frame(width: 720)
        .task {
            await viewModel.load()
        }
    }

    private func permissionRow(title: String, scope: RemotePermissionScope, triad: PermissionTriadState) -> some View {
        HStack(spacing: 24) {
            Text(title)
                .frame(width: 120, alignment: .leading)
            permissionToggle(title: tr("Read"), scope: scope, permission: .read, isOn: triad.read)
            permissionToggle(title: tr("Write"), scope: scope, permission: .write, isOn: triad.write)
            permissionToggle(title: tr("Execute"), scope: scope, permission: .execute, isOn: triad.execute)
        }
    }

    private func permissionToggle(title: String, scope: RemotePermissionScope, permission: RemotePermissionKind, isOn: Bool) -> some View {
        Toggle(title, isOn: Binding(
            get: { isOn },
            set: { viewModel.setPermission(scope: scope, permission: permission, enabled: $0) }
        ))
        .toggleStyle(.checkbox)
    }
}
