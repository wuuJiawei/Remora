import Foundation
import RemoraCore

struct HostConnectionClipboardBuilder {
    static func sshCommand(for host: RemoraCore.Host) -> String {
        "ssh \(host.username)@\(host.address) -p \(host.port)"
    }

    static func connectionInfoText(
        for host: RemoraCore.Host,
        credentialStore: CredentialStore = CredentialStore()
    ) async -> String {
        var lines = [
            "\(tr("Host")): \(host.address)",
            "\(tr("Port")): \(host.port)",
            "\(tr("Username")): \(host.username)",
        ]

        switch host.auth.method {
        case .password:
            lines.append("\(tr("Auth")): \(tr("Password"))")
            let password = await resolvedPassword(for: host, credentialStore: credentialStore)
            lines.append("\(tr("Password")): \(password)")
        case .privateKey:
            lines.append("\(tr("Auth")): \(tr("Private Key"))")
            let keyPath = normalized(host.auth.keyReference) ?? tr("(not set)")
            lines.append("\(tr("Private Key Path")): \(keyPath)")
        case .agent:
            lines.append("\(tr("Auth")): \(tr("SSH Agent"))")
            lines.append("\(tr("Credential")): \(tr("Managed by local SSH agent"))")
        }

        return lines.joined(separator: "\n")
    }

    private static func resolvedPassword(
        for host: RemoraCore.Host,
        credentialStore: CredentialStore
    ) async -> String {
        guard let reference = normalized(host.auth.passwordReference) else {
            return tr("(not saved)")
        }

        guard let password = await credentialStore.secret(for: reference),
              !password.isEmpty
        else {
            return tr("(not saved)")
        }
        return password
    }

    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else {
            return nil
        }
        return trimmed
    }
}
