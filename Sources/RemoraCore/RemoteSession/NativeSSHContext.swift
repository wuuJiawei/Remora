import Foundation
import RemoraSSHNative

enum NativeSSHContextError: Error, Equatable {
    case creationFailed(code: UInt32, backendCode: Int32, message: String)
    case closed
}

final class NativeSSHContext: @unchecked Sendable {
    static let expectedABIVersion: UInt32 = 4
    static var nativeABIVersion: UInt32 { remora_ssh_native_abi_version() }
    static var backendVersion: String { String(cString: remora_ssh_backend_version()) }
    static var cryptoBackend: String { String(cString: remora_ssh_crypto_backend()) }

    private var handle: OpaquePointer?

    init() throws {
        var newHandle: OpaquePointer?
        var nativeError = remora_ssh_error()
        let result = remora_ssh_context_create(&newHandle, &nativeError)
        guard result == REMORA_SSH_ERROR_NONE, let newHandle else {
            throw NativeSSHContextError.creationFailed(
                code: result.rawValue,
                backendCode: nativeError.backend_code,
                message: String(cString: remora_ssh_error_message(&nativeError))
            )
        }
        handle = newHandle
    }

    deinit {
        close()
    }

    var isOpen: Bool {
        guard let handle else { return false }
        return remora_ssh_context_is_valid(handle)
    }

    var isAuthenticated: Bool {
        guard let handle else { return false }
        return remora_ssh_context_is_authenticated(handle)
    }

    func close() {
        remora_ssh_context_destroy(&handle)
    }

    func requireOpen() throws {
        guard let handle, remora_ssh_context_is_valid(handle) else {
            throw NativeSSHContextError.closed
        }
    }

    func handshake(socketDescriptor: Int32) throws -> NativeSSHCallStatus {
        let handle = try requiredHandle()
        var nativeError = remora_ssh_error()
        let result = remora_ssh_context_handshake(handle, socketDescriptor, &nativeError)
        return try status(result, error: &nativeError, category: .session, code: "handshake_failed")
    }

    func hostKey() throws -> NativeSSHHostKey {
        let handle = try requiredHandle()
        var nativeError = remora_ssh_error()
        var nativeHostKey = remora_ssh_host_key()
        let result = remora_ssh_context_host_key(handle, &nativeHostKey, &nativeError)
        guard result == REMORA_SSH_ERROR_NONE else {
            throw operationError(
                result,
                error: &nativeError,
                category: .hostKey,
                code: "host_key_unavailable"
            )
        }
        let bytes = withUnsafeBytes(of: &nativeHostKey.sha256) { Data($0) }
        return NativeSSHHostKey(
            algorithm: Self.hostKeyAlgorithm(nativeHostKey.algorithm),
            sha256: bytes
        )
    }

    func authenticationMethods(username: String) throws -> (NativeSSHCallStatus, Set<NativeSSHAuthenticationMethod>) {
        let handle = try requiredHandle()
        var nativeError = remora_ssh_error()
        var length = 0
        var buffer = [CChar](repeating: 0, count: 1024)
        let result = username.withCString { usernamePointer in
            remora_ssh_context_authentication_methods(
                handle,
                usernamePointer,
                &buffer,
                buffer.count,
                &length,
                &nativeError
            )
        }
        let callStatus = try status(
            result,
            error: &nativeError,
            category: .authentication,
            code: "authentication_methods_failed"
        )
        guard case .complete = callStatus, length > 0 else {
            return (callStatus, [])
        }
        let methodString = String(decoding: buffer.prefix(length).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let methods = Set(
            methodString.split(separator: ",").compactMap {
                NativeSSHAuthenticationMethod(rawValue: String($0))
            }
        )
        return (callStatus, methods)
    }

    func authenticatePassword(username: String, password: String) throws -> NativeSSHCallStatus {
        let handle = try requiredHandle()
        var nativeError = remora_ssh_error()
        let result = username.withCString { usernamePointer in
            password.withCString { passwordPointer in
                remora_ssh_context_authenticate_password(
                    handle,
                    usernamePointer,
                    passwordPointer,
                    &nativeError
                )
            }
        }
        return try status(result, error: &nativeError, category: .authentication, code: "password_authentication_failed")
    }

    func authenticatePrivateKey(
        username: String,
        privateKey: NativeSSHPrivateKey
    ) throws -> NativeSSHCallStatus {
        let handle = try requiredHandle()
        var nativeError = remora_ssh_error()
        let result = username.withCString { usernamePointer in
            privateKey.privateKeyURL.path.withCString { privateKeyPointer in
                withOptionalCString(privateKey.publicKeyURL?.path) { publicKeyPointer in
                    withOptionalCString(privateKey.passphrase) { passphrasePointer in
                        remora_ssh_context_authenticate_private_key(
                            handle,
                            usernamePointer,
                            publicKeyPointer,
                            privateKeyPointer,
                            passphrasePointer,
                            &nativeError
                        )
                    }
                }
            }
        }
        return try status(result, error: &nativeError, category: .authentication, code: "private_key_authentication_failed")
    }

    func authenticateAgent(username: String) throws -> NativeSSHCallStatus {
        let handle = try requiredHandle()
        var nativeError = remora_ssh_error()
        let result = username.withCString { usernamePointer in
            remora_ssh_context_authenticate_agent(handle, usernamePointer, &nativeError)
        }
        return try status(result, error: &nativeError, category: .authentication, code: "agent_authentication_failed")
    }

    func authenticateKeyboardInteractive(
        username: String,
        bridge: KeyboardInteractiveBridge
    ) throws -> NativeSSHCallStatus {
        let handle = try requiredHandle()
        var nativeError = remora_ssh_error()
        let bridgePointer = Unmanaged.passUnretained(bridge).toOpaque()
        let result = username.withCString { usernamePointer in
            remora_ssh_context_authenticate_keyboard_interactive(
                handle,
                usernamePointer,
                nativeKeyboardChallengeHandler,
                bridgePointer,
                &nativeError
            )
        }
        return try status(
            result,
            error: &nativeError,
            category: .authentication,
            code: result == REMORA_SSH_ERROR_CHALLENGE_CANCELLED
                ? "authentication_challenge_cancelled"
                : "keyboard_interactive_authentication_failed"
        )
    }

    func createShell(pty: PTYSize, terminalType: String) throws -> NativeSSHChannelHandle {
        let handle = try requiredHandle()
        var channelHandle: OpaquePointer?
        var nativeError = remora_ssh_error()
        let result = terminalType.withCString { terminalPointer in
            remora_ssh_channel_create_shell(
                handle,
                terminalPointer,
                UInt32(clamping: pty.columns),
                UInt32(clamping: pty.rows),
                &channelHandle,
                &nativeError
            )
        }
        guard result == REMORA_SSH_ERROR_NONE, let channelHandle else {
            throw operationError(
                result,
                error: &nativeError,
                category: .channel,
                code: "shell_allocation_failed"
            )
        }
        return NativeSSHChannelHandle(handle: channelHandle, context: self)
    }

    func createExec(command: String) throws -> NativeSSHChannelHandle {
        let handle = try requiredHandle()
        var channelHandle: OpaquePointer?
        var nativeError = remora_ssh_error()
        let result = command.withCString { commandPointer in
            remora_ssh_channel_create_exec(
                handle,
                commandPointer,
                &channelHandle,
                &nativeError
            )
        }
        guard result == REMORA_SSH_ERROR_NONE, let channelHandle else {
            throw operationError(
                result,
                error: &nativeError,
                category: .command,
                code: "command_allocation_failed"
            )
        }
        return NativeSSHChannelHandle(handle: channelHandle, context: self)
    }

    func createDirectTCPIP(
        destinationHost: String,
        destinationPort: UInt16,
        sourceHost: String,
        sourcePort: UInt16
    ) throws -> NativeSSHChannelHandle {
        let handle = try requiredHandle()
        var channelHandle: OpaquePointer?
        var nativeError = remora_ssh_error()
        let result = destinationHost.withCString { destinationPointer in
            sourceHost.withCString { sourcePointer in
                remora_ssh_channel_create_direct_tcpip(
                    handle,
                    destinationPointer,
                    destinationPort,
                    sourcePointer,
                    sourcePort,
                    &channelHandle,
                    &nativeError
                )
            }
        }
        guard result == REMORA_SSH_ERROR_NONE, let channelHandle else {
            throw operationError(
                result,
                error: &nativeError,
                category: .channel,
                code: "direct_tcpip_allocation_failed"
            )
        }
        return NativeSSHChannelHandle(handle: channelHandle, context: self)
    }

    func createSFTP() throws -> NativeSFTPSessionHandle {
        let handle = try requiredHandle()
        var sftpHandle: OpaquePointer?
        var nativeError = remora_ssh_error()
        let result = remora_ssh_sftp_create(handle, &sftpHandle, &nativeError)
        guard result == REMORA_SSH_ERROR_NONE, let sftpHandle else {
            throw operationError(
                result,
                error: &nativeError,
                category: .fileSystem,
                code: "sftp_allocation_failed"
            )
        }
        return NativeSFTPSessionHandle(handle: sftpHandle, context: self)
    }

    func blockDirections() -> NativeSocketDirections {
        guard let handle else { return .both }
        let rawValue = remora_ssh_context_block_directions(handle)
        let directions = NativeSocketDirections(rawValue: rawValue)
        return directions.isEmpty ? .both : directions
    }

    private func requiredHandle() throws -> OpaquePointer {
        guard let handle, remora_ssh_context_is_valid(handle) else {
            throw NativeSSHContextError.closed
        }
        return handle
    }

    private func status(
        _ result: remora_ssh_error_code,
        error: inout remora_ssh_error,
        category: RemoteErrorCategory,
        code: String
    ) throws -> NativeSSHCallStatus {
        switch result {
        case REMORA_SSH_ERROR_NONE:
            return .complete
        case REMORA_SSH_ERROR_WOULD_BLOCK:
            return .wouldBlock(blockDirections())
        default:
            throw operationError(result, error: &error, category: category, code: code)
        }
    }

    private func operationError(
        _ result: remora_ssh_error_code,
        error: inout remora_ssh_error,
        category: RemoteErrorCategory,
        code: String
    ) -> RemoteOperationError {
        RemoteOperationError(
            category: category,
            code: code,
            safeDiagnosticMessage: String(cString: remora_ssh_error_message(&error)),
            backendCode: result == REMORA_SSH_ERROR_NONE ? nil : Int(error.backend_code)
        )
    }

    private static func hostKeyAlgorithm(
        _ algorithm: remora_ssh_host_key_algorithm
    ) -> NativeSSHHostKeyAlgorithm {
        switch algorithm {
        case REMORA_SSH_HOST_KEY_RSA: .rsa
        case REMORA_SSH_HOST_KEY_DSS: .dss
        case REMORA_SSH_HOST_KEY_ECDSA_256: .ecdsa256
        case REMORA_SSH_HOST_KEY_ECDSA_384: .ecdsa384
        case REMORA_SSH_HOST_KEY_ECDSA_521: .ecdsa521
        case REMORA_SSH_HOST_KEY_ED25519: .ed25519
        default: .unknown
        }
    }
}

private func withOptionalCString<Result>(
    _ value: String?,
    _ body: (UnsafePointer<CChar>?) throws -> Result
) rethrows -> Result {
    guard let value else { return try body(nil) }
    return try value.withCString(body)
}
