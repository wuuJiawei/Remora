import Foundation
import Darwin
import Testing
@testable import RemoraCore

struct LocalShellClientTests {
    private actor OutputCollector {
        private var buffer = Data()

        func append(_ data: Data) {
            buffer.append(data)
        }

        func text() -> String {
            String(decoding: buffer, as: UTF8.self)
        }
    }

    private func waitUntil(
        timeout: TimeInterval,
        interval: TimeInterval = 0.05,
        condition: @escaping () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() {
                return true
            }
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
        return await condition()
    }

    @Test
    func interruptTargetsPreferForegroundProcessGroupAndFallbackToShell() {
        let targets = LocalShellSession.interruptSignalTargets(
            foregroundProcessGroup: 2345,
            shellProcessID: 3456,
            shellProcessGroup: 2345,
            appProcessGroup: 1234
        )

        #expect(
            targets == [
                .processGroup(2345),
                .process(3456),
            ]
        )
    }

    @Test
    func interruptTargetsAvoidApplicationProcessGroup() {
        let targets = LocalShellSession.interruptSignalTargets(
            foregroundProcessGroup: 1234,
            shellProcessID: 3456,
            shellProcessGroup: 1234,
            appProcessGroup: 1234
        )

        #expect(targets == [.process(3456)])
    }

    @Test
    func interruptTargetsCanUseShellProcessGroupWhenForegroundIsMissing() {
        let targets = LocalShellSession.interruptSignalTargets(
            foregroundProcessGroup: nil,
            shellProcessID: 4567,
            shellProcessGroup: 5678,
            appProcessGroup: 1234
        )

        #expect(
            targets == [
                .processGroup(5678),
                .process(4567),
            ]
        )
    }

    @Test
    func localShellUsesUTF8LocaleForChineseInputAndFilenames() async throws {
        let client = LocalShellClient()
        let host = Host(
            name: "local",
            address: "127.0.0.1",
            username: NSUserName(),
            auth: HostAuth(method: .agent)
        )

        try await client.connect(to: host)
        let shell = try await client.openShell(pty: .init(columns: 120, rows: 30))
        let output = OutputCollector()
        shell.onOutput = { data in
            Task {
                await output.append(data)
            }
        }

        try await shell.start()
        defer {
            Task {
                await shell.stop()
                await client.disconnect()
            }
        }

        let ready = await waitUntil(timeout: 5.0) {
            let text = await output.text()
            return text.contains("Connected to local zsh shell")
        }
        #expect(ready, "Expected local shell to start.")
        guard ready else { return }

        try await shell.write(Data("locale charmap\n".utf8))
        let hasUTF8Charmap = await waitUntil(timeout: 5.0) {
            let text = await output.text()
            return text.contains("UTF-8")
        }
        #expect(hasUTF8Charmap, "Local shell should advertise UTF-8 charmap.")

        let tempDirectoryName = "remora-local-shell-\(UUID().uuidString)"
        let chineseFilename = "中文文件"
        let setupCommand = """
        mkdir -p -- '\(tempDirectoryName)' && cd -- '\(tempDirectoryName)' && touch -- '\(chineseFilename)' && ls\n
        """
        try await shell.write(Data(setupCommand.utf8))

        let listedChineseFilename = await waitUntil(timeout: 5.0) {
            let text = await output.text()
            return text.contains(chineseFilename)
        }
        #expect(listedChineseFilename, "ls output should preserve Chinese filenames in local shell.")

        let chineseCommand = "中文命令"
        try await shell.write(Data("\(chineseCommand)\n".utf8))

        let echoedChineseCommand = await waitUntil(timeout: 5.0) {
            let text = await output.text()
            return text.contains(chineseCommand)
        }
        #expect(echoedChineseCommand, "Typed Chinese input should be echoed back without mojibake.")

        let cleanupCommand = "cd .. && rm -rf -- '\(tempDirectoryName)'\n"
        try? await shell.write(Data(cleanupCommand.utf8))
    }
}
