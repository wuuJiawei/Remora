import Foundation
import Testing
@testable import RemoraCore

@Suite("Administrator SFTP server resolver")
struct AdministratorSFTPServerResolverTests {
    @Test("Candidate paths must be absolute and normalized")
    func candidatePathsMustBeSafe() {
        #expect(throws: RemoteOperationError.self) {
            _ = try AdministratorSFTPServerResolver(configuredPath: "usr/lib/sftp-server")
        }
        #expect(throws: RemoteOperationError.self) {
            _ = try AdministratorSFTPServerResolver(configuredPath: "/usr/lib/../bin/sftp-server")
        }
    }

    @Test("Configured path is checked first and duplicate candidates are removed")
    func candidateOrderIsStableAndDeduplicated() async throws {
        let executor = ResolverCommandExecutor(executablePaths: ["/fallback/sftp-server"])
        let resolver = try AdministratorSFTPServerResolver(
            configuredPath: "/custom/sftp-server",
            allowedPaths: ["/custom/sftp-server", "/fallback/sftp-server"]
        )

        #expect(try await resolver.resolve(using: executor) == "/fallback/sftp-server")
        #expect(await executor.checkedPaths == [
            "/custom/sftp-server",
            "/fallback/sftp-server",
        ])
    }

    @Test("Missing server returns a typed capability error")
    func missingServerReturnsTypedError() async throws {
        let executor = ResolverCommandExecutor(executablePaths: [])
        let resolver = try AdministratorSFTPServerResolver(allowedPaths: ["/missing/sftp-server"])

        do {
            _ = try await resolver.resolve(using: executor)
            Issue.record("Expected resolver failure")
        } catch let error as RemoteOperationError {
            #expect(error.code == "administrator_sftp_server_unavailable")
        }
    }
}

private actor ResolverCommandExecutor: RemoteCommandExecutorProtocol {
    private let executablePaths: Set<String>
    private(set) var checkedPaths: [String] = []

    init(executablePaths: Set<String>) {
        self.executablePaths = executablePaths
    }

    func start(_ request: RemoteCommandRequest) async throws -> any RemoteCommandExecutionProtocol {
        _ = request
        throw RemoteOperationError(
            category: .command,
            code: "fixture_stream_unavailable",
            safeDiagnosticMessage: "Resolver fixture does not stream commands"
        )
    }

    func execute(_ request: RemoteCommandRequest) async throws -> RemoteCommandResult {
        guard case .shell(let script) = request.executable,
              let path = Self.path(from: script)
        else {
            throw RemoteOperationError(
                category: .command,
                code: "fixture_command_invalid",
                safeDiagnosticMessage: "Resolver fixture received an unexpected command"
            )
        }
        checkedPaths.append(path)
        return RemoteCommandResult(
            exitStatus: executablePaths.contains(path) ? 0 : 1,
            standardOutput: Data(),
            standardError: Data()
        )
    }

    private static func path(from script: String) -> String? {
        guard script.hasPrefix("[ -x '"), script.hasSuffix("' ]") else { return nil }
        return String(script.dropFirst(6).dropLast(3))
            .replacingOccurrences(of: "'\\''", with: "'")
    }
}
