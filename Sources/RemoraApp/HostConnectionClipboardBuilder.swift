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
            "Host: \(host.address)",
            "Port: \(host.port)",
            "Username: \(host.username)",
        ]

        switch host.auth.method {
        case .password:
            lines.append("Auth: Password")
            let password = await resolvedPassword(for: host, credentialStore: credentialStore)
            lines.append("Password: \(password)")
        case .privateKey:
            lines.append("Auth: Private Key")
            let keyPath = normalized(host.auth.keyReference) ?? "(not set)"
            lines.append("Private Key Path: \(keyPath)")
        case .agent:
            lines.append("Auth: SSH Agent")
            lines.append("Credential: Managed by local SSH agent")
        }

        return lines.joined(separator: "\n")
    }

    private static func resolvedPassword(
        for host: RemoraCore.Host,
        credentialStore: CredentialStore
    ) async -> String {
        guard let reference = normalized(host.auth.passwordReference) else {
            return "(not saved)"
        }

        guard let password = await credentialStore.secret(for: reference),
              !password.isEmpty
        else {
            return "(not saved)"
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
