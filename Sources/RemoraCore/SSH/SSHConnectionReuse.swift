import Foundation

enum SSHConnectionReuse {
    static func masterOptions(for host: Host) -> [String] {
        [
            "-o", "ControlMaster=auto",
            "-o", "ControlPersist=600",
            "-o", "ControlPath=\(controlPath(for: host))",
        ]
    }

    static func reuseOnlyOptions(for host: Host) -> [String] {
        [
            "-o", "ControlMaster=no",
            "-o", "ControlPath=\(controlPath(for: host))",
        ]
    }

    static func controlPath(for host: Host) -> String {
        let raw = "remora-\(host.username)-\(host.address)-\(host.port)"
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
