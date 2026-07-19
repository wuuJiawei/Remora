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
        let identity = "\(host.id.uuidString)|\(host.username)|\(host.address)|\(host.port)|\(purpose.rawValue)"
        let digest = stableDigest(identity)
        return "/tmp/remora-\(host.id.uuidString.prefix(8))-\(purpose.rawValue)-\(digest).sock"
    }

    private static func stableDigest(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
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
