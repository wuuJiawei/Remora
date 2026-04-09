import AppKit
import Foundation
import SwiftUI
import Testing
import RemoraCore
@testable import RemoraApp

@Suite(.serialized)
@MainActor
struct QuickCommandExecutionTests {
    @Test
    func executionRequestUsesDirectSendForSingleLineCommand() {
        let command = HostQuickCommand(name: "List", command: "ls -la")

        #expect(
            command.executionRequest()
                == HostQuickCommand.ExecutionRequest(text: "ls -la", usesBracketedPaste: false)
        )
    }

    @Test
    func executionRequestPreservesInternalNewlinesAndUsesBracketedPaste() {
        let command = HostQuickCommand(
            name: "Deploy",
            command: "cd /srv/app\n./deploy.sh\nsystemctl status remora"
        )

        #expect(
            command.executionRequest()
                == HostQuickCommand.ExecutionRequest(
                    text: "cd /srv/app\n./deploy.sh\nsystemctl status remora",
                    usesBracketedPaste: true
                )
        )
    }

    @Test
    func executionRequestPastesMultilineCommandAsSingleBlockBeforeExecuting() async {
        let recorder = TerminalCommandRecorder()
        let manager = SessionManager(
            sshClientFactory: {
                RecordingSSHClient(recorder: recorder, initialDirectory: "/srv/app")
            }
        )
        let runtime = TerminalRuntime(
            localSessionManager: manager,
            sshSessionManager: manager,
            remoteShellIntegrationInstaller: { _ in }
        )
        let command = HostQuickCommand(
            name: "Deploy",
            command: "cd '/srv/app/releases'\n./deploy.sh"
        )

        runtime.connectSSH(address: "127.0.0.1", port: 22, username: "deploy", privateKeyPath: nil)
        let connected = await waitUntil(timeout: 2.0) {
            runtime.connectionState.contains("Connected (SSH)")
        }
        #expect(connected)
        guard connected else { return }

        guard let request = command.executionRequest() else {
            Issue.record("Expected multiline quick command execution request.")
            return
        }

        await recorder.reset()
        runtime.sendText(request.text, bracketedPaste: request.usesBracketedPaste)
        runtime.sendText("\n")

        let executed = await waitUntilAsync(timeout: 2.0) {
            await recorder.commands == ["cd '/srv/app/releases'\n./deploy.sh"]
        }
        #expect(executed, "Multiline quick command should stay as one pasted block until the final execute newline.")

        let rawPayload = await recorder.rawWrites.joined()
        #expect(rawPayload == "\u{001B}[200~\(request.text)\u{001B}[201~\n")
        runtime.disconnect()
    }

    @Test
    func quickCommandEditorUsesMultilineEditorInLightAndDarkAppearances() {
        assertQuickCommandEditorUsesTextView(for: .aqua)
        assertQuickCommandEditorUsesTextView(for: .darkAqua)
    }

    private func assertQuickCommandEditorUsesTextView(for appearanceName: NSAppearance.Name) {
        let host = Host(
            name: "prod-api",
            address: "127.0.0.1",
            username: "deploy",
            auth: HostAuth(method: .agent)
        )
        let hostingView = NSHostingView(
            rootView: HostQuickCommandEditorSheet(
                host: host,
                commands: [
                    HostQuickCommand(name: "Deploy", command: "cd /srv/app\n./deploy.sh")
                ],
                editingCommandID: nil,
                nameDraft: .constant("Deploy"),
                commandDraft: .constant("cd /srv/app\n./deploy.sh"),
                validationMessage: nil,
                onClose: {},
                onSave: {},
                onStartEdit: { _ in },
                onDelete: { _ in },
                onCancelEdit: {}
            )
        )

        hostingView.appearance = NSAppearance(named: appearanceName)
        hostingView.frame = NSRect(x: 0, y: 0, width: 620, height: 520)
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        let textViews = recursiveSubviews(in: hostingView).compactMap { $0 as? NSTextView }
        #expect(
            textViews.contains(where: { $0.isEditable && $0.string.contains("./deploy.sh") }),
            "Quick command editor should render an editable multiline text view in \(appearanceName.rawValue)."
        )
    }

    private func recursiveSubviews(in root: NSView) -> [NSView] {
        root.subviews + root.subviews.flatMap { recursiveSubviews(in: $0) }
    }

    private func waitUntil(timeout: TimeInterval, condition: @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return condition()
    }

    private func waitUntilAsync(timeout: TimeInterval, condition: @escaping () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() {
                return true
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return await condition()
    }
}
