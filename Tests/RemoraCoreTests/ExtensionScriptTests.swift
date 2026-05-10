import Foundation
import Testing
@testable import RemoraCore

struct ExtensionScriptTests {
    @Test
    func extensionScriptCodableRoundTripPreservesFieldsAndClampsTimeout() throws {
        let script = ExtensionScript(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            name: "Deploy",
            language: .python,
            body: "print('ok')",
            scope: .host("host-1"),
            timeoutSeconds: 99_999,
            requireConfirmation: false,
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 20),
            isEnabled: false
        )

        let data = try JSONEncoder().encode(script)
        let decoded = try JSONDecoder().decode(ExtensionScript.self, from: data)

        #expect(decoded.id == script.id)
        #expect(decoded.name == "Deploy")
        #expect(decoded.language == .python)
        #expect(decoded.body == "print('ok')")
        #expect(decoded.scope == .host("host-1"))
        #expect(decoded.timeoutSeconds == ExtensionScript.maximumTimeoutSeconds)
        #expect(decoded.requireConfirmation == false)
        #expect(decoded.createdAt == Date(timeIntervalSince1970: 10))
        #expect(decoded.updatedAt == Date(timeIntervalSince1970: 20))
        #expect(decoded.isEnabled == false)
    }

    @Test
    func extensionScriptStoreLoadSavePersistsScripts() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("extension-script-store-\(UUID().uuidString)", isDirectory: true)
        let fileURL = root.appendingPathComponent("extension-scripts.json", isDirectory: false)
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        let store = ExtensionScriptStore(fileURL: fileURL)
        let script = ExtensionScript(name: "Hello", body: "echo hello", updatedAt: Date(timeIntervalSince1970: 10))

        #expect(try store.load().isEmpty)
        try store.save([script])

        let loaded = try store.load()
        #expect(loaded.count == 1)
        #expect(loaded.first?.name == "Hello")
        #expect(loaded.first?.body == "echo hello")
    }

    @Test
    func runnerCapturesShellStdoutAndExitCode() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("extension-script-runner-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        let runner = ExtensionScriptRunner(temporaryDirectoryURL: root)
        let script = ExtensionScript(
            name: "Echo",
            language: .shell,
            body: "echo remora-script\n",
            timeoutSeconds: 5
        )

        let result = await runner.run(script: script)

        #expect(result.status == .success)
        #expect(result.exitCode == 0)
        #expect(result.stdout.contains("remora-script"))
    }

    @Test
    func runnerInjectsSafeHostEnvironmentVariables() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("extension-script-env-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        let runner = ExtensionScriptRunner(temporaryDirectoryURL: root)
        let script = ExtensionScript(
            name: "Env",
            language: .shell,
            body: """
            echo "$REMORA_HOST_ID"
            echo "$REMORA_HOST_NAME"
            echo "$REMORA_USER@$REMORA_HOST:$REMORA_PORT"
            test -f "$REMORA_CONTEXT_JSON"
            """,
            timeoutSeconds: 5
        )
        let context = ExtensionScriptRunContext(
            host: ExtensionScriptHostContext(
                id: "host-123",
                name: "Production",
                host: "192.0.2.10",
                port: 2222,
                user: "root",
                authMethod: "key",
                keyPath: "/Users/me/.ssh/id_ed25519",
                localDownloadDirectory: "/Users/me/Downloads"
            )
        )

        let result = await runner.run(script: script, context: context)

        #expect(result.status == .success)
        #expect(result.stdout.contains("host-123"))
        #expect(result.stdout.contains("Production"))
        #expect(result.stdout.contains("root@192.0.2.10:2222"))
    }

    @Test
    func runnerTimesOutLongShellScript() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("extension-script-timeout-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        let runner = ExtensionScriptRunner(temporaryDirectoryURL: root)
        let script = ExtensionScript(
            name: "Sleep",
            language: .shell,
            body: "sleep 5\n",
            timeoutSeconds: 1
        )

        let result = await runner.run(script: script)

        #expect(result.status == .timedOut)
    }
}
