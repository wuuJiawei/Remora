import Foundation

public enum ExtensionScriptRunnerError: Error, Equatable, Sendable {
    case invalidScriptBody
    case interpreterMissing(String)
}

public final class ExtensionScriptExecution: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var isCancelled = false

    public init() {}

    public func cancel() {
        lock.lock()
        isCancelled = true
        let runningProcess = process
        lock.unlock()

        if let runningProcess, runningProcess.isRunning {
            runningProcess.terminate()
        }
    }

    fileprivate func attach(process: Process) {
        lock.lock()
        self.process = process
        let shouldCancel = isCancelled
        lock.unlock()

        if shouldCancel, process.isRunning {
            process.terminate()
        }
    }

    fileprivate func clear(process: Process) {
        lock.lock()
        if self.process === process {
            self.process = nil
        }
        lock.unlock()
    }

    fileprivate var cancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isCancelled
    }
}

public struct ExtensionScriptRunner {
    private let fileManager: FileManager
    private let temporaryDirectoryURL: URL
    private let environment: [String: String]

    public init(
        fileManager: FileManager = .default,
        temporaryDirectoryURL: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.fileManager = fileManager
        self.temporaryDirectoryURL = temporaryDirectoryURL ?? fileManager.temporaryDirectory
        self.environment = environment
    }

    public func run(
        script: ExtensionScript,
        context: ExtensionScriptRunContext = .init(),
        execution: ExtensionScriptExecution = ExtensionScriptExecution()
    ) async -> ExtensionScriptRunResult {
        let startedAt = Date()
        var tempRoot: URL?
        defer {
            if let tempRoot {
                try? fileManager.removeItem(at: tempRoot)
            }
        }

        do {
            let trimmedBody = script.body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmedBody.isEmpty == false else {
                throw ExtensionScriptRunnerError.invalidScriptBody
            }

            let interpreter = try interpreterCommand(for: script.language)
            let root = temporaryDirectoryURL.appendingPathComponent("remora-extension-\(UUID().uuidString)", isDirectory: true)
            tempRoot = root
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

            let scriptFileURL = root.appendingPathComponent("script.\(script.language.fileExtension)", isDirectory: false)
            try script.body.write(to: scriptFileURL, atomically: true, encoding: .utf8)
            try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptFileURL.path)

            let contextURL = root.appendingPathComponent("context.json", isDirectory: false)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(context).write(to: contextURL, options: [.atomic])
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: contextURL.path)

            let process = Process()
            process.executableURL = interpreter.executableURL
            process.arguments = interpreter.arguments + [scriptFileURL.path]
            process.environment = makeEnvironment(context: context, contextFileURL: contextURL)

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            let outputCollector = PipeOutputCollector(stdout: stdoutPipe, stderr: stderrPipe)
            outputCollector.start()

            execution.attach(process: process)
            try process.run()

            let didTimeOut = await waitForExitOrTimeout(
                process: process,
                timeoutSeconds: ExtensionScript.clampedTimeoutSeconds(script.timeoutSeconds)
            )
            if didTimeOut, process.isRunning {
                process.terminate()
            }

            process.waitUntilExit()
            execution.clear(process: process)

            let output = outputCollector.stopAndRead()
            let duration = Date().timeIntervalSince(startedAt)
            let exitCode = process.terminationStatus

            if execution.cancelled {
                return ExtensionScriptRunResult(
                    status: .cancelled,
                    exitCode: exitCode,
                    stdout: output.stdout,
                    stderr: output.stderr,
                    duration: duration,
                    errorMessage: nil
                )
            }

            if didTimeOut {
                return ExtensionScriptRunResult(
                    status: .timedOut,
                    exitCode: exitCode,
                    stdout: output.stdout,
                    stderr: output.stderr,
                    duration: duration,
                    errorMessage: nil
                )
            }

            return ExtensionScriptRunResult(
                status: exitCode == 0 ? .success : .failed,
                exitCode: exitCode,
                stdout: output.stdout,
                stderr: output.stderr,
                duration: duration,
                errorMessage: nil
            )
        } catch let error as ExtensionScriptRunnerError {
            return failureResult(for: error, startedAt: startedAt)
        } catch {
            return ExtensionScriptRunResult(
                status: .failed,
                exitCode: nil,
                stdout: "",
                stderr: "",
                duration: Date().timeIntervalSince(startedAt),
                errorMessage: error.localizedDescription
            )
        }
    }

    private func failureResult(for error: ExtensionScriptRunnerError, startedAt: Date) -> ExtensionScriptRunResult {
        switch error {
        case .invalidScriptBody:
            return ExtensionScriptRunResult(
                status: .failed,
                exitCode: nil,
                stdout: "",
                stderr: "",
                duration: Date().timeIntervalSince(startedAt),
                errorMessage: "Script body is empty."
            )
        case .interpreterMissing(let command):
            return ExtensionScriptRunResult(
                status: .interpreterMissing,
                exitCode: nil,
                stdout: "",
                stderr: "",
                duration: Date().timeIntervalSince(startedAt),
                errorMessage: "Required interpreter is not available: \(command)."
            )
        }
    }

    private func interpreterCommand(for language: ExtensionScriptLanguage) throws -> InterpreterCommand {
        switch language {
        case .shell:
            if fileManager.isExecutableFile(atPath: "/bin/zsh") {
                return InterpreterCommand(executableURL: URL(fileURLWithPath: "/bin/zsh"), arguments: [])
            }
            if fileManager.isExecutableFile(atPath: "/bin/bash") {
                return InterpreterCommand(executableURL: URL(fileURLWithPath: "/bin/bash"), arguments: [])
            }
            throw ExtensionScriptRunnerError.interpreterMissing("/bin/zsh")
        case .python:
            return try envInterpreter("python3")
        case .javascript:
            return try envInterpreter("node")
        case .swift:
            return try envInterpreter("swift")
        }
    }

    private func envInterpreter(_ name: String) throws -> InterpreterCommand {
        guard fileManager.isExecutableFile(atPath: "/usr/bin/env") else {
            throw ExtensionScriptRunnerError.interpreterMissing("/usr/bin/env \(name)")
        }
        guard canResolveInterpreter(name) else {
            throw ExtensionScriptRunnerError.interpreterMissing(name)
        }
        return InterpreterCommand(executableURL: URL(fileURLWithPath: "/usr/bin/env"), arguments: [name])
    }

    private func canResolveInterpreter(_ name: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["which", name]
        process.environment = environment
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func makeEnvironment(context: ExtensionScriptRunContext, contextFileURL: URL) -> [String: String] {
        var environment = environment
        environment["REMORA_CONTEXT_JSON"] = contextFileURL.path

        guard let host = context.host else { return environment }
        if let value = host.id { environment["REMORA_HOST_ID"] = value }
        if let value = host.name { environment["REMORA_HOST_NAME"] = value }
        if let value = host.host { environment["REMORA_HOST"] = value }
        if let value = host.port { environment["REMORA_PORT"] = "\(value)" }
        if let value = host.user { environment["REMORA_USER"] = value }
        if let value = host.authMethod { environment["REMORA_AUTH_METHOD"] = value }
        if let value = host.keyPath { environment["REMORA_KEY_PATH"] = value }
        if let value = host.localDownloadDirectory { environment["REMORA_LOCAL_DOWNLOAD_DIR"] = value }
        return environment
    }

    private func waitForExitOrTimeout(process: Process, timeoutSeconds: Int) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                while process.isRunning {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
                return false
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds) * 1_000_000_000)
                return process.isRunning
            }

            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }
}

private struct InterpreterCommand: Sendable {
    var executableURL: URL
    var arguments: [String]
}

private final class PipeOutputCollector: @unchecked Sendable {
    private let stdout: Pipe
    private let stderr: Pipe
    private let lock = NSLock()
    private var stdoutData = Data()
    private var stderrData = Data()

    init(stdout: Pipe, stderr: Pipe) {
        self.stdout = stdout
        self.stderr = stderr
    }

    func start() {
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.append(handle.availableData, toStdout: true)
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.append(handle.availableData, toStdout: false)
        }
    }

    func stopAndRead() -> (stdout: String, stderr: String) {
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        append(stdout.fileHandleForReading.readDataToEndOfFile(), toStdout: true)
        append(stderr.fileHandleForReading.readDataToEndOfFile(), toStdout: false)

        lock.lock()
        let stdoutData = self.stdoutData
        let stderrData = self.stderrData
        lock.unlock()

        return (
            String(data: stdoutData, encoding: .utf8) ?? "",
            String(data: stderrData, encoding: .utf8) ?? ""
        )
    }

    private func append(_ data: Data, toStdout: Bool) {
        guard data.isEmpty == false else { return }
        lock.lock()
        if toStdout {
            stdoutData.append(data)
        } else {
            stderrData.append(data)
        }
        lock.unlock()
    }
}
