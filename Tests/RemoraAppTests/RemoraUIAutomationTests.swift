import AppKit
import ApplicationServices
import Foundation
import Testing

@Suite(.serialized)
@MainActor
struct RemoraUIAutomationTests {
    @Test
    func fileManagerHeaderTogglesExpandAndCollapse() throws {
        guard ProcessInfo.processInfo.environment["REMORA_RUN_UI_TESTS"] == "1" else {
            return
        }

        #expect(AXIsProcessTrusted(), "Grant Accessibility permission to the terminal running tests.")
        guard AXIsProcessTrusted() else { return }

        let appURL = try locateRemoraAppBinary()
        let process = Process()
        process.executableURL = appURL
        process.arguments = []
        try process.run()
        defer {
            if process.isRunning {
                process.terminate()
            }
        }

        guard waitUntil(timeout: 8, {
            NSRunningApplication(processIdentifier: process.processIdentifier) != nil
        }) else {
            Issue.record("RemoraApp did not launch in time.")
            return
        }

        NSRunningApplication(processIdentifier: process.processIdentifier)?
            .activate(options: [.activateAllWindows])

        let appElement = AXUIElementCreateApplication(process.processIdentifier)

        guard let fileManagerButton = waitForElement(
            in: appElement,
            timeout: 8,
            matching: { element in
                role(of: element) == kAXButtonRole as String && title(of: element) == "File Manager"
            }
        ) else {
            Issue.record("Could not find File Manager header button.")
            return
        }

        #expect(findElement(in: appElement, matching: { title(of: $0) == "Refresh" }) == nil)

        _ = AXUIElementPerformAction(fileManagerButton, kAXPressAction as CFString)

        let expanded = waitUntil(timeout: 5, {
            findElement(in: appElement, matching: { title(of: $0) == "Refresh" }) != nil
        })
        #expect(expanded, "File Manager should expand and show Refresh button.")

        _ = AXUIElementPerformAction(fileManagerButton, kAXPressAction as CFString)

        let collapsed = waitUntil(timeout: 5, {
            findElement(in: appElement, matching: { title(of: $0) == "Refresh" }) == nil
        })
        #expect(collapsed, "File Manager should collapse and hide Refresh button.")
    }

    @Test
    func sidebarGroupTogglesThreadsVisibility() throws {
        guard ProcessInfo.processInfo.environment["REMORA_RUN_UI_TESTS"] == "1" else {
            return
        }

        #expect(AXIsProcessTrusted(), "Grant Accessibility permission to the terminal running tests.")
        guard AXIsProcessTrusted() else { return }

        let appURL = try locateRemoraAppBinary()
        let process = Process()
        process.executableURL = appURL
        process.arguments = []
        try process.run()
        defer {
            if process.isRunning {
                process.terminate()
            }
        }

        guard waitUntil(timeout: 8, {
            NSRunningApplication(processIdentifier: process.processIdentifier) != nil
        }) else {
            Issue.record("RemoraApp did not launch in time.")
            return
        }

        NSRunningApplication(processIdentifier: process.processIdentifier)?
            .activate()

        let appElement = AXUIElementCreateApplication(process.processIdentifier)

        guard let groupHeaderButton = waitForElement(
            in: appElement,
            timeout: 8,
            matching: { element in
                role(of: element) == kAXButtonRole as String && title(of: element) == "Production"
            }
        ) else {
            Issue.record("Could not find 'Production' group header button.")
            return
        }

        let hostVisibleInitially = waitUntil(timeout: 5, {
            findElement(in: appElement, matching: { title(of: $0) == "prod-api" }) != nil
        })
        #expect(hostVisibleInitially, "Expected prod-api row to be visible before collapsing group.")

        _ = AXUIElementPerformAction(groupHeaderButton, kAXPressAction as CFString)

        let hostHiddenAfterCollapse = waitUntil(timeout: 5, {
            findElement(in: appElement, matching: { title(of: $0) == "prod-api" }) == nil
        })
        #expect(hostHiddenAfterCollapse, "Expected prod-api row to be hidden after collapsing group.")

        _ = AXUIElementPerformAction(groupHeaderButton, kAXPressAction as CFString)

        let hostVisibleAfterExpand = waitUntil(timeout: 5, {
            findElement(in: appElement, matching: { title(of: $0) == "prod-api" }) != nil
        })
        #expect(hostVisibleAfterExpand, "Expected prod-api row to be visible after expanding group.")
    }

    @Test
    func terminalAcceptsKeyboardInputAndShowsCommandOutput() throws {
        guard ProcessInfo.processInfo.environment["REMORA_RUN_UI_TESTS"] == "1" else {
            return
        }

        #expect(AXIsProcessTrusted(), "Grant Accessibility permission to the terminal running tests.")
        guard AXIsProcessTrusted() else { return }

        let appURL = try locateRemoraAppBinary()
        let process = Process()
        process.executableURL = appURL
        process.arguments = []
        try process.run()
        defer {
            if process.isRunning {
                process.terminate()
            }
        }

        guard waitUntil(timeout: 8, {
            NSRunningApplication(processIdentifier: process.processIdentifier) != nil
        }) else {
            Issue.record("RemoraApp did not launch in time.")
            return
        }

        NSRunningApplication(processIdentifier: process.processIdentifier)?
            .activate()

        let appElement = AXUIElementCreateApplication(process.processIdentifier)
        let connected = waitUntil(timeout: 8, {
            findElement(in: appElement, matching: { title(of: $0) == "Connected (Mock)" }) != nil
        })
        #expect(connected, "Expected mock terminal connection to be established.")
        guard connected else { return }

        guard let transcriptElement = waitForElement(
            in: appElement,
            timeout: 8,
            matching: { element in
                identifier(of: element) == "terminal-transcript"
            }
        ) else {
            Issue.record("Could not find transcript accessibility element.")
            return
        }

        let hasInitialTranscript = waitUntil(timeout: 8, {
            guard let snapshot = transcriptText(from: transcriptElement) else { return false }
            return snapshot.contains("Type commands and press Enter.")
        })
        if !hasInitialTranscript {
            let snapshot = transcriptText(from: transcriptElement) ?? ""
            Issue.record("Initial transcript snapshot: \(snapshot)")
            Issue.record("Transcript AX summary: \(accessibilitySummary(of: transcriptElement))")
        }
        #expect(hasInitialTranscript, "Terminal should render initial prompt output.")
        guard hasInitialTranscript else { return }

        guard let terminal = waitForElement(
            in: appElement,
            timeout: 6,
            matching: { element in
                identifier(of: element) == "terminal-view"
            }
        ) else {
            Issue.record("Could not find terminal accessibility element.")
            return
        }

        guard let frame = frame(of: terminal) else {
            Issue.record("Could not read terminal frame for click focus.")
            return
        }

        _ = AXUIElementSetAttributeValue(
            terminal,
            kAXFocusedAttribute as CFString,
            kCFBooleanTrue
        )
        click(point: CGPoint(x: frame.midX, y: frame.midY))
        typeText("whoami\r")

        var lastValue = ""
        let hasOutput = waitUntil(timeout: 8, {
            guard let value = transcriptText(from: transcriptElement) else {
                return false
            }
            lastValue = value
            return value.range(of: #"whoami\s*remora"#, options: .regularExpression) != nil
        })
        if !hasOutput {
            Issue.record("Terminal accessibility value after typing: \(lastValue)")
            Issue.record("Terminal AX summary: \(accessibilitySummary(of: terminal))")
        }
        #expect(hasOutput, "Terminal should accept keyboard input and render command output.")

        let hasLineBreak = lastValue.range(of: #"whoami\s*\n\s*remora"#, options: .regularExpression) != nil
        #expect(hasLineBreak, "Command output should appear on a new line after Enter.")
    }

    @Test
    func terminalArrowKeysDoNotCorruptPrompt() throws {
        guard ProcessInfo.processInfo.environment["REMORA_RUN_UI_TESTS"] == "1" else {
            return
        }

        #expect(AXIsProcessTrusted(), "Grant Accessibility permission to the terminal running tests.")
        guard AXIsProcessTrusted() else { return }

        let appURL = try locateRemoraAppBinary()
        let process = Process()
        process.executableURL = appURL
        process.arguments = []
        try process.run()
        defer {
            if process.isRunning {
                process.terminate()
            }
        }

        guard waitUntil(timeout: 8, {
            NSRunningApplication(processIdentifier: process.processIdentifier) != nil
        }) else {
            Issue.record("RemoraApp did not launch in time.")
            return
        }

        NSRunningApplication(processIdentifier: process.processIdentifier)?
            .activate()

        let appElement = AXUIElementCreateApplication(process.processIdentifier)
        let connected = waitUntil(timeout: 8, {
            findElement(in: appElement, matching: { title(of: $0) == "Connected (Mock)" }) != nil
        })
        #expect(connected, "Expected mock terminal connection to be established.")
        guard connected else { return }

        guard let transcriptElement = waitForElement(
            in: appElement,
            timeout: 8,
            matching: { element in
                identifier(of: element) == "terminal-transcript"
            }
        ) else {
            Issue.record("Could not find transcript accessibility element.")
            return
        }

        guard let terminal = waitForElement(
            in: appElement,
            timeout: 6,
            matching: { element in
                identifier(of: element) == "terminal-view"
            }
        ) else {
            Issue.record("Could not find terminal accessibility element.")
            return
        }

        guard let frame = frame(of: terminal) else {
            Issue.record("Could not read terminal frame for click focus.")
            return
        }

        click(point: CGPoint(x: frame.midX, y: frame.midY))
        pressLeftArrow(repeatCount: 25)
        typeText("whoami\r")

        var snapshot = ""
        let hasValidOutput = waitUntil(timeout: 8, {
            guard let value = transcriptText(from: transcriptElement) else { return false }
            snapshot = value
            return value.range(of: #"whoami\s*\n\s*remora"#, options: .regularExpression) != nil
        })

        if !hasValidOutput {
            Issue.record("Transcript after arrow-input: \(snapshot)")
        }

        #expect(hasValidOutput, "Arrow keys should not move input cursor into prompt prefix.")
        #expect(!snapshot.contains("\u{1B}"), "Transcript should not include raw ANSI arrow sequences.")
    }

    private func locateRemoraAppBinary() throws -> URL {
        if let custom = ProcessInfo.processInfo.environment["REMORA_APP_BINARY"], !custom.isEmpty {
            let url = URL(fileURLWithPath: custom)
            if FileManager.default.isExecutableFile(atPath: url.path) {
                return url
            }
        }

        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let candidates = [
            root.appendingPathComponent(".build/debug/RemoraApp"),
            root.appendingPathComponent(".build/arm64-apple-macosx/debug/RemoraApp"),
            root.appendingPathComponent(".build/x86_64-apple-macosx/debug/RemoraApp"),
        ]

        if let hit = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) {
            return hit
        }

        throw NSError(
            domain: "RemoraUIAutomationTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Cannot locate RemoraApp binary. Set REMORA_APP_BINARY to the app executable path."]
        )
    }

    private func waitForElement(
        in appElement: AXUIElement,
        timeout: TimeInterval,
        matching: (AXUIElement) -> Bool
    ) -> AXUIElement? {
        var found: AXUIElement?
        let ok = waitUntil(timeout: timeout) {
            found = findElement(in: appElement, matching: matching)
            return found != nil
        }
        return ok ? found : nil
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return condition()
    }

    private func findElement(
        in root: AXUIElement,
        matching: (AXUIElement) -> Bool
    ) -> AXUIElement? {
        if matching(root) { return root }
        for child in children(of: root) {
            if let found = findElement(in: child, matching: matching) {
                return found
            }
        }
        return nil
    }

    private func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value)
        guard status == .success, let raw = value else { return [] }
        return raw as? [AXUIElement] ?? []
    }

    private func title(of element: AXUIElement) -> String? {
        stringAttribute(kAXTitleAttribute as CFString, of: element)
            ?? stringAttribute(kAXDescriptionAttribute as CFString, of: element)
            ?? stringAttribute(kAXValueAttribute as CFString, of: element)
    }

    private func role(of element: AXUIElement) -> String? {
        stringAttribute(kAXRoleAttribute as CFString, of: element)
    }

    private func identifier(of element: AXUIElement) -> String? {
        stringAttribute(kAXIdentifierAttribute as CFString, of: element)
    }

    private func stringAttribute(_ attr: CFString, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attr, &value)
        guard status == .success, let raw = value else { return nil }
        if let string = raw as? String {
            return string
        }
        if let attributed = raw as? NSAttributedString {
            return attributed.string
        }
        if let number = raw as? NSNumber {
            return number.stringValue
        }
        return String(describing: raw)
    }

    private func frame(of element: AXUIElement) -> CGRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?

        let positionStatus = AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef)
        let sizeStatus = AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef)
        guard positionStatus == .success, sizeStatus == .success,
              let rawPosition = positionRef, let rawSize = sizeRef
        else {
            return nil
        }

        guard CFGetTypeID(rawPosition) == AXValueGetTypeID(),
              CFGetTypeID(rawSize) == AXValueGetTypeID()
        else {
            return nil
        }

        let positionValue = rawPosition as! AXValue
        let sizeValue = rawSize as! AXValue
        guard AXValueGetType(positionValue) == .cgPoint,
              AXValueGetType(sizeValue) == .cgSize
        else {
            return nil
        }

        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &point),
              AXValueGetValue(sizeValue, .cgSize, &size)
        else {
            return nil
        }

        return CGRect(origin: point, size: size)
    }

    private func click(point: CGPoint) {
        guard let down = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseDown,
            mouseCursorPosition: point,
            mouseButton: .left
        ) else { return }
        guard let up = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseUp,
            mouseCursorPosition: point,
            mouseButton: .left
        ) else { return }

        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private func typeText(_ text: String) {
        var unicodeBuffer = ""

        func flushUnicodeBuffer() {
            guard !unicodeBuffer.isEmpty else { return }
            postUnicodeText(unicodeBuffer)
            unicodeBuffer.removeAll(keepingCapacity: true)
        }

        for scalar in text.unicodeScalars {
            if scalar == "\r" || scalar == "\n" {
                flushUnicodeBuffer()
                guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: true),
                      let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: false)
                else { continue }
                keyDown.post(tap: .cghidEventTap)
                keyUp.post(tap: .cghidEventTap)
                usleep(18_000)
                continue
            }

            unicodeBuffer.append(String(scalar))
        }

        flushUnicodeBuffer()
    }

    private func postUnicodeText(_ text: String) {
        var utf16Units = Array(text.utf16)
        guard !utf16Units.isEmpty else { return }
        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
        else { return }

        keyDown.keyboardSetUnicodeString(stringLength: utf16Units.count, unicodeString: &utf16Units)
        keyUp.keyboardSetUnicodeString(stringLength: utf16Units.count, unicodeString: &utf16Units)
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        usleep(20_000)
    }

    private func pressLeftArrow(repeatCount: Int) {
        guard repeatCount > 0 else { return }
        for _ in 0 ..< repeatCount {
            guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: 123, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: 123, keyDown: false)
            else { continue }
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
            usleep(10_000)
        }
    }

    private func transcriptText(from element: AXUIElement) -> String? {
        if let value = stringAttribute(kAXValueAttribute as CFString, of: element), !value.isEmpty {
            return value
        }
        if let title = title(of: element), !title.isEmpty {
            return title
        }
        return nil
    }

    private func accessibilitySummary(of element: AXUIElement) -> String {
        var namesRef: CFArray?
        let status = AXUIElementCopyAttributeNames(element, &namesRef)
        guard status == .success, let names = namesRef as? [String] else {
            return "attributeNames unavailable (\(status.rawValue))"
        }

        let roleValue = stringAttribute(kAXRoleAttribute as CFString, of: element) ?? "nil"
        let titleValue = stringAttribute(kAXTitleAttribute as CFString, of: element) ?? "nil"
        let descValue = stringAttribute(kAXDescriptionAttribute as CFString, of: element) ?? "nil"
        let valueValue = stringAttribute(kAXValueAttribute as CFString, of: element) ?? "nil"
        let helpValue = stringAttribute(kAXHelpAttribute as CFString, of: element) ?? "nil"
        let focusedValue = stringAttribute(kAXFocusedAttribute as CFString, of: element) ?? "nil"
        let idValue = stringAttribute(kAXIdentifierAttribute as CFString, of: element) ?? "nil"
        return "role=\(roleValue), id=\(idValue), focused=\(focusedValue), title=\(titleValue), desc=\(descValue), value=\(valueValue), help=\(helpValue), attrs=\(names)"
    }
}
