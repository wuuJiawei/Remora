import Foundation

public actor SystemSFTPClient: SFTPClientProtocol {
    private struct ProcessResult {
        var status: Int32
        var stdout: Data
        var stderr: Data
    }

    private struct BatchLaunchConfiguration {
        var executablePath: String
        var arguments: [String]
        var environment: [String: String]
    }

    private let host: Host
    private let credentialStore = CredentialStore()

    public init(host: Host) {
        self.host = host
    }

    public func list(path: String) async throws -> [RemoteFileEntry] {
        let normalized = normalize(path)
        let output = try await runSFTPBatch(commands: ["ls -lan \(Self.quoteBatchArgument(normalized))"])
        let parsedLongEntries = Self.parseLongListOutput(output, parentPath: normalized)
        if !parsedLongEntries.isEmpty {
            return parsedLongEntries
        }

        // Some servers return a non-long listing even when -l is requested.
        if let sshFallback = try? await listViaSSH(path: normalized), !sshFallback.isEmpty {
            return sshFallback
        }

        let parsedNameEntries = Self.parseNameOnlyListOutput(output, parentPath: normalized)
        if !parsedNameEntries.isEmpty {
            return parsedNameEntries
        }

        return []
    }

    public func download(path: String) async throws -> Data {
        let normalized = normalize(path)
        let tempURL = makeTemporaryURL(prefix: "remora-sftp-download")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        _ = try await runSFTPBatch(
            commands: [
                "get \(Self.quoteBatchArgument(normalized)) \(Self.quoteBatchArgument(tempURL.path))",
            ]
        )
        return try Data(contentsOf: tempURL)
    }

    public func download(path: String, progress: TransferProgressHandler?) async throws -> Data {
        let normalized = normalize(path)
        let expectedSize = try? await stat(path: normalized).size
        progress?(.init(bytesTransferred: 0, totalBytes: expectedSize))
        let payload = try await download(path: normalized)
        progress?(.init(bytesTransferred: Int64(payload.count), totalBytes: expectedSize ?? Int64(payload.count)))
        return payload
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
        _ = try await runSFTPBatch(
            commands: [
                "put \(Self.quoteBatchArgument(fileURL.path)) \(Self.quoteBatchArgument(normalized))",
            ]
        )
        progress?(.init(bytesTransferred: totalBytes ?? 0, totalBytes: totalBytes))
    }

    public func rename(from: String, to: String) async throws {
        let source = normalize(from)
        let destination = normalize(to)
        _ = try await runSFTPBatch(
            commands: [
                "rename \(Self.quoteBatchArgument(source)) \(Self.quoteBatchArgument(destination))",
            ]
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
        _ = try await runSFTPBatch(commands: ["mkdir \(Self.quoteBatchArgument(normalized))"])
    }

    public func remove(path: String) async throws {
        let normalized = normalize(path)
        let attributes = try await stat(path: normalized)
        if attributes.isDirectory {
            let command = "rm -rf -- \(Self.quoteShellArgument(normalized))"
            try await runSSHCommand(command)
            return
        }
        _ = try await runSFTPBatch(commands: ["rm \(Self.quoteBatchArgument(normalized))"])
    }

    public func stat(path: String) async throws -> RemoteFileAttributes {
        let normalized = normalize(path)
        let output = try await runSFTPBatch(commands: ["ls -ldn \(Self.quoteBatchArgument(normalized))"])
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
        var commands: [String] = []

        if let permissions = attributes.permissions {
            commands.append("chmod \(String(permissions, radix: 8)) \(Self.quoteBatchArgument(normalized))")
        }
        if let owner = attributes.owner, !owner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            commands.append("chown \(Self.quoteBatchArgument(owner)) \(Self.quoteBatchArgument(normalized))")
        }
        if let group = attributes.group, !group.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            commands.append("chgrp \(Self.quoteBatchArgument(group)) \(Self.quoteBatchArgument(normalized))")
        }

        if !commands.isEmpty {
            _ = try await runSFTPBatch(commands: commands)
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

    static func makeSFTPArguments(for host: Host) -> [String] {
        var args: [String] = [
            "-q",
            "-b", "-",
            "-P", "\(host.port)",
            "-o", "ConnectTimeout=\(max(1, host.policies.connectTimeoutSeconds))",
            "-o", "ServerAliveInterval=\(max(5, host.policies.keepAliveSeconds))",
            "-o", "ServerAliveCountMax=3",
            "-o", "StrictHostKeyChecking=ask",
        ]
        args.append(contentsOf: SSHConnectionReuse.options(for: host))

        switch host.auth.method {
        case .privateKey:
            if let keyRef = host.auth.keyReference, !keyRef.isEmpty {
                args.append(contentsOf: ["-i", keyRef])
            }
            args.append(contentsOf: ["-o", "PreferredAuthentications=publickey"])
        case .password:
            args.append(contentsOf: ["-o", "PreferredAuthentications=password,keyboard-interactive"])
        case .agent:
            args.append(contentsOf: ["-o", "PreferredAuthentications=publickey"])
        }

        args.append("\(host.username)@\(host.address)")
        return args
    }

    static func makeSSHArguments(for host: Host) -> [String] {
        var args: [String] = [
            "-p", "\(host.port)",
            "-o", "ConnectTimeout=\(max(1, host.policies.connectTimeoutSeconds))",
            "-o", "ServerAliveInterval=\(max(5, host.policies.keepAliveSeconds))",
            "-o", "ServerAliveCountMax=3",
            "-o", "StrictHostKeyChecking=ask",
        ]
        args.append(contentsOf: SSHConnectionReuse.options(for: host))

        switch host.auth.method {
        case .privateKey:
            if let keyRef = host.auth.keyReference, !keyRef.isEmpty {
                args.append(contentsOf: ["-i", keyRef])
            }
            args.append(contentsOf: ["-o", "PreferredAuthentications=publickey"])
        case .password:
            args.append(contentsOf: ["-o", "PreferredAuthentications=password,keyboard-interactive"])
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
        parseLongListEntries(output, now: now).map { parsed in
            let fullPath: String
            if parentPath == "/" {
                fullPath = "/\(parsed.name)"
            } else {
                fullPath = "\(parentPath)/\(parsed.name)".replacingOccurrences(of: "//", with: "/")
            }
            return RemoteFileEntry(
                name: parsed.name,
                path: fullPath,
                size: parsed.size,
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
                guard name != "." && name != ".." else { continue }
                guard !seen.contains(name) else { continue }
                seen.insert(name)

                let fullPath: String
                if parentPath == "/" {
                    fullPath = "/\(name)"
                } else {
                    fullPath = "\(parentPath)/\(name)".replacingOccurrences(of: "//", with: "/")
                }
                entries.append(
                    RemoteFileEntry(
                        name: name,
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

    private func runSFTPBatch(commands: [String]) async throws -> String {
        let normalizedCommands = commands.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !normalizedCommands.isEmpty else {
            throw SFTPClientError.unsupportedOperation("empty-sftp-command")
        }

        let launch = try await makeSFTPBatchLaunchConfiguration()
        let payload = Data((normalizedCommands + ["quit"]).joined(separator: "\n").appending("\n").utf8)
        let result = try await runProcess(
            executablePath: launch.executablePath,
            arguments: launch.arguments,
            environment: launch.environment,
            stdin: payload
        )

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

    private func runSSHCommandOutput(_ command: String) async throws -> String {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let launch = try await makeSSHLaunchConfiguration(command: trimmed)
        let result = try await runProcess(
            executablePath: launch.executablePath,
            arguments: launch.arguments,
            environment: launch.environment,
            stdin: nil
        )

        let stdoutText = String(decoding: result.stdout, as: UTF8.self)
        let stderrText = String(decoding: result.stderr, as: UTF8.self)

        guard result.status == 0 else {
            let message = [stderrText, stdoutText]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first(where: { !$0.isEmpty }) ?? "ssh exited with status \(result.status)"
            throw SSHError.connectionFailed(message)
        }

        return stdoutText
    }

    private func runProcess(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        stdin: Data?
    ) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
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
                let stdinPipe = Pipe()
                process.standardInput = stdinPipe

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: SSHError.connectionFailed(error.localizedDescription))
                    return
                }

                if let stdin, !stdin.isEmpty {
                    do {
                        try stdinPipe.fileHandleForWriting.write(contentsOf: stdin)
                    } catch {
                        process.terminate()
                        continuation.resume(throwing: SSHError.connectionFailed("stdin write failed: \(error.localizedDescription)"))
                        return
                    }
                }

                try? stdinPipe.fileHandleForWriting.close()

                process.waitUntilExit()
                let stdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()

                try? stdoutPipe.fileHandleForReading.close()
                try? stderrPipe.fileHandleForReading.close()

                continuation.resume(
                    returning: ProcessResult(
                        status: process.terminationStatus,
                        stdout: stdout,
                        stderr: stderr
                    )
                )
            }
        }
    }

    private func makeSFTPBatchLaunchConfiguration() async throws -> BatchLaunchConfiguration {
        if host.auth.method == .password {
            return try await makePasswordLaunchConfiguration(
                baseExecutable: "/usr/bin/sftp",
                baseArguments: Self.makeSFTPArguments(for: host)
            )
        }
        return BatchLaunchConfiguration(
            executablePath: "/usr/bin/sftp",
            arguments: Self.makeSFTPArguments(for: host),
            environment: [:]
        )
    }

    private func makeSSHLaunchConfiguration(command: String) async throws -> BatchLaunchConfiguration {
        let sshArgs = Self.makeSSHArguments(for: host) + [command]
        if host.auth.method == .password {
            return try await makePasswordLaunchConfiguration(
                baseExecutable: "/usr/bin/ssh",
                baseArguments: sshArgs
            )
        }
        return BatchLaunchConfiguration(
            executablePath: "/usr/bin/ssh",
            arguments: sshArgs,
            environment: [:]
        )
    }

    private func makePasswordLaunchConfiguration(
        baseExecutable: String,
        baseArguments: [String]
    ) async throws -> BatchLaunchConfiguration {
        let sshpassCandidates = [
            "/opt/homebrew/bin/sshpass",
            "/usr/local/bin/sshpass",
            "/usr/bin/sshpass",
        ]

        guard let sshpassPath = sshpassCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw SFTPClientError.unsupportedOperation("password-auth-sftp-requires-sshpass")
        }

        guard let passwordRef = host.auth.passwordReference, !passwordRef.isEmpty else {
            throw SFTPClientError.unsupportedOperation("password-reference-missing")
        }
        guard let password = await credentialStore.secret(for: passwordRef), !password.isEmpty else {
            throw SFTPClientError.unsupportedOperation("password-secret-missing")
        }

        return BatchLaunchConfiguration(
            executablePath: sshpassPath,
            arguments: ["-e", baseExecutable] + baseArguments,
            environment: ["SSHPASS": password]
        )
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

    private func listViaSSH(path: String) async throws -> [RemoteFileEntry] {
        let command = "LC_ALL=C ls -1Ap -- \(Self.quoteShellArgument(path))"
        let output = try await runSSHCommandOutput(command)
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

    private static func quoteBatchArgument(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static func quoteShellArgument(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }
}
