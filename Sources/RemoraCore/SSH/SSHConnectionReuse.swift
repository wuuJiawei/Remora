import Foundation

enum SSHConnectionReuse {
    enum Purpose: String, Sendable {
        case sftp
        case remoteCommand = "remote-command"
        case portForward = "port-forward"
        case shell
    }

    static func masterOptions(for host: Host, purpose: Purpose) -> [String] {
        let path = controlPath(for: host, purpose: purpose)
        SSHControlMasterCleanup.registerControlPath(path)
        return [
            "-o", "ControlMaster=auto",
            "-o", "ControlPersist=no",
            "-o", "ControlPath=\(path)",
        ]
    }

    static func reuseOnlyOptions(for host: Host, purpose: Purpose) -> [String] {
        [
            "-o", "ControlMaster=no",
            "-o", "ControlPath=\(controlPath(for: host, purpose: purpose))",
        ]
    }

    static func removeControlPath(for host: Host, purpose: Purpose) {
        SSHControlMasterCleanup.removeControlPath(controlPath(for: host, purpose: purpose))
    }

    static func controlPath(for host: Host, purpose: Purpose) -> String {
        let stableID = host.id.uuidString.prefix(8)
        let raw = "remora-\(stableID)-\(purpose.rawValue)-\(host.username)-\(host.address)-\(host.port)"
        let sanitized = raw.map { scalar -> Character in
            if scalar.isLetter || scalar.isNumber || scalar == "-" || scalar == "_" {
                return scalar
            }
            return "_"
        }
        let limited = String(sanitized.prefix(72))
        return "/tmp/\(limited).sock"
    }
}

enum SSHConnectionReusePolicy {
    static func shouldUseConnectionReuse(
        authMethod: AuthenticationMethod,
        hasStoredPassword: Bool
    ) -> Bool {
        authMethod != .password || !hasStoredPassword
    }
}
