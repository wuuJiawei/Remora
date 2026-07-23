import Foundation

public actor PersistentHostKeyStoreProvider {
    public static let shared = PersistentHostKeyStoreProvider()

    private var cachedStore: HostKeyStore?

    public init() {}

    public func store() throws -> HostKeyStore {
        if let cachedStore { return cachedStore }
        do {
            let store = try HostKeyStore.persistent()
            cachedStore = store
            return store
        } catch {
            throw RemoteOperationError(
                category: .hostKey,
                code: "host_key_store_unavailable",
                safeDiagnosticMessage: "Persistent SSH host key storage is unavailable"
            )
        }
    }
}

public struct NativeDirectSessionConnector: Sendable {
    public typealias DiagnosticHandler = @Sendable (NativeSSHDiagnosticEvent) -> Void

    private let credentialStore: CredentialStore
    private let hostKeyStoreProvider: PersistentHostKeyStoreProvider
    private let interactionBroker: NativeSessionInteractionBroker
    private let routeResolver: HostConnectionRouteResolver
    private let diagnosticHandler: DiagnosticHandler?

    public init(
        credentialStore: CredentialStore = CredentialStore(),
        hostKeyStoreProvider: PersistentHostKeyStoreProvider = .shared,
        interactionBroker: NativeSessionInteractionBroker,
        routeResolver: HostConnectionRouteResolver = HostConnectionRouteResolver(),
        diagnosticHandler: DiagnosticHandler? = nil
    ) {
        self.credentialStore = credentialStore
        self.hostKeyStoreProvider = hostKeyStoreProvider
        self.interactionBroker = interactionBroker
        self.routeResolver = routeResolver
        self.diagnosticHandler = diagnosticHandler
    }

    public func request(for host: Host) throws -> RemoteSessionAcquisitionRequest {
        let resolvedRoute = try routeResolver.resolve(host: host)
        let key = Self.sessionKey(for: host, resolvedRoute: resolvedRoute)
        return RemoteSessionAcquisitionRequest(key: key) {
            let store = try await hostKeyStoreProvider.store()
            let verifier = HostKeyVerifier(store: store) { request in
                await interactionBroker.requestHostKeyDecision(for: request)
            }
            let authentication = try await authentication(for: host, route: resolvedRoute.route)
            let transport = LibSSH2Transport(hostKeyVerifier: verifier)

            if let diagnosticHandler {
                Task {
                    for await event in await transport.diagnostics() {
                        diagnosticHandler(event)
                    }
                }
            }

            do {
                try await transport.connect(
                    configuration: NativeSSHConnectionConfiguration(
                        endpoint: key.route.endpoint,
                        username: key.route.transportUsername,
                        authentication: authentication,
                        connectTimeout: .seconds(max(1, host.policies.connectTimeoutSeconds))
                    )
                )
                let session = RemoteSession(key: key, transport: transport)
                if let executor = try? await session.commandExecutor() {
                    do {
                        try await RemoteShellIntegrationInstaller.shared.ensureInstalled(using: executor)
                        await transport.recordDiagnostic(
                            operation: "shell_integration_install",
                            message: "completed"
                        )
                    } catch {
                        let operationError = error as? RemoteOperationError
                        await transport.recordDiagnostic(
                            operation: "shell_integration_install",
                            message: "skipped code=\(operationError?.code ?? "unknown")",
                            backendCode: operationError?.backendCode
                        )
                    }
                }
                return session
            } catch {
                await transport.close()
                throw error
            }
        }
    }

    private func authentication(
        for host: Host,
        route: ConnectionRoute
    ) async throws -> NativeSSHAuthentication {
        if case .gateway(let gatewayRoute) = route,
           gatewayRoute.providerID == JumpServerGatewayProvider.identifier,
           host.auth.method != .password
        {
            throw RemoteOperationError(
                category: .authentication,
                code: "jumpserver_authentication_unsupported",
                safeDiagnosticMessage: "JumpServer routes currently require password authentication"
            )
        }

        switch host.auth.method {
        case .agent:
            return .agent
        case .privateKey:
            guard let path = normalized(host.auth.keyReference) else {
                throw RemoteOperationError(
                    category: .authentication,
                    code: "private_key_missing",
                    safeDiagnosticMessage: "Private key authentication requires a key file"
                )
            }
            let privateKeyURL = URL(fileURLWithPath: path)
            let requiresPassphrase = try await Task.detached(priority: .utility) {
                try NativePrivateKeyInspector.requiresPassphrase(at: privateKeyURL)
            }.value
            let passphrase = requiresPassphrase
                ? try await interactionBroker.requestCredential(kind: .privateKeyPassphrase)
                : nil
            return .privateKey(
                NativeSSHPrivateKey(
                    privateKeyURL: privateKeyURL,
                    passphrase: passphrase
                )
            )
        case .password:
            let password = try await password(for: host)
            let coordinator = AuthenticationCoordinator { prompts in
                guard prompts.count == 1,
                      !prompts[0].echo,
                      prompts[0].text.localizedCaseInsensitiveContains("password")
                else {
                    return nil
                }
                return [password]
            }
            interactionBroker.observeKeyboardInteractive(coordinator)
            return .passwordOrKeyboardInteractive(password: password, coordinator: coordinator)
        }
    }

    private func password(for host: Host) async throws -> String {
        if let reference = normalized(host.auth.passwordReference),
           let password = await credentialStore.secret(for: reference),
           !password.isEmpty
        {
            return password
        }
        let password = try await interactionBroker.requestCredential(kind: .password)
        guard !password.isEmpty else {
            throw RemoteOperationError(
                category: .authentication,
                code: "password_empty",
                safeDiagnosticMessage: "Password authentication requires a non-empty password"
            )
        }
        return password
    }

    private static func sessionKey(
        for host: Host,
        resolvedRoute: ResolvedHostConnectionRoute
    ) -> RemoteSessionKey {
        let credentialReference: String? = switch host.auth.method {
        case .agent:
            nil
        case .privateKey:
            normalized(host.auth.keyReference)
        case .password:
            normalized(host.auth.passwordReference)
        }
        return RemoteSessionKey(
            route: resolvedRoute.route,
            target: resolvedRoute.target,
            authenticationIdentity: RemoteAuthenticationIdentity(
                username: resolvedRoute.route.transportUsername,
                method: host.auth.method,
                credentialReference: credentialReference
            ),
            hostKeyPolicyID: "persistent-strict-v1"
        )
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func normalized(_ value: String?) -> String? {
        Self.normalized(value)
    }
}

private enum NativePrivateKeyInspector {
    private static let maximumKeyBytes = 16 * 1_024 * 1_024
    private static let openSSHMagic = Data("openssh-key-v1\0".utf8)

    static func requiresPassphrase(at url: URL) throws -> Bool {
        let resourceValues = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard resourceValues.isRegularFile == true,
              let fileSize = resourceValues.fileSize,
              fileSize > 0,
              fileSize <= maximumKeyBytes
        else {
            throw RemoteOperationError(
                category: .authentication,
                code: "private_key_invalid",
                safeDiagnosticMessage: "Private key file is missing, empty, or exceeds the size limit"
            )
        }

        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard let text = String(data: data, encoding: .utf8) else { return false }
        if text.contains("BEGIN ENCRYPTED PRIVATE KEY")
            || text.contains("Proc-Type: 4,ENCRYPTED")
            || text.contains("DEK-Info:")
        {
            return true
        }
        guard text.contains("BEGIN OPENSSH PRIVATE KEY") else { return false }

        let encoded = text
            .split(whereSeparator: \.isNewline)
            .filter { !$0.hasPrefix("-----") }
            .joined()
        guard let decoded = Data(base64Encoded: encoded),
              decoded.starts(with: openSSHMagic),
              let cipher = readSSHString(decoded, offset: openSSHMagic.count)
        else {
            throw RemoteOperationError(
                category: .authentication,
                code: "private_key_invalid",
                safeDiagnosticMessage: "OpenSSH private key metadata is invalid"
            )
        }
        return cipher != "none"
    }

    private static func readSSHString(_ data: Data, offset: Int) -> String? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        let length = data[offset ..< offset + 4].reduce(UInt32(0)) { value, byte in
            (value << 8) | UInt32(byte)
        }
        let (end, overflow) = offset.addingReportingOverflow(4 + Int(length))
        guard !overflow, end <= data.count else { return nil }
        return String(data: data[offset + 4 ..< end], encoding: .utf8)
    }
}
