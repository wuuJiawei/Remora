import Foundation
import RemoraCore

@MainActor
final class RemoteFilePropertiesViewModel: ObservableObject {
    @Published var permissionsText: String = ""
    @Published var ownerText: String = ""
    @Published var groupText: String = ""
    @Published var modifiedAt: Date = Date()
    @Published private(set) var isLoading = false
    @Published private(set) var isSaving = false
    @Published var errorMessage: String?

    @Published private(set) var isDirectory = false
    @Published private(set) var size: Int64 = 0

    let path: String

    private let fileTransfer: FileTransferViewModel
    private let initialAttributes: RemoteFileAttributes?

    init(path: String, fileTransfer: FileTransferViewModel, initialAttributes: RemoteFileAttributes? = nil) {
        self.path = path
        self.fileTransfer = fileTransfer
        self.initialAttributes = initialAttributes
    }

    func load() async {
        if let initialAttributes {
            apply(attributes: initialAttributes)
            errorMessage = nil
            if !needsRemoteAttributeFetch(for: initialAttributes) {
                return
            }
        }

        isLoading = true
        defer { isLoading = false }

        do {
            let attrs = try await fileTransfer.loadRemoteAttributes(path: path)
            apply(attributes: attrs)
            errorMessage = nil
        } catch {
            if initialAttributes == nil {
                errorMessage = error.localizedDescription
            }
        }
    }

    func save() async {
        isSaving = true
        defer { isSaving = false }

        let trimmedPermissions = permissionsText.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsedPermissions: UInt16? = {
            guard !trimmedPermissions.isEmpty else { return nil }
            return UInt16(trimmedPermissions, radix: 8)
        }()

        if !trimmedPermissions.isEmpty, parsedPermissions == nil {
            errorMessage = "Permissions should be a valid octal value, e.g. 755"
            return
        }

        let attributes = RemoteFileAttributes(
            permissions: parsedPermissions,
            owner: ownerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : ownerText,
            group: groupText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : groupText,
            size: size,
            modifiedAt: modifiedAt,
            isDirectory: isDirectory
        )

        do {
            try await fileTransfer.saveRemoteAttributes(path: path, attributes: attributes)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func apply(attributes: RemoteFileAttributes) {
        permissionsText = attributes.permissions.map { String($0, radix: 8) } ?? ""
        ownerText = attributes.owner ?? ""
        groupText = attributes.group ?? ""
        modifiedAt = attributes.modifiedAt
        isDirectory = attributes.isDirectory
        size = attributes.size
    }

    private func needsRemoteAttributeFetch(for attributes: RemoteFileAttributes) -> Bool {
        attributes.permissions == nil || attributes.owner == nil || attributes.group == nil
    }
}
