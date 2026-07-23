import Foundation
import RemoraCore

struct HostConnectionClipboardBuilder {
    static func sshCommand(for host: RemoraCore.Host) throws -> String {
        let resolved = try HostConnectionRouteResolver().resolve(host: host)
        let destination = quoteShellArgument("\(resolved.route.transportUsername)@\(host.address)")
        return "ssh -p \(host.port) \(destination)"
    }

    static func connectionInfoText(
        for host: RemoraCore.Host,
        includePassword: Bool = false,
        credentialStore: CredentialStore = CredentialStore()
    ) async throws -> String {
        let resolved = try HostConnectionRouteResolver().resolve(host: host)
        var lines = [
            "\(tr("Host")): \(host.address)",
            "\(tr("Port")): \(host.port)",
        ]

        switch host.connectionRoute {
        case .direct:
            lines.append("\(tr("Connection route")): \(tr("Direct"))")
            lines.append("\(tr("Username")): \(resolved.route.transportUsername)")
        case .gateway(let gateway):
            lines.append("\(tr("Connection route")): \(tr("JumpServer"))")
            lines.append("\(tr("Platform username")): \(gateway.platformUsername)")
            lines.append("\(tr("SSH username")): \(resolved.route.transportUsername)")
            if let target = gateway.target {
                lines.append("\(tr("Asset")): \(target.assetDisplayName)")
                lines.append("\(tr("Asset target")): \(target.assetTarget)")
                lines.append("\(tr("Asset account username")): \(target.accountUsername)")
            } else {
                lines.append("\(tr("Target")): \(tr("Interactive asset menu"))")
            }
        }

        switch host.auth.method {
        case .password:
            lines.append("\(tr("Auth")): \(tr("Password"))")
            if includePassword,
               let passwordReference = normalized(host.auth.passwordReference),
               let password = await credentialStore.secret(for: passwordReference),
               !password.isEmpty
            {
                lines.append("\(tr("Password")): \(password)")
            }
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

    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else {
            return nil
        }
        return trimmed
    }

    private static func quoteShellArgument(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }
}
