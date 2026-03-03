import AppKit
import Foundation
import Testing
@testable import RemoraTerminal

@MainActor
struct TerminalInputTests {
    private final class DataCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [Data] = []

        func append(_ data: Data) {
            lock.lock()
            storage.append(data)
            lock.unlock()
        }

        var values: [Data] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    @Test
    func terminalViewInsertTextSendsUTF8ForCJK() {
        let view = TerminalView(rows: 4, columns: 40)
        let capture = DataCapture()
        view.onInput = { capture.append($0) }

        view.insertText("中文输入", replacementRange: NSRange(location: NSNotFound, length: 0))

        #expect(capture.values.count == 1)
        #expect(String(data: capture.values[0], encoding: .utf8) == "中文输入")
    }

    @Test
    func inputMapperCommandUsesApplicationCursorMode() {
        let mapper = TerminalInputMapper()

        mapper.applicationCursorKeysEnabled = false
        let normal = mapper.map(command: #selector(NSResponder.moveUp(_:)))
        #expect(normal == Data("\u{1B}[A".utf8))

        mapper.applicationCursorKeysEnabled = true
        let application = mapper.map(command: #selector(NSResponder.moveUp(_:)))
        #expect(application == Data("\u{1B}OA".utf8))
    }
}
