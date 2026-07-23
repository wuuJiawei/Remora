import Foundation

public struct AdministratorSFTPServerResolver: Sendable {
    public static let defaultAllowedPaths = [
        "/usr/lib/openssh/sftp-server",
        "/usr/lib/ssh/sftp-server",
        "/usr/libexec/openssh/sftp-server",
        "/usr/libexec/sftp-server",
    ]

    private let candidatePaths: [String]

    public init(
        configuredPath: String? = nil,
        allowedPaths: [String] = AdministratorSFTPServerResolver.defaultAllowedPaths
    ) throws {
        let candidates = ([configuredPath].compactMap { $0 } + allowedPaths)
            .filter { !$0.isEmpty }
        guard candidates.allSatisfy(Self.isAbsoluteNormalizedPath) else {
            throw RemoteOperationError(
                category: .fileSystem,
                code: "administrator_sftp_server_path_invalid",
                safeDiagnosticMessage: "Administrator SFTP server paths must be absolute and normalized"
            )
        }
        var seen = Set<String>()
        candidatePaths = candidates.filter { seen.insert($0).inserted }
    }

    public func resolve(using executor: any RemoteCommandExecutorProtocol) async throws -> String {
        for path in candidatePaths {
            let result = try await executor.execute(
                RemoteCommandRequest(
                    executable: .shell("[ -x \(POSIXCommandBuilder.quote(path)) ]"),
                    replayPolicy: .readOnly,
                    timeout: .seconds(5)
                )
            )
            if result.exitStatus == 0 {
                return path
            }
        }
        throw RemoteOperationError(
            category: .fileSystem,
            code: "administrator_sftp_server_unavailable",
            safeDiagnosticMessage: "No supported SFTP server executable was found on the remote host"
        )
    }

    private static func isAbsoluteNormalizedPath(_ path: String) -> Bool {
        guard path.hasPrefix("/"), !path.contains("\0") else { return false }
        return URL(fileURLWithPath: path).standardized.path == path
    }
}
