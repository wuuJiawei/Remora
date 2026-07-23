import Foundation
import Testing
@testable import RemoraCore

@Suite("Administrator SFTP filesystem")
struct ExecSFTPRemoteFileSystemTests {
    @Test("Handshake rejects SFTP versions other than v3")
    func handshakeRejectsVersionMismatch() async {
        let execution = ScriptedSFTPExecution(startup: .version(4))

        await #expect(throws: SFTPWireError.invalidVersion(4)) {
            _ = try await ExecSFTPRemoteFileSystem.open(execution: execution)
        }
    }

    @Test("Stderr and exit before VERSION surface a privilege error")
    func startupFailureIncludesSudoDiagnostic() async {
        let execution = ScriptedSFTPExecution(
            startup: .exit(stderr: "sudo: a password is required", status: 1)
        )

        do {
            _ = try await ExecSFTPRemoteFileSystem.open(execution: execution)
            Issue.record("Expected administrator SFTP startup to fail")
        } catch let error as RemoteOperationError {
            #expect(error.category == .privilege)
            #expect(error.code == "administrator_sftp_start_failed")
            #expect(error.safeDiagnosticMessage.contains("password is required"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Unexpected STATUS OK is a malformed data response")
    func statusOKForAttributesIsMalformed() async throws {
        let execution = ScriptedSFTPExecution(statusOKForStat: true)
        let fileSystem = try await ExecSFTPRemoteFileSystem.open(execution: execution)
        defer { Task { await fileSystem.close() } }

        do {
            _ = try await fileSystem.attributes(path: "/tmp/item", followSymbolicLinks: true)
            Issue.record("Expected malformed STATUS OK response")
        } catch let error as RemoteFileSystemOperationError {
            #expect(error.status == .malformedResponse)
            #expect(error.backendCode == Int(SFTPStatusCode.ok.rawValue))
        }
    }

    @Test("File reads and writes stay inside the 64 KiB wire budget")
    func fileIOIsBounded() async throws {
        let execution = ScriptedSFTPExecution()
        let fileSystem = try await ExecSFTPRemoteFileSystem.open(execution: execution)
        let readHandle = try await fileSystem.openFile(
            path: "/tmp/read",
            options: [.read],
            attributes: nil
        )
        let data = try await readHandle.read(maximumBytes: 1_024 * 1_024)
        #expect(data.count == 8)
        await readHandle.close()

        let writeHandle = try await fileSystem.openFile(
            path: "/tmp/write",
            options: [.write, .create, .truncate],
            attributes: nil
        )
        let written = try await writeHandle.write(Data(repeating: 0x5A, count: 128 * 1_024))
        #expect(written == 64 * 1_024)
        await writeHandle.close()
        await fileSystem.close()

        #expect(await execution.maximumRequestedReadSize == 64 * 1_024)
        #expect(await execution.maximumReceivedWriteSize == 64 * 1_024)
    }

    @Test("OpenSSH symlink request sends target before link path")
    func symlinkUsesOpenSSHArgumentOrder() async throws {
        let execution = ScriptedSFTPExecution()
        let fileSystem = try await ExecSFTPRemoteFileSystem.open(execution: execution)

        try await fileSystem.createSymbolicLink(path: "/tmp/link", target: "../target")
        #expect(await execution.lastSymlinkArguments == ["../target", "/tmp/link"])
        await fileSystem.close()
    }

    @Test("Protocol failure unregisters exactly once")
    func protocolFailureUnregistersExactlyOnce() async {
        let execution = ScriptedSFTPExecution(startup: .version(4))
        let recorder = CloseRecorder()

        await #expect(throws: SFTPWireError.invalidVersion(4)) {
            _ = try await ExecSFTPRemoteFileSystem.open(execution: execution) { id in
                await recorder.record(id)
            }
        }
        #expect(await recorder.count == 1)
    }
}

private actor CloseRecorder {
    private(set) var identifiers: [UUID] = []
    var count: Int { identifiers.count }

    func record(_ id: UUID) {
        identifiers.append(id)
    }
}

private actor ScriptedSFTPExecution: SFTPCommandExecution {
    enum Startup: Sendable {
        case version(UInt32)
        case exit(stderr: String, status: Int32)
    }

    nonisolated let id = UUID()

    private let startup: Startup
    private let statusOKForStat: Bool
    private let stream: AsyncThrowingStream<RemoteCommandEvent, Error>
    private let continuation: AsyncThrowingStream<RemoteCommandEvent, Error>.Continuation
    private var decoder = SFTPCodec()
    private(set) var maximumRequestedReadSize = 0
    private(set) var maximumReceivedWriteSize = 0
    private(set) var lastSymlinkArguments: [String] = []
    private var isCancelled = false

    init(startup: Startup = .version(3), statusOKForStat: Bool = false) {
        self.startup = startup
        self.statusOKForStat = statusOKForStat
        let pair = AsyncThrowingStream<RemoteCommandEvent, Error>.makeStream(
            bufferingPolicy: .bufferingOldest(64)
        )
        stream = pair.stream
        continuation = pair.continuation
    }

    func start() async throws { }

    func events() async -> AsyncThrowingStream<RemoteCommandEvent, Error> {
        stream
    }

    func writeStandardInput(_ data: Data) async throws {
        guard !isCancelled else { throw CancellationError() }
        for packet in try decoder.append(data) {
            if packet.type == SFTPMessageType.initialize.rawValue {
                try sendStartupResponse()
            } else {
                try sendResponse(to: packet)
            }
        }
    }

    func finishStandardInput() async throws { }

    func cancel() async {
        guard !isCancelled else { return }
        isCancelled = true
        continuation.finish()
    }

    private func sendStartupResponse() throws {
        switch startup {
        case .version(let version):
            var payload = SFTPDataWriter()
            payload.appendUInt32(version)
            payload.appendString("posix-rename@openssh.com")
            payload.appendString("1")
            try send(.version, payload: payload.data)
        case .exit(let stderr, let status):
            continuation.yield(.standardError(Data(stderr.utf8)))
            continuation.yield(.exitStatus(status))
        }
    }

    private func sendResponse(to packet: SFTPPacket) throws {
        var reader = SFTPDataReader(
            data: packet.payload,
            maximumStringLength: SFTPCodec.defaultMaximumStringLength,
            maximumExtendedAttributeCount: SFTPCodec.defaultMaximumExtendedAttributeCount
        )
        let requestID = try reader.readUInt32()
        guard let type = SFTPMessageType(rawValue: packet.type) else {
            try sendStatus(id: requestID, code: .operationUnsupported)
            return
        }

        switch type {
        case .open:
            try sendHandle(id: requestID)
        case .read:
            _ = try reader.readDataString()
            _ = try reader.readUInt64()
            let requestedSize = Int(try reader.readUInt32())
            maximumRequestedReadSize = max(maximumRequestedReadSize, requestedSize)
            var payload = SFTPDataWriter()
            payload.appendUInt32(requestID)
            payload.appendDataString(Data(repeating: 0x41, count: min(requestedSize, 8)))
            try send(.data, payload: payload.data)
        case .write:
            _ = try reader.readDataString()
            _ = try reader.readUInt64()
            let payload = try reader.readDataString()
            maximumReceivedWriteSize = max(maximumReceivedWriteSize, payload.count)
            try sendStatus(id: requestID, code: .ok)
        case .close, .mkdir, .remove, .rmdir, .rename, .setstat, .extended:
            try sendStatus(id: requestID, code: .ok)
        case .stat, .lstat:
            if statusOKForStat {
                try sendStatus(id: requestID, code: .ok)
            } else {
                var payload = SFTPDataWriter()
                payload.appendUInt32(requestID)
                payload.appendAttributes(SFTPFileAttributes(size: 8, permissions: 0o100644))
                try send(.attrs, payload: payload.data)
            }
        case .symlink:
            lastSymlinkArguments = [try reader.readString(), try reader.readString()]
            try sendStatus(id: requestID, code: .ok)
        default:
            try sendStatus(id: requestID, code: .operationUnsupported)
        }
    }

    private func sendHandle(id: UInt32) throws {
        var payload = SFTPDataWriter()
        payload.appendUInt32(id)
        payload.appendDataString(Data("handle".utf8))
        try send(.handle, payload: payload.data)
    }

    private func sendStatus(id: UInt32, code: SFTPStatusCode) throws {
        var payload = SFTPDataWriter()
        payload.appendUInt32(id)
        payload.appendUInt32(code.rawValue)
        payload.appendString("")
        payload.appendString("")
        try send(.status, payload: payload.data)
    }

    private func send(_ type: SFTPMessageType, payload: Data) throws {
        continuation.yield(.standardOutput(try SFTPCodec.encode(SFTPPacket(type: type, payload: payload))))
    }
}
