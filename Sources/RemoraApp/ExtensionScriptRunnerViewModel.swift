import Foundation
import RemoraCore

@MainActor
final class ExtensionScriptRunnerViewModel: ObservableObject {
    enum RunState: Equatable {
        case idle
        case awaitingConfirmation
        case running
        case finished
    }

    @Published private(set) var script: ExtensionScript?
    @Published private(set) var host: RemoraCore.Host?
    @Published private(set) var state: RunState = .idle
    @Published private(set) var result: ExtensionScriptRunResult?

    private var execution: ExtensionScriptExecution?
    private var runTask: Task<Void, Never>?

    var isPresented: Bool {
        script != nil
    }

    var isRunning: Bool {
        state == .running
    }

    func prepare(script: ExtensionScript, host: RemoraCore.Host?) {
        cancel()
        self.script = script
        self.host = host
        self.result = nil
        state = script.requireConfirmation ? .awaitingConfirmation : .running
        if script.requireConfirmation == false {
            start()
        }
    }

    func start() {
        guard let script, state != .running else { return }
        state = .running
        result = nil

        let execution = ExtensionScriptExecution()
        self.execution = execution
        let context = Self.makeRunContext(host: host)

        runTask = Task { [weak self] in
            let runner = ExtensionScriptRunner()
            let result = await runner.run(script: script, context: context, execution: execution)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.result = result
                self?.state = .finished
                self?.execution = nil
                self?.runTask = nil
            }
        }
    }

    func cancel() {
        execution?.cancel()
        runTask?.cancel()
        execution = nil
        runTask = nil
        if state == .running {
            result = ExtensionScriptRunResult(
                status: .cancelled,
                exitCode: nil,
                stdout: result?.stdout ?? "",
                stderr: result?.stderr ?? "",
                duration: 0,
                errorMessage: nil
            )
            state = .finished
        }
    }

    func dismiss() {
        cancel()
        script = nil
        host = nil
        state = .idle
        result = nil
    }

    static func makeRunContext(host: RemoraCore.Host?) -> ExtensionScriptRunContext {
        let downloadDirectory = AppSettings.resolvedDownloadDirectoryURL(
            from: AppPreferences.shared.snapshot.downloadDirectoryPath
        ).path

        guard let host else {
            return ExtensionScriptRunContext(
                host: ExtensionScriptHostContext(
                    localDownloadDirectory: downloadDirectory
                )
            )
        }

        return ExtensionScriptRunContext(
            host: ExtensionScriptHostContext(
                id: host.id.uuidString,
                name: host.name,
                host: host.address,
                port: host.port,
                user: host.username,
                authMethod: host.auth.method.rawValue,
                keyPath: host.auth.method == .privateKey ? host.auth.keyReference : nil,
                localDownloadDirectory: downloadDirectory
            )
        )
    }
}
