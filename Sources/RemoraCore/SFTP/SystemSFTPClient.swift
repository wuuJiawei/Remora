import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public actor SystemSFTPClient: SFTPClientProtocol {
    private struct ProcessResult {
        var status: Int32
        var stdout: Data
        var stderr: Data
    }

    private enum OutputLogMode {
        case text
        case metadataOnly
    }

    private enum InputLogMode {
        case text
        case metadataOnly
    }

    private struct BatchLaunchConfiguration {
        var executablePath: String
        var arguments: [String]
        var environment: [String: String]
        var usesConnectionReuse: Bool
    }

    private let host: Host
    private let credentialStore = CredentialStore()
    private let directoryOperationTimeout: TimeInterval
    private let shellFallbackTimeout: TimeInterval
    private var prefersSSHStreamingDownload = false
    private var prefersSSHStreamingUpload = false

    private static let diagnosticsQueue = DispatchQueue(label: "io.lighting-tech.remora.sftp-diagnostics")
    private static let diagnosticsLogMaxBytes: Int64 = 10 * 1024 * 1024
    private static let diagnosticsRetentionDays: Int = 14
    private static let diagnosticsLogURL: URL = {
        let fm = FileManager.default
        let baseDirectory = fm.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("Remora", isDirectory: true)
            ?? fm.temporaryDirectory.appendingPathComponent("Remora", isDirectory: true)
        try? fm.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        return baseDirectory.appendingPathComponent("sftp-diagnostics.log")
    }()

    public init(host: Host) {
        self.host = host
        self.directoryOperationTimeout = TimeInterval(min(10, max(5, host.policies.connectTimeoutSeconds)))
        self.shellFallbackTimeout = TimeInterval(min(6, max(4, host.policies.connectTimeoutSeconds / 2)))
    }

    public func list(path: String) async throws -> [RemoteFileEntry] {
        let normalized = normalize(path)
        do {
            let output = try await runSFTPBatch(
                commands: ["ls -lan \(Self.quoteBatchArgument(normalized))"],
                timeout: directoryOperationTimeout
            )
            let parsedLongEntries = Self.parseLongListOutput(output, parentPath: normalized)
            if !parsedLongEntries.isEmpty {
                return parsedLongEntries
            }

            // Some servers return a non-long listing even when -l is requested.
            if let sshFallback = try? await listViaSSH(path: normalized, timeout: shellFallbackTimeout), !sshFallback.isEmpty {
                return sshFallback
            }

            let parsedNameEntries = Self.parseNameOnlyListOutput(output, parentPath: normalized)
            if !parsedNameEntries.isEmpty {
                return parsedNameEntries
            }

            return []
        } catch {
            // Some servers disable SFTP subsystem while SSH shell stays available.
            if let sshFallback = try? await listViaSSH(path: normalized, timeout: shellFallbackTimeout), !sshFallback.isEmpty {
                return sshFallback
            }
            throw error
        }
    }

    public func download(path: String) async throws -> Data {
        let normalized = normalize(path)
        if prefersSSHStreamingDownload {
            return try await downloadViaSSH(path: normalized)
        }

        do {
            return try await downloadViaSFTP(path: normalized)
        } catch {
            guard Self.shouldSwitchToSSHStreamingTransfer(for: error) else {
                throw error
            }
            prefersSSHStreamingDownload = true
            Self.appendDiagnostics(
                Self.formatDiagnosticsMessage(
                    host: host,
                    phase: "download-mode-switch",
                    body: [
                        "reason=\(error.localizedDescription)",
                        "mode=ssh-streaming"
                    ]
                )
            )
            return try await downloadViaSSH(path: normalized)
        }
    }

    public func download(path: String, progress: TransferProgressHandler?) async throws -> Data {
        let normalized = normalize(path)
        let expectedSize = try? await stat(path: normalized).size
        progress?(.init(bytesTransferred: 0, totalBytes: expectedSize))
        let payload = try await download(path: normalized)
        progress?(.init(bytesTransferred: Int64(payload.count), totalBytes: expectedSize ?? Int64(payload.count)))
        return payload
    }

    public func download(path: String, to localFileURL: URL, progress: TransferProgressHandler?) async throws {
        let normalized = normalize(path)
        let expectedSize = try? await stat(path: normalized).size
        progress?(.init(bytesTransferred: 0, totalBytes: expectedSize))

        let prepared = try prepareDownloadDestination(localFileURL)
        defer { try? FileManager.default.removeItem(at: prepared.tempURL) }

        if prefersSSHStreamingDownload {
            try await downloadViaSSH(path: normalized, to: prepared.tempURL)
        } else {
            do {
                try await downloadViaSFTP(path: normalized, to: prepared.tempURL)
            } catch {
                guard Self.shouldSwitchToSSHStreamingTransfer(for: error) else {
                    throw error
                }
                prefersSSHStreamingDownload = true
                Self.appendDiagnostics(
                    Self.formatDiagnosticsMessage(
                        host: host,
                        phase: "download-mode-switch",
                        body: [
                            "reason=\(error.localizedDescription)",
                            "mode=ssh-streaming"
                        ]
                    )
                )
                try await downloadViaSSH(path: normalized, to: prepared.tempURL)
            }
        }

        try finalizeDownloadedFile(tempURL: prepared.tempURL, destinationURL: prepared.destinationURL)
        let transferredBytes = expectedSize
            ?? (try? prepared.destinationURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
            ?? 0
        progress?(.init(bytesTransferred: transferredBytes, totalBytes: expectedSize ?? transferredBytes))
    }

    public func upload(data: Data, to path: String) async throws {
        let tempURL = makeTemporaryURL(prefix: "remora-sftp-upload")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        try data.write(to: tempURL, options: .atomic)
        try await upload(fileURL: tempURL, to: path, progress: nil)
    }

    public func upload(data: Data, to path: String, progress: TransferProgressHandler?) async throws {
        let totalBytes = Int64(data.count)
        progress?(.init(bytesTransferred: 0, totalBytes: totalBytes))
        try await upload(data: data, to: path)
        progress?(.init(bytesTransferred: totalBytes, totalBytes: totalBytes))
    }

    public func upload(fileURL: URL, to path: String, progress: TransferProgressHandler?) async throws {
        let normalized = normalize(path)
        let totalBytes = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
        progress?(.init(bytesTransferred: 0, totalBytes: totalBytes))

        if prefersSSHStreamingUpload {
            try await uploadViaSSH(fileURL: fileURL, to: normalized)
            progress?(.init(bytesTransferred: totalBytes ?? 0, totalBytes: totalBytes))
            return
        }

        do {
            try await uploadViaSFTP(fileURL: fileURL, to: normalized)
        } catch {
            guard Self.shouldSwitchToSSHStreamingTransfer(for: error) else {
                throw error
            }
            prefersSSHStreamingUpload = true
            Self.appendDiagnostics(
                Self.formatDiagnosticsMessage(
                    host: host,
                    phase: "upload-mode-switch",
                    body: [
                        "reason=\(error.localizedDescription)",
                        "mode=ssh-streaming"
                    ]
                )
            )
            try await uploadViaSSH(fileURL: fileURL, to: normalized)
        }

        progress?(.init(bytesTransferred: totalBytes ?? 0, totalBytes: totalBytes))
    }

    public func rename(from: String, to: String) async throws {
        let source = normalize(from)
        let destination = normalize(to)
        let fallbackCommand = "mv -- \(Self.quoteShellArgument(source)) \(Self.quoteShellArgument(destination))"
        try await executeSFTPPrimaryWithSSHFallback(
            sftpOperation: {
                _ = try await runSFTPBatch(
                    commands: [
                        "rename \(Self.quoteBatchArgument(source)) \(Self.quoteBatchArgument(destination))",
                    ]
                )
            },
            sshFallback: {
                try await runSSHCommand(fallbackCommand)
            }
        )
    }

    public func move(from: String, to: String) async throws {
        try await rename(from: from, to: to)
    }

    public func copy(from: String, to: String) async throws {
        let source = normalize(from)
        let destination = normalize(to)
        let command = "cp -R -- \(Self.quoteShellArgument(source)) \(Self.quoteShellArgument(destination))"
        try await runSSHCommand(command)
    }

    public func mkdir(path: String) async throws {
        let normalized = normalize(path)
        let fallbackCommand = "mkdir -p -- \(Self.quoteShellArgument(normalized))"
        try await executeSFTPPrimaryWithSSHFallback(
            sftpOperation: {
                _ = try await runSFTPBatch(commands: ["mkdir \(Self.quoteBatchArgument(normalized))"])
            },
            sshFallback: {
                try await runSSHCommand(fallbackCommand)
            }
        )
    }

    public func remove(path: String) async throws {
        let normalized = normalize(path)
        let attributes = try await stat(path: normalized)
        let command: String
        if attributes.isDirectory == true {
            command = "rm -rf -- \(Self.quoteShellArgument(normalized))"
        } else {
            command = "rm -f -- \(Self.quoteShellArgument(normalized))"
        }
        try await runSSHCommand(command)
    }

    public func stat(path: String) async throws -> RemoteFileAttributes {
        let normalized = normalize(path)
        let output = try await executeSFTPPrimaryWithSSHFallback(
            sftpOperation: {
                try await runSFTPBatch(
                    commands: ["ls -ldn \(Self.quoteBatchArgument(normalized))"],
                    timeout: directoryOperationTimeout
                )
            },
            sshFallback: {
                let command = "LC_ALL=C ls -ldn -- \(Self.quoteShellArgument(normalized))"
                return try await runSSHCommandOutput(command, timeout: shellFallbackTimeout)
            }
        )
        guard let parsed = Self.parseLongListEntries(output).first else {
            throw SFTPClientError.notFound(normalized)
        }
        return RemoteFileAttributes(
            permissions: parsed.permissions,
            owner: parsed.owner,
            group: parsed.group,
            size: parsed.size,
            modifiedAt: parsed.modifiedAt,
            isDirectory: parsed.isDirectory
        )
    }

    public func setAttributes(path: String, attributes: RemoteFileAttributes) async throws {
        let normalized = normalize(path)
        var sftpCommands: [String] = []
        var sshCommands: [String] = []

        if let permissions = attributes.permissions {
            let permissionText = String(permissions, radix: 8)
            sftpCommands.append("chmod \(permissionText) \(Self.quoteBatchArgument(normalized))")
            sshCommands.append("chmod \(permissionText) -- \(Self.quoteShellArgument(normalized))")
        }
        if let owner = attributes.owner, !owner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sftpCommands.append("chown \(Self.quoteBatchArgument(owner)) \(Self.quoteBatchArgument(normalized))")
            sshCommands.append("chown \(Self.quoteShellArgument(owner)) -- \(Self.quoteShellArgument(normalized))")
        }
        if let group = attributes.group, !group.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sftpCommands.append("chgrp \(Self.quoteBatchArgument(group)) \(Self.quoteBatchArgument(normalized))")
            sshCommands.append("chgrp \(Self.quoteShellArgument(group)) -- \(Self.quoteShellArgument(normalized))")
        }

        if !sftpCommands.isEmpty {
            let sftpCommandsSnapshot = sftpCommands
            let sshCommandsSnapshot = sshCommands
            try await executeSFTPPrimaryWithSSHFallback(
                sftpOperation: {
                    _ = try await runSFTPBatch(commands: sftpCommandsSnapshot)
                },
                sshFallback: {
                    for command in sshCommandsSnapshot {
                        try await runSSHCommand(command)
                    }
                }
            )
        }

        let gnuFormatter = DateFormatter()
        gnuFormatter.locale = Locale(identifier: "en_US_POSIX")
        gnuFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        gnuFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        let bsdFormatter = DateFormatter()
        bsdFormatter.locale = Locale(identifier: "en_US_POSIX")
        bsdFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        bsdFormatter.dateFormat = "yyyyMMddHHmm.ss"

        let gnuTimestamp = gnuFormatter.string(from: attributes.modifiedAt)
        let bsdTimestamp = bsdFormatter.string(from: attributes.modifiedAt)
        let touchCommand = "touch -m -d \(Self.quoteShellArgument(gnuTimestamp)) -- \(Self.quoteShellArgument(normalized)) 2>/dev/null || touch -m -t \(bsdTimestamp) -- \(Self.quoteShellArgument(normalized))"
        try await runSSHCommand(touchCommand)
    }

    public func executeRemoteShellCommand(
        _ command: String,
        timeout: TimeInterval? = nil
    ) async throws -> String {
        try await runSSHCommandOutput(command, timeout: timeout ?? shellFallbackTimeout)
    }

    public func streamRemoteShellCommand(_ command: String) async throws -> AsyncThrowingStream<String, Error> {
        let launch = await makePrimarySSHLaunchConfiguration(command: command)
        return Self.makeStreamingProcess(
            executablePath: launch.executablePath,
            arguments: launch.arguments,
            environment: launch.environment,
            host: host,
            logPhase: "ssh-stream"
        )
    }

    private func executeSFTPPrimaryWithSSHFallback<T: Sendable>(
        sftpOperation: @Sendable () async throws -> T,
        sshFallback: @Sendable () async throws -> T
    ) async throws -> T {
        do {
            return try await sftpOperation()
        } catch {
            return try await sshFallback()
        }
    }

    static func makeSFTPArguments(
        for host: Host,
        batchMode: Bool = true,
        useConnectionReuse: Bool = true
    ) -> [String] {
        var args: [String] = [
            "-q",
            "-b", "-",
            "-P", "\(host.port)",
            "-o", "ConnectTimeout=\(max(1, host.policies.connectTimeoutSeconds))",
            "-o", "ServerAliveInterval=\(max(5, host.policies.keepAliveSeconds))",
            "-o", "ServerAliveCountMax=3",
            "-o", "StrictHostKeyChecking=ask",
        ]
        if batchMode {
            args.append(contentsOf: ["-o", "BatchMode=yes"])
        }
        if useConnectionReuse {
            args.append(contentsOf: SSHConnectionReuse.masterOptions(for: host))
        }

        switch host.auth.method {
        case .privateKey:
            if let keyRef = host.auth.keyReference, !keyRef.isEmpty {
                args.append(contentsOf: ["-i", keyRef])
            }
            args.append(contentsOf: ["-o", "PreferredAuthentications=publickey"])
        case .password:
            args.append(contentsOf: ["-o", "PreferredAuthentications=password,keyboard-interactive"])
            args.append(contentsOf: ["-o", "NumberOfPasswordPrompts=1"])
        case .agent:
            args.append(contentsOf: ["-o", "PreferredAuthentications=publickey"])
        }

        args.append("\(host.username)@\(host.address)")
        return args
    }

    static func makeSSHArguments(
        for host: Host,
        batchMode: Bool = true,
        useConnectionReuse: Bool = true
    ) -> [String] {
        var args: [String] = [
            "-p", "\(host.port)",
            "-o", "ConnectTimeout=\(max(1, host.policies.connectTimeoutSeconds))",
            "-o", "ServerAliveInterval=\(max(5, host.policies.keepAliveSeconds))",
            "-o", "ServerAliveCountMax=3",
            "-o", "StrictHostKeyChecking=ask",
        ]
        if batchMode {
            args.append(contentsOf: ["-o", "BatchMode=yes"])
        }
        if useConnectionReuse {
            args.append(contentsOf: SSHConnectionReuse.masterOptions(for: host))
        }

        switch host.auth.method {
        case .privateKey:
            if let keyRef = host.auth.keyReference, !keyRef.isEmpty {
                args.append(contentsOf: ["-i", keyRef])
            }
            args.append(contentsOf: ["-o", "PreferredAuthentications=publickey"])
        case .password:
            args.append(contentsOf: ["-o", "PreferredAuthentications=password,keyboard-interactive"])
            args.append(contentsOf: ["-o", "NumberOfPasswordPrompts=1"])
        case .agent:
            args.append(contentsOf: ["-o", "PreferredAuthentications=publickey"])
        }

        args.append("\(host.username)@\(host.address)")
        return args
    }

    struct ParsedLongListEntry: Equatable {
        var name: String
        var size: Int64
        var isDirectory: Bool
        var modifiedAt: Date
        var permissions: UInt16?
        var owner: String?
        var group: String?
    }

    static func parseLongListOutput(_ output: String, parentPath: String, now: Date = Date()) -> [RemoteFileEntry] {
        var seen = Set<String>()
        return parseLongListEntries(output, now: now).compactMap { parsed in
            guard let normalizedName = sanitizeListedName(parsed.name, parentPath: parentPath) else {
                return nil
            }
            guard !seen.contains(normalizedName) else { return nil }
            seen.insert(normalizedName)

            let fullPath: String
            if parentPath == "/" {
                fullPath = "/\(normalizedName)"
            } else {
                fullPath = "\(parentPath)/\(normalizedName)".replacingOccurrences(of: "//", with: "/")
            }
            return RemoteFileEntry(
                name: normalizedName,
                path: fullPath,
                size: parsed.size,
                permissions: parsed.permissions,
                owner: parsed.owner,
                group: parsed.group,
                isDirectory: parsed.isDirectory,
                modifiedAt: parsed.modifiedAt
            )
        }
    }

    static func parseNameOnlyListOutput(_ output: String, parentPath: String, now: Date = Date()) -> [RemoteFileEntry] {
        var seen = Set<String>()
        var entries: [RemoteFileEntry] = []
        let lines = output
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }

        for line in lines {
            guard !line.isEmpty else { continue }
            guard !line.hasPrefix("sftp>") else { continue }
            guard !line.hasPrefix("Connected to ") else { continue }
            guard !line.hasSuffix(":") else { continue }
            guard !line.contains("No such file") else { continue }

            let tokens = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            for rawToken in tokens {
                guard !rawToken.isEmpty else { continue }
                var name = rawToken
                var isDirectory = false
                if name.hasSuffix("/") {
                    isDirectory = true
                    name.removeLast()
                }
                guard let normalizedName = sanitizeListedName(name, parentPath: parentPath) else { continue }
                guard !seen.contains(normalizedName) else { continue }
                seen.insert(normalizedName)

                let fullPath: String
                if parentPath == "/" {
                    fullPath = "/\(normalizedName)"
                } else {
                    fullPath = "\(parentPath)/\(normalizedName)".replacingOccurrences(of: "//", with: "/")
                }
                entries.append(
                    RemoteFileEntry(
                        name: normalizedName,
                        path: fullPath,
                        size: 0,
                        isDirectory: isDirectory,
                        modifiedAt: now
                    )
                )
            }
        }

        return entries
    }

    static func parseLongListEntries(_ output: String, now: Date = Date()) -> [ParsedLongListEntry] {
        output
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n")
            .compactMap { parseLongListLine(String($0), now: now) }
    }

    private static func parseLongListLine(_ rawLine: String, now: Date) -> ParsedLongListEntry? {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return nil }
        guard !line.hasPrefix("total ") else { return nil }
        guard !line.hasSuffix(":") else { return nil }

        let fields = line.split(omittingEmptySubsequences: true, whereSeparator: { $0.isWhitespace })
        guard fields.count >= 9 else { return nil }

        let modeField = String(fields[0])
        guard modeField.count >= 10 else { return nil }
        let fileType = modeField.first ?? "-"
        guard fileType == "d" || fileType == "-" || fileType == "l" else { return nil }

        guard let size = Int64(fields[4]) else { return nil }
        let month = String(fields[5])
        let day = String(fields[6])
        let timeOrYear = String(fields[7])
        let nameWithTarget = fields.dropFirst(8).map(String.init).joined(separator: " ")
        guard !nameWithTarget.isEmpty else { return nil }
        let name = nameWithTarget.components(separatedBy: " -> ").first ?? nameWithTarget
        guard name != "." && name != ".." else { return nil }

        return ParsedLongListEntry(
            name: name,
            size: size,
            isDirectory: fileType == "d",
            modifiedAt: parseLongListDate(month: month, day: day, timeOrYear: timeOrYear, now: now) ?? now,
            permissions: parsePermissions(modeField),
            owner: String(fields[2]),
            group: String(fields[3])
        )
    }

    private static func parsePermissions(_ field: String) -> UInt16? {
        guard field.count >= 10 else { return nil }
        let modeChars = Array(field.dropFirst())
        guard modeChars.count >= 9 else { return nil }

        func triadValue(_ chars: ArraySlice<Character>) -> UInt16 {
            var value: UInt16 = 0
            let array = Array(chars)
            guard array.count == 3 else { return 0 }

            if array[0] == "r" { value += 4 }
            if array[1] == "w" { value += 2 }
            if array[2] == "x" || array[2] == "s" || array[2] == "t" { value += 1 }
            return value
        }

        let owner = triadValue(modeChars[0..<3])
        let group = triadValue(modeChars[3..<6])
        let other = triadValue(modeChars[6..<9])
        return owner * 64 + group * 8 + other
    }

    private static func sanitizeListedName(_ rawName: String, parentPath: String) -> String? {
        var candidate = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return nil }

        if candidate.hasSuffix("/") {
            candidate.removeLast()
        }

        if candidate == "." || candidate == ".." {
            return nil
        }

        let normalizedParent = parentPath == "/" ? "/" : parentPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let parentPrefix = normalizedParent == "/" ? "/" : "\(normalizedParent)/"
        if candidate.hasPrefix(parentPrefix), candidate.count > parentPrefix.count {
            candidate = String(candidate.dropFirst(parentPrefix.count))
        }

        if candidate.hasPrefix("/") {
            candidate = URL(fileURLWithPath: candidate).lastPathComponent
        }

        candidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return nil }
        guard candidate != "." && candidate != ".." else { return nil }
        return candidate
    }

    private static func parseLongListDate(
        month: String,
        day: String,
        timeOrYear: String,
        now: Date
    ) -> Date? {
        let locale = Locale(identifier: "en_US_POSIX")
        let calendar = Calendar(identifier: .gregorian)

        if timeOrYear.contains(":") {
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.timeZone = TimeZone.current
            formatter.dateFormat = "MMM d HH:mm yyyy"
            let currentYear = calendar.component(.year, from: now)
            let candidate = "\(month) \(day) \(timeOrYear) \(currentYear)"
            guard let parsed = formatter.date(from: candidate) else { return nil }
            if parsed.timeIntervalSince(now) > 24 * 60 * 60 {
                var components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: parsed)
                components.year = (components.year ?? currentYear) - 1
                return calendar.date(from: components)
            }
            return parsed
        }

        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "MMM d yyyy"
        return formatter.date(from: "\(month) \(day) \(timeOrYear)")
    }

    private func runSFTPBatch(commands: [String], timeout: TimeInterval? = nil) async throws -> String {
        let normalizedCommands = commands.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !normalizedCommands.isEmpty else {
            throw SFTPClientError.unsupportedOperation("empty-sftp-command")
        }

        let payload = Data((normalizedCommands + ["quit"]).joined(separator: "\n").appending("\n").utf8)
        let result = try await runSFTPBatchWithFallbacks(stdin: payload, timeout: timeout)

        let stdoutText = String(decoding: result.stdout, as: UTF8.self)
        let stderrText = String(decoding: result.stderr, as: UTF8.self)

        guard result.status == 0 else {
            let message = [stderrText, stdoutText]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first(where: { !$0.isEmpty }) ?? "sftp exited with status \(result.status)"
            throw SSHError.connectionFailed(message)
        }

        if !stderrText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return stdoutText + "\n" + stderrText
        }
        return stdoutText
    }

    private func runSSHCommand(_ command: String) async throws {
        _ = try await runSSHCommandOutput(command)
    }

    private func runSSHCommandToFile(
        _ command: String,
        destinationURL: URL,
        timeout: TimeInterval? = nil
    ) async throws {
        _ = try await runSSHCommandWithFallbacks(
            command: command,
            timeout: timeout,
            outputLogMode: .metadataOnly,
            inputLogMode: .text,
            stdoutFileURL: destinationURL
        )
    }

    private func runSSHCommandResult(
        _ command: String,
        stdin: Data? = nil,
        timeout: TimeInterval? = nil,
        outputLogMode: OutputLogMode = .text,
        inputLogMode: InputLogMode = .text
    ) async throws -> ProcessResult {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ProcessResult(status: 0, stdout: Data(), stderr: Data())
        }

        let result = try await runSSHCommandWithFallbacks(
            command: trimmed,
            stdin: stdin,
            timeout: timeout,
            outputLogMode: outputLogMode,
            inputLogMode: inputLogMode
        )
        guard result.status == 0 else {
            let stderrText = String(decoding: result.stderr, as: UTF8.self)
            let stdoutText = String(decoding: result.stdout, as: UTF8.self)
            let message = [stderrText, stdoutText]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first(where: { !$0.isEmpty }) ?? "ssh exited with status \(result.status)"
            throw SSHError.connectionFailed(message)
        }
        return result
    }

    private func runSSHCommandOutput(_ command: String, timeout: TimeInterval? = nil) async throws -> String {
        let result = try await runSSHCommandResult(
            command,
            timeout: timeout,
            outputLogMode: .text
        )
        return String(decoding: result.stdout, as: UTF8.self)
    }

    private func runSSHCommandData(_ command: String, timeout: TimeInterval? = nil) async throws -> Data {
        let result = try await runSSHCommandResult(
            command,
            timeout: timeout,
            outputLogMode: .metadataOnly
        )
        return result.stdout
    }

    private func runSFTPBatchWithFallbacks(stdin: Data, timeout: TimeInterval? = nil) async throws -> ProcessResult {
        let primary = await makePrimarySFTPLaunchConfiguration()
        var result = try await runProcess(
            executablePath: primary.executablePath,
            arguments: primary.arguments,
            environment: primary.environment,
            stdin: stdin,
            timeout: timeout,
            logPhase: "sftp-primary",
            host: host,
            outputLogMode: .text,
            inputLogMode: .text
        )
        if result.status == 0 {
            return result
        }

        guard primary.usesConnectionReuse, shouldRetryWithoutConnectionReuse(result: result) else {
            return result
        }

        let retry = makeSFTPLaunchConfiguration(batchMode: true, useConnectionReuse: false)
        result = try await runProcess(
            executablePath: retry.executablePath,
            arguments: retry.arguments,
            environment: retry.environment,
            stdin: stdin,
            timeout: timeout,
            logPhase: "sftp-retry-no-reuse",
            host: host,
            outputLogMode: .text,
            inputLogMode: .text
        )
        return result
    }

    private func downloadViaSFTP(path: String) async throws -> Data {
        let tempURL = makeTemporaryURL(prefix: "remora-sftp-download")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        try await downloadViaSFTP(path: path, to: tempURL)
        return try Data(contentsOf: tempURL)
    }

    private func downloadViaSFTP(path: String, to localFileURL: URL) async throws {
        try FileManager.default.createDirectory(
            at: localFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        _ = try await runSFTPBatch(
            commands: [
                "get \(Self.quoteBatchArgument(path)) \(Self.quoteBatchArgument(localFileURL.path))",
            ]
        )
    }

    private func uploadViaSFTP(fileURL: URL, to path: String) async throws {
        _ = try await runSFTPBatch(
            commands: [
                "put \(Self.quoteBatchArgument(fileURL.path)) \(Self.quoteBatchArgument(path))",
            ]
        )
    }

    private func downloadViaSSH(path: String) async throws -> Data {
        let command = "cat -- \(Self.quoteShellArgument(path))"
        return try await runSSHCommandData(command)
    }

    private func downloadViaSSH(path: String, to localFileURL: URL) async throws {
        let command = "cat -- \(Self.quoteShellArgument(path))"
        try await runSSHCommandToFile(command, destinationURL: localFileURL)
    }

    private func uploadViaSSH(fileURL: URL, to path: String) async throws {
        let payload = try Data(contentsOf: fileURL)
        let command = "cat > \(Self.quoteShellArgument(path))"
        _ = try await runSSHCommandResult(
            command,
            stdin: payload,
            outputLogMode: .text,
            inputLogMode: .metadataOnly
        )
    }

    private func runSSHCommandWithFallbacks(
        command: String,
        stdin: Data? = nil,
        timeout: TimeInterval? = nil,
        outputLogMode: OutputLogMode,
        inputLogMode: InputLogMode,
        stdoutFileURL: URL? = nil
    ) async throws -> ProcessResult {
        let primary = await makePrimarySSHLaunchConfiguration(command: command)
        var result = try await runProcess(
            executablePath: primary.executablePath,
            arguments: primary.arguments,
            environment: primary.environment,
            stdin: stdin,
            timeout: timeout,
            logPhase: "ssh-primary",
            host: host,
            outputLogMode: outputLogMode,
            inputLogMode: inputLogMode,
            stdoutFileURL: stdoutFileURL
        )
        if result.status == 0 {
            return result
        }

        guard primary.usesConnectionReuse, shouldRetryWithoutConnectionReuse(result: result) else {
            return result
        }

        let retry = makeSSHLaunchConfiguration(command: command, batchMode: true, useConnectionReuse: false)
        result = try await runProcess(
            executablePath: retry.executablePath,
            arguments: retry.arguments,
            environment: retry.environment,
            stdin: stdin,
            timeout: timeout,
            logPhase: "ssh-retry-no-reuse",
            host: host,
            outputLogMode: outputLogMode,
            inputLogMode: inputLogMode,
            stdoutFileURL: stdoutFileURL
        )
        return result
    }

    private func runProcess(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        stdin: Data?,
        timeout: TimeInterval? = nil,
        logPhase: String,
        host: Host,
        outputLogMode: OutputLogMode,
        inputLogMode: InputLogMode,
        stdoutFileURL: URL? = nil
    ) async throws -> ProcessResult {
        Self.appendDiagnostics(
            Self.formatDiagnosticsMessage(
                host: host,
                phase: "\(logPhase)-start",
                body: [
                    "executable=\(executablePath)",
                    "arguments=\(arguments.joined(separator: " "))",
                    "environment=\(Self.redactedEnvironmentDescription(environment))",
                    "stdin=\(Self.describeInput(stdin, mode: inputLogMode))"
                ]
            )
        )
        let startedAt = Date()

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessResult, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executablePath)
                process.arguments = arguments
                if !environment.isEmpty {
                    process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
                }

                let stderrPipe = Pipe()
                process.standardError = stderrPipe
                let stdinPipe = Pipe()
                process.standardInput = stdinPipe
                var stdoutPipe: Pipe?
                var stdoutHandle: FileHandle?

                if let stdoutFileURL {
                    do {
                        try FileManager.default.createDirectory(
                            at: stdoutFileURL.deletingLastPathComponent(),
                            withIntermediateDirectories: true
                        )
                        FileManager.default.createFile(atPath: stdoutFileURL.path, contents: nil)
                        let handle = try FileHandle(forWritingTo: stdoutFileURL)
                        stdoutHandle = handle
                        process.standardOutput = handle
                    } catch {
                        continuation.resume(throwing: SSHError.connectionFailed("stdout file setup failed: \(error.localizedDescription)"))
                        return
                    }
                } else {
                    let pipe = Pipe()
                    stdoutPipe = pipe
                    process.standardOutput = pipe
                }

                do {
                    try process.run()
                } catch {
                    let elapsed = Date().timeIntervalSince(startedAt)
                    Self.appendDiagnostics(
                        Self.formatDiagnosticsMessage(
                            host: host,
                            phase: "\(logPhase)-launch-error",
                            body: [
                                "duration_ms=\(Int(elapsed * 1000))",
                                "error=\(error.localizedDescription)"
                            ]
                        )
                    )
                    continuation.resume(throwing: SSHError.connectionFailed(error.localizedDescription))
                    return
                }

                final class OutputBuffer: @unchecked Sendable {
                    private let lock = NSLock()
                    private var data = Data()

                    func set(_ newData: Data) {
                        lock.lock()
                        data = newData
                        lock.unlock()
                    }

                    func get() -> Data {
                        lock.lock()
                        defer { lock.unlock() }
                        return data
                    }
                }

                let stdoutBuffer = OutputBuffer()
                let stderrBuffer = OutputBuffer()
                let outputGroup = DispatchGroup()
                if let stdoutPipe {
                    outputGroup.enter()
                    DispatchQueue.global(qos: .utility).async {
                        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                        stdoutBuffer.set(data)
                        outputGroup.leave()
                    }
                }
                outputGroup.enter()
                DispatchQueue.global(qos: .utility).async {
                    let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    stderrBuffer.set(data)
                    outputGroup.leave()
                }

                if let stdin, !stdin.isEmpty {
                    do {
                        try stdinPipe.fileHandleForWriting.write(contentsOf: stdin)
                    } catch {
                        process.terminate()
                        let elapsed = Date().timeIntervalSince(startedAt)
                        Self.appendDiagnostics(
                            Self.formatDiagnosticsMessage(
                                host: host,
                                phase: "\(logPhase)-stdin-error",
                                body: [
                                    "duration_ms=\(Int(elapsed * 1000))",
                                    "error=\(error.localizedDescription)"
                                ]
                            )
                        )
                        continuation.resume(throwing: SSHError.connectionFailed("stdin write failed: \(error.localizedDescription)"))
                        return
                    }
                }

                try? stdinPipe.fileHandleForWriting.close()

                let waitOutcome = Self.waitForProcessExit(process, timeout: timeout)
                outputGroup.wait()
                let capturedStdout = stdoutBuffer.get()
                let capturedStderr = stderrBuffer.get()

                try? stdoutHandle?.close()
                try? stdoutPipe?.fileHandleForReading.close()
                try? stderrPipe.fileHandleForReading.close()

                if waitOutcome == .timedOut {
                    let timeoutText = timeout.map { String(format: "%.1f", $0) } ?? "unknown"
                    let elapsed = Date().timeIntervalSince(startedAt)
                    Self.appendDiagnostics(
                        Self.formatDiagnosticsMessage(
                            host: host,
                            phase: "\(logPhase)-timeout",
                            body: [
                                "duration_ms=\(Int(elapsed * 1000))",
                                "stdout=\(Self.describeOutput(capturedStdout, mode: outputLogMode))",
                                "stderr=\(Self.describeOutput(capturedStderr, mode: .text))"
                            ]
                        )
                    )
                    continuation.resume(throwing: SSHError.connectionFailed("command timed out after \(timeoutText)s"))
                    return
                }

                let elapsed = Date().timeIntervalSince(startedAt)
                Self.appendDiagnostics(
                    Self.formatDiagnosticsMessage(
                        host: host,
                        phase: "\(logPhase)-exit",
                        body: [
                            "duration_ms=\(Int(elapsed * 1000))",
                            "status=\(process.terminationStatus)",
                            "stdout=\(Self.describeOutput(capturedStdout, mode: outputLogMode))",
                            "stderr=\(Self.describeOutput(capturedStderr, mode: .text))"
                        ]
                    )
                )

                continuation.resume(
                    returning: ProcessResult(
                        status: process.terminationStatus,
                        stdout: capturedStdout,
                        stderr: capturedStderr
                    )
                )
            }
        }
    }

    private enum ProcessWaitOutcome {
        case exited
        case timedOut
    }

    private static func waitForProcessExit(_ process: Process, timeout: TimeInterval?) -> ProcessWaitOutcome {
        guard let timeout, timeout > 0 else {
            process.waitUntilExit()
            return .exited
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }

        guard process.isRunning else {
            process.waitUntilExit()
            return .exited
        }

        process.terminate()
        let graceDeadline = Date().addingTimeInterval(1)
        while process.isRunning, Date() < graceDeadline {
            Thread.sleep(forTimeInterval: 0.02)
        }

        if process.isRunning {
            _ = kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
        return .timedOut
    }

    private static func makeStreamingProcess(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        host: Host,
        logPhase: String
    ) -> AsyncThrowingStream<String, Error> {
        final class ProcessBox: @unchecked Sendable {
            private let lock = NSLock()
            private var process: Process?
            private var wasCancelled = false

            func setProcess(_ process: Process) {
                lock.lock()
                self.process = process
                lock.unlock()
            }

            func cancel() {
                lock.lock()
                wasCancelled = true
                let process = self.process
                lock.unlock()
                process?.terminate()
            }

            func isCancelled() -> Bool {
                lock.lock()
                defer { lock.unlock() }
                return wasCancelled
            }
        }

        final class DataBuffer: @unchecked Sendable {
            private let lock = NSLock()
            private var data = Data()

            func append(_ chunk: Data) {
                lock.lock()
                data.append(chunk)
                lock.unlock()
            }

            func get() -> Data {
                lock.lock()
                defer { lock.unlock() }
                return data
            }
        }

        let processBox = ProcessBox()

        return AsyncThrowingStream { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                Self.appendDiagnostics(
                    Self.formatDiagnosticsMessage(
                        host: host,
                        phase: "\(logPhase)-start",
                        body: [
                            "executable=\(executablePath)",
                            "arguments=\(arguments.joined(separator: " "))",
                            "environment=\(Self.redactedEnvironmentDescription(environment))"
                        ]
                    )
                )

                let process = Process()
                process.executableURL = URL(fileURLWithPath: executablePath)
                process.arguments = arguments
                if !environment.isEmpty {
                    process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
                }

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe
                process.standardInput = FileHandle.nullDevice
                processBox.setProcess(process)

                let stderrBuffer = DataBuffer()
                stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    guard !data.isEmpty else { return }
                    continuation.yield(String(decoding: data, as: UTF8.self))
                }
                stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    guard !data.isEmpty else { return }
                    stderrBuffer.append(data)
                }

                process.terminationHandler = { process in
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    try? stdoutPipe.fileHandleForReading.close()
                    try? stderrPipe.fileHandleForReading.close()

                    let stderrText = String(decoding: stderrBuffer.get(), as: UTF8.self)
                    Self.appendDiagnostics(
                        Self.formatDiagnosticsMessage(
                            host: host,
                            phase: "\(logPhase)-exit",
                            body: [
                                "status=\(process.terminationStatus)",
                                "stderr=\(stderrText.isEmpty ? "<empty>" : stderrText)"
                            ]
                        )
                    )

                    if processBox.isCancelled() {
                        continuation.finish()
                        return
                    }

                    if process.terminationStatus == 0 || process.terminationReason == .uncaughtSignal {
                        continuation.finish()
                        return
                    }

                    let message = stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
                    let errorText = message.isEmpty ? "stream command failed with status \(process.terminationStatus)" : message
                    continuation.finish(throwing: SSHError.connectionFailed(errorText))
                }

                do {
                    try process.run()
                } catch {
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    try? stdoutPipe.fileHandleForReading.close()
                    try? stderrPipe.fileHandleForReading.close()
                    Self.appendDiagnostics(
                        Self.formatDiagnosticsMessage(
                            host: host,
                            phase: "\(logPhase)-launch-error",
                            body: ["error=\(error.localizedDescription)"]
                        )
                    )
                    continuation.finish(throwing: SSHError.connectionFailed(error.localizedDescription))
                }
            }

            continuation.onTermination = { _ in
                processBox.cancel()
            }
        }
    }

    private func shouldRetryWithoutConnectionReuse(result: ProcessResult) -> Bool {
        guard result.status != 0 else { return false }
        let message = String(decoding: result.stderr + result.stdout, as: UTF8.self)
        return Self.isTransientConnectionFailureMessage(message)
    }

    static func isTransientConnectionFailureMessage(_ message: String) -> Bool {
        let lowered = message.lowercased()
        if lowered.contains("connection closed") {
            return true
        }
        if lowered.contains("control socket") {
            return true
        }
        if lowered.contains("mux_client") || lowered.contains("muxserver") {
            return true
        }
        if lowered.contains("broken pipe") {
            return true
        }
        return false
    }

    private static func shouldSwitchToSSHStreamingTransfer(for error: Error) -> Bool {
        isTransientConnectionFailureMessage(error.localizedDescription)
    }

    static func diagnosticsLogFilePath() -> String {
        diagnosticsLogURL.path
    }

    private static func formatDiagnosticsMessage(host: Host, phase: String, body: [String]) -> String {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let header = "[\(timestamp)] [\(phase)] [\(host.username)@\(host.address):\(host.port)]"
        let payload = body.joined(separator: "\n")
        return "\(header)\n\(payload)\n"
    }

    private static func appendDiagnostics(_ message: String) {
        diagnosticsQueue.sync {
            rotateDiagnosticsIfNeeded(fileManager: .default)
            cleanupExpiredDiagnosticsIfNeeded(fileManager: .default, now: Date())

            let data = Data((message + "\n").utf8)
            if FileManager.default.fileExists(atPath: diagnosticsLogURL.path) {
                do {
                    let handle = try FileHandle(forWritingTo: diagnosticsLogURL)
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                    return
                } catch {
                    // Fall through and attempt direct write.
                }
            }

            do {
                try data.write(to: diagnosticsLogURL, options: [.atomic])
            } catch {
                // Best-effort diagnostics; ignore write failure.
            }
        }
    }

    private static func rotateDiagnosticsIfNeeded(fileManager: FileManager) {
        guard let attributes = try? fileManager.attributesOfItem(atPath: diagnosticsLogURL.path),
              let sizeNumber = attributes[.size] as? NSNumber
        else {
            return
        }

        let fileSize = sizeNumber.int64Value
        guard fileSize >= diagnosticsLogMaxBytes else { return }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let timestamp = formatter.string(from: Date())
        let archiveURL = diagnosticsLogURL.deletingPathExtension().appendingPathExtension("\(timestamp).log")
        try? fileManager.moveItem(at: diagnosticsLogURL, to: archiveURL)
    }

    private static func cleanupExpiredDiagnosticsIfNeeded(fileManager: FileManager, now: Date) {
        let directoryURL = diagnosticsLogURL.deletingLastPathComponent()
        guard let fileURLs = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        for fileURL in fileURLs {
            let fileName = fileURL.lastPathComponent
            guard fileName.hasPrefix("sftp-diagnostics") else { continue }

            guard let values = try? fileURL.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey, .creationDateKey]),
                  values.isDirectory != true
            else {
                continue
            }

            let referenceDate = values.contentModificationDate ?? values.creationDate
            guard let referenceDate else { continue }
            guard shouldDeleteDiagnosticsFile(referenceDate: referenceDate, now: now, retentionDays: diagnosticsRetentionDays) else {
                continue
            }
            try? fileManager.removeItem(at: fileURL)
        }
    }

    static func shouldDeleteDiagnosticsFile(referenceDate: Date, now: Date, retentionDays: Int) -> Bool {
        let retentionInterval = TimeInterval(retentionDays * 24 * 60 * 60)
        return now.timeIntervalSince(referenceDate) > retentionInterval
    }

    static func redactedEnvironmentDescription(_ environment: [String: String]) -> String {
        if environment.isEmpty { return "{}" }
        let pairs = environment
            .sorted(by: { $0.key < $1.key })
            .map { key, value in
                let upperKey = key.uppercased()
                if upperKey.contains("PASS") || upperKey.contains("TOKEN") || upperKey.contains("SECRET") {
                    return "\(key)=<redacted>"
                }
                return "\(key)=\(value)"
            }
        return "{\(pairs.joined(separator: ", "))}"
    }

    private static func describeInput(_ input: Data?, mode: InputLogMode) -> String {
        guard let input, !input.isEmpty else { return "<empty>" }
        switch mode {
        case .text:
            if let text = String(data: input, encoding: .utf8) {
                return text
            }
            return "<non-utf8 \(input.count) bytes>"
        case .metadataOnly:
            return "<\(input.count) bytes omitted>"
        }
    }

    private static func describeOutput(_ output: Data, mode: OutputLogMode) -> String {
        guard !output.isEmpty else { return "<empty>" }
        switch mode {
        case .text:
            if let text = String(data: output, encoding: .utf8) {
                return text
            }
            return "<non-utf8 \(output.count) bytes>"
        case .metadataOnly:
            return "<\(output.count) bytes omitted>"
        }
    }

    private func storedPasswordIfAvailable() async -> String? {
        guard host.auth.method == .password else { return nil }
        guard let passwordRef = host.auth.passwordReference, !passwordRef.isEmpty else { return nil }
        guard let password = await credentialStore.secret(for: passwordRef), !password.isEmpty else { return nil }
        return password
    }

    private func makePrimarySFTPLaunchConfiguration() async -> BatchLaunchConfiguration {
        if host.auth.method == .password,
           let passwordLaunch = await makePasswordLaunchConfigurationIfAvailable(
               baseExecutable: "/usr/bin/sftp",
               baseArguments: Self.makeSFTPArguments(for: host, batchMode: false, useConnectionReuse: false),
               usesConnectionReuse: false
           )
        {
            return passwordLaunch
        }

        if host.auth.method == .password {
            return makeSFTPLaunchConfiguration(batchMode: true, useConnectionReuse: false)
        }

        return makeSFTPLaunchConfiguration(batchMode: true, useConnectionReuse: true)
    }

    private func makePrimarySSHLaunchConfiguration(command: String) async -> BatchLaunchConfiguration {
        if host.auth.method == .password,
           let passwordLaunch = await makePasswordLaunchConfigurationIfAvailable(
               baseExecutable: "/usr/bin/ssh",
               baseArguments: Self.makeSSHArguments(for: host, batchMode: false, useConnectionReuse: false) + [command],
               usesConnectionReuse: false
           )
        {
            return passwordLaunch
        }

        if host.auth.method == .password {
            return makeSSHLaunchConfiguration(command: command, batchMode: true, useConnectionReuse: false)
        }

        return makeSSHLaunchConfiguration(command: command, batchMode: true, useConnectionReuse: true)
    }

    private func makeSFTPLaunchConfiguration(batchMode: Bool, useConnectionReuse: Bool) -> BatchLaunchConfiguration {
        BatchLaunchConfiguration(
            executablePath: "/usr/bin/sftp",
            arguments: Self.makeSFTPArguments(for: host, batchMode: batchMode, useConnectionReuse: useConnectionReuse),
            environment: [:],
            usesConnectionReuse: useConnectionReuse
        )
    }

    private func makeSSHLaunchConfiguration(command: String, batchMode: Bool, useConnectionReuse: Bool) -> BatchLaunchConfiguration {
        BatchLaunchConfiguration(
            executablePath: "/usr/bin/ssh",
            arguments: Self.makeSSHArguments(for: host, batchMode: batchMode, useConnectionReuse: useConnectionReuse) + [command],
            environment: [:],
            usesConnectionReuse: useConnectionReuse
        )
    }

    private func makePasswordLaunchConfigurationIfAvailable(
        baseExecutable: String,
        baseArguments: [String],
        usesConnectionReuse: Bool
    ) async -> BatchLaunchConfiguration? {
        guard let password = await storedPasswordIfAvailable() else {
            return nil
        }

        let sshpassCandidates = [
            "/opt/homebrew/bin/sshpass",
            "/usr/local/bin/sshpass",
            "/usr/bin/sshpass",
        ]

        if let sshpassPath = sshpassCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return BatchLaunchConfiguration(
                executablePath: sshpassPath,
                arguments: ["-e", baseExecutable] + baseArguments,
                environment: ["SSHPASS": password],
                usesConnectionReuse: usesConnectionReuse
            )
        }

        guard let askPassScriptPath = ensureAskPassScriptPath() else {
            return nil
        }

        return BatchLaunchConfiguration(
            executablePath: baseExecutable,
            arguments: baseArguments,
            environment: [
                "SSH_ASKPASS": askPassScriptPath,
                "SSH_ASKPASS_REQUIRE": "force",
                "DISPLAY": "remora-askpass",
                "REMORA_SSH_PASSWORD": password,
            ]
            ,
            usesConnectionReuse: usesConnectionReuse
        )
    }

    private func ensureAskPassScriptPath() -> String? {
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("remora-ssh-askpass.sh")

        if FileManager.default.fileExists(atPath: scriptURL.path) {
            return scriptURL.path
        }

        let script = """
        #!/bin/sh
        printf '%s\\n' \"${REMORA_SSH_PASSWORD}\"
        """
        guard let scriptData = script.data(using: .utf8) else {
            return nil
        }

        do {
            try scriptData.write(to: scriptURL, options: [.atomic])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: scriptURL.path
            )
            return scriptURL.path
        } catch {
            return nil
        }
    }

    private func normalize(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "/" }
        let prefixed = trimmed.hasPrefix("/") ? trimmed : "/\(trimmed)"
        return prefixed.replacingOccurrences(of: "//", with: "/")
    }

    private func makeTemporaryURL(prefix: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
    }

    private func prepareDownloadDestination(_ destinationURL: URL) throws -> (tempURL: URL, destinationURL: URL) {
        let standardizedDestination = destinationURL.standardizedFileURL
        let directory = standardizedDestination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let tempURL = directory.appendingPathComponent(".remora-download-\(UUID().uuidString)")
        return (tempURL, standardizedDestination)
    }

    private func finalizeDownloadedFile(tempURL: URL, destinationURL: URL) throws {
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.moveItem(at: tempURL, to: destinationURL)
    }

    private func listViaSSH(path: String, timeout: TimeInterval? = nil) async throws -> [RemoteFileEntry] {
        let longListCommand = "LC_ALL=C ls -lan -- \(Self.quoteShellArgument(path))"
        if let longOutput = try? await runSSHCommandOutput(longListCommand, timeout: timeout) {
            let parsedLongEntries = Self.parseLongListOutput(longOutput, parentPath: path)
            if !parsedLongEntries.isEmpty {
                return parsedLongEntries
            }
        }

        let nameOnlyCommand = "LC_ALL=C ls -1Ap -- \(Self.quoteShellArgument(path))"
        let output = try await runSSHCommandOutput(nameOnlyCommand, timeout: timeout)
        let now = Date()
        let names = output
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != "." && $0 != ".." }

        return names.map { rawName in
            var name = rawName
            let isDirectory = name.hasSuffix("/")
            if isDirectory {
                name.removeLast()
            }

            let fullPath: String
            if path == "/" {
                fullPath = "/\(name)"
            } else {
                fullPath = "\(path)/\(name)".replacingOccurrences(of: "//", with: "/")
            }

            return RemoteFileEntry(
                name: name,
                path: fullPath,
                size: 0,
                isDirectory: isDirectory,
                modifiedAt: now
            )
        }
    }

    static func quoteBatchArgument(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static func quoteShellArgument(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }
}
