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
    func newSSHConnectionButtonPresentsAndDismissesEditorSheet() throws {
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

        guard let newConnectionButton = waitForElement(
            in: appElement,
            timeout: 8,
            matching: { identifier(of: $0) == "sidebar-new-ssh-connection" }
        ) else {
            Issue.record("Could not find new SSH connection button.")
            return
        }

        _ = AXUIElementPerformAction(newConnectionButton, kAXPressAction as CFString)

        guard let editorTitle = waitForElement(
            in: appElement,
            timeout: 5,
            matching: { identifier(of: $0) == "host-editor-title" }
        ) else {
            Issue.record("Could not find host editor sheet title.")
            return
        }

        #expect(title(of: editorTitle) == "New SSH Connection")

        guard let cancelButton = waitForElement(
            in: appElement,
            timeout: 5,
            matching: { element in
                role(of: element) == kAXButtonRole as String && title(of: element) == "Cancel"
            }
        ) else {
            Issue.record("Could not find editor Cancel button.")
            return
        }

        _ = AXUIElementPerformAction(cancelButton, kAXPressAction as CFString)

        let dismissed = waitUntil(timeout: 5, {
            findElement(in: appElement, matching: { identifier(of: $0) == "host-editor-title" }) == nil
        })
        #expect(dismissed, "Expected host editor sheet to dismiss after Cancel.")
    }

    @Test
    func doubleClickHostRowCreatesNewSessionAndConnects() throws {
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
        guard let hostRow = waitForElement(
            in: appElement,
            timeout: 8,
            matching: { element in
                role(of: element) == kAXStaticTextRole as String && title(of: element) == "prod-api"
            }
        ) else {
            Issue.record("Could not find prod-api row.")
            return
        }

        guard let hostFrame = frame(of: hostRow) else {
            Issue.record("Could not read prod-api row frame.")
            return
        }

        doubleClick(point: CGPoint(x: hostFrame.midX, y: hostFrame.midY))

        let session2Ready = waitUntil(timeout: 8, {
            guard selectSessionTab("Session 2", in: appElement) else { return false }
            guard let transcript = activeTranscriptText(in: appElement) else { return false }
            return transcript.contains("Connected to deploy@10.0.0.10:22")
        })

        #expect(session2Ready, "Double-clicking a host row should create Session 2 and connect to that host.")
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
        let expectedUser = NSUserName()
        let connected = waitUntil(timeout: 8, {
            hasConnectedStatus(in: appElement)
        })
        #expect(connected, "Expected terminal connection to be established.")
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
            return value.contains("whoami")
                && value.contains("\n\(expectedUser)\n")
        })
        if !hasOutput {
            Issue.record("Terminal accessibility value after typing: \(lastValue)")
            Issue.record("Terminal AX summary: \(accessibilitySummary(of: terminal))")
        }
        #expect(hasOutput, "Terminal should accept keyboard input and render command output.")

        let hasLineBreak = lastValue.contains("whoami")
            && lastValue.contains("\n\(expectedUser)\n")
        #expect(hasLineBreak, "Command output should appear on a new line after Enter.")

        let remainsVisibleWithoutMouseInteraction = waitUntil(timeout: 2, {
            guard let snapshot = transcriptText(from: transcriptElement) else { return false }
            return snapshot.contains("Connected to \(expectedUser)@127.0.0.1:22")
                && snapshot.contains("\n\(expectedUser)\n")
        })
        #expect(remainsVisibleWithoutMouseInteraction, "Terminal content should remain visible after Enter without extra mouse clicks.")
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
        let expectedUser = NSUserName()
        let connected = waitUntil(timeout: 8, {
            hasConnectedStatus(in: appElement)
        })
        #expect(connected, "Expected terminal connection to be established.")
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
            return value.contains("whoami")
                && value.contains("\n\(expectedUser)\n")
        })

        if !hasValidOutput {
            Issue.record("Transcript after arrow-input: \(snapshot)")
        }

        #expect(hasValidOutput, "Arrow keys should not move input cursor into prompt prefix.")
        #expect(!snapshot.contains("\u{1B}"), "Transcript should not include raw ANSI arrow sequences.")
    }

    @Test
    func terminalRetainsHistoryAcrossMultipleCommands() throws {
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
        let expectedUser = NSUserName()
        let connected = waitUntil(timeout: 8, {
            hasConnectedStatus(in: appElement)
        })
        #expect(connected, "Expected terminal connection to be established.")
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
        typeText("123\r")
        let hasFirstOutput = waitUntil(timeout: 6, {
            guard let snapshot = transcriptText(from: transcriptElement) else { return false }
            return snapshot.contains("command not found: 123")
        })
        #expect(hasFirstOutput, "Expected first command output.")

        typeText("ls\r")
        let hasSecondOutput = waitUntil(timeout: 6, {
            guard let snapshot = transcriptText(from: transcriptElement) else { return false }
            return snapshot.contains("app.log") && snapshot.contains("config.yml")
        })
        #expect(hasSecondOutput, "Expected ls command output.")

        typeText("whoami\r")
        var finalSnapshot = ""
        let hasThirdOutput = waitUntil(timeout: 6, {
            guard let snapshot = transcriptText(from: transcriptElement) else { return false }
            finalSnapshot = snapshot
            return snapshot.contains("whoami")
                && snapshot.contains("\n\(expectedUser)\n")
        })
        #expect(hasThirdOutput, "Expected whoami command output.")

        typeText("help\r")
        let hasFourthOutput = waitUntil(timeout: 6, {
            guard let snapshot = transcriptText(from: transcriptElement) else { return false }
            finalSnapshot = snapshot
            return snapshot.contains("Available commands: help, date, whoami, ls, clear")
        })
        #expect(hasFourthOutput, "Expected help command output.")

        typeText("unknown\r")
        let hasFifthOutput = waitUntil(timeout: 6, {
            guard let snapshot = transcriptText(from: transcriptElement) else { return false }
            finalSnapshot = snapshot
            return snapshot.contains("command not found: unknown")
        })
        #expect(hasFifthOutput, "Expected fifth command output.")

        let historyRetained =
            finalSnapshot.contains("Connected to \(expectedUser)@127.0.0.1:22")
            && finalSnapshot.contains("command not found: 123")
            && finalSnapshot.contains("app.log")
            && finalSnapshot.contains("whoami")
            && finalSnapshot.contains("Available commands: help, date, whoami, ls, clear")
            && finalSnapshot.contains("command not found: unknown")
        if !historyRetained {
            Issue.record("Final transcript snapshot: \(finalSnapshot)")
        }
        #expect(historyRetained, "Previous terminal history should remain visible after multiple commands.")
    }

    @Test
    func terminalBackspaceAndEnterBehaveConsistently() throws {
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
        let expectedUser = NSUserName()
        let connected = waitUntil(timeout: 8, {
            hasConnectedStatus(in: appElement)
        })
        #expect(connected, "Expected terminal connection to be established.")
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
        typeText("whoamx")
        pressDelete(repeatCount: 1)
        typeText("i\r")

        var snapshot = ""
        let hasCorrectOutput = waitUntil(timeout: 8, {
            guard let value = transcriptText(from: transcriptElement) else { return false }
            snapshot = value
            return value.contains("\n\(expectedUser)\n")
                && value.contains("\(expectedUser)@127.0.0.1 %")
        })

        if !hasCorrectOutput {
            Issue.record("Transcript after backspace-edit command: \(snapshot)")
        }

        #expect(hasCorrectOutput, "Backspace editing should produce the corrected command output after Enter.")
        #expect(!snapshot.contains("command not found: whoamx"), "Corrected command should not execute the unedited typo.")
    }

    @Test
    func terminalSelectionSupportsCommandCCopy() throws {
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
        let expectedUser = NSUserName()
        let connected = waitUntil(timeout: 8, {
            hasConnectedStatus(in: appElement)
        })
        #expect(connected, "Expected terminal connection to be established.")
        guard connected else { return }

        guard let terminal = waitForElement(
            in: appElement,
            timeout: 6,
            matching: { identifier(of: $0) == "terminal-view" }
        ) else {
            Issue.record("Could not find terminal accessibility element.")
            return
        }

        guard let transcriptElement = waitForElement(
            in: appElement,
            timeout: 8,
            matching: { identifier(of: $0) == "terminal-transcript" }
        ) else {
            Issue.record("Could not find transcript accessibility element.")
            return
        }

        guard let frame = frame(of: terminal) else {
            Issue.record("Could not read terminal frame for copy-selection test.")
            return
        }

        click(point: CGPoint(x: frame.midX, y: frame.midY))
        typeText("whoami\r")

        let hasWhoamiOutput = waitUntil(timeout: 8, {
            guard let value = transcriptText(from: transcriptElement) else { return false }
            return value.contains("whoami") && value.contains("\n\(expectedUser)\n")
        })
        #expect(hasWhoamiOutput, "Expected whoami output before copy test.")
        guard hasWhoamiOutput else { return }

        NSPasteboard.general.clearContents()
        drag(from: CGPoint(x: frame.minX + 20, y: frame.minY + 20), to: CGPoint(x: frame.maxX - 20, y: frame.maxY - 20))
        pressCommandC()

        var copied = ""
        let copiedExpectedText = waitUntil(timeout: 5, {
            guard let value = NSPasteboard.general.string(forType: .string), !value.isEmpty else { return false }
            copied = value
            return value.contains("whoami") || value.contains(expectedUser)
        })

        if !copiedExpectedText {
            Issue.record("Clipboard content after Cmd+C: \(copied)")
        }
        #expect(copiedExpectedText, "Cmd+C should copy selected terminal text into pasteboard.")
    }

    @Test
    func newSessionStartsIsolatedFromExistingTerminalBuffer() throws {
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
            hasConnectedStatus(in: appElement)
        })
        #expect(connected, "Expected terminal connection to be established.")
        guard connected else { return }

        guard let terminal = waitForElement(
            in: appElement,
            timeout: 8,
            matching: { identifier(of: $0) == "terminal-view" }
        ) else {
            Issue.record("Could not find terminal accessibility element.")
            return
        }

        guard let transcriptElement = waitForElement(
            in: appElement,
            timeout: 8,
            matching: { identifier(of: $0) == "terminal-transcript" }
        ) else {
            Issue.record("Could not find transcript accessibility element.")
            return
        }

        guard let frame = frame(of: terminal) else {
            Issue.record("Could not read terminal frame for click focus.")
            return
        }

        click(point: CGPoint(x: frame.midX, y: frame.midY))
        typeText("help\r")

        let firstSessionHasCommandOutput = waitUntil(timeout: 8, {
            guard let value = transcriptText(from: transcriptElement) else { return false }
            return value.contains("Available commands: help, date, whoami, ls, clear")
        })
        #expect(firstSessionHasCommandOutput, "First session should contain command output.")
        guard firstSessionHasCommandOutput else { return }

        guard let addSessionButton = waitForElement(
            in: appElement,
            timeout: 5,
            matching: { identifier(of: $0) == "session-tab-add" }
        ) else {
            Issue.record("Could not find add-session button.")
            return
        }

        _ = AXUIElementPerformAction(addSessionButton, kAXPressAction as CFString)

        guard let session2Tab = waitForElement(
            in: appElement,
            timeout: 5,
            matching: { element in
                role(of: element) == kAXButtonRole as String && title(of: element) == "Session 2"
            }
        ) else {
            Issue.record("Could not find Session 2 tab button.")
            return
        }

        _ = AXUIElementPerformAction(session2Tab, kAXPressAction as CFString)

        let secondSessionIsClean = waitUntil(timeout: 5, {
            findElement(in: appElement, matching: { element in
                guard identifier(of: element) == "terminal-transcript" else { return false }
                guard let value = transcriptText(from: element) else { return false }
                return !value.contains("Available commands: help, date, whoami, ls, clear")
            }) != nil
        })

        if !secondSessionIsClean {
            let leaked = findElement(in: appElement, matching: { identifier(of: $0) == "terminal-transcript" })
                .flatMap { transcriptText(from: $0) } ?? ""
            Issue.record("Session 2 terminal buffer leaked from Session 1: \(leaked)")
        }

        #expect(secondSessionIsClean, "New session should not inherit previous session terminal buffer.")
    }

    @Test
    func multiSessionSupportsMultiRoundIsolationAndClear() throws {
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
            hasConnectedStatus(in: appElement)
        })
        #expect(connected, "Expected initial terminal connection.")
        guard connected else { return }

        guard let addSessionButton = waitForElement(
            in: appElement,
            timeout: 5,
            matching: { identifier(of: $0) == "session-tab-add" }
        ) else {
            Issue.record("Could not find add-session button.")
            return
        }

        _ = AXUIElementPerformAction(addSessionButton, kAXPressAction as CFString)
        _ = AXUIElementPerformAction(addSessionButton, kAXPressAction as CFString)

        let sessionTitles = ["Session 1", "Session 2", "Session 3"]
        for title in sessionTitles {
            guard selectSessionTab(title, in: appElement) else {
                Issue.record("Could not select tab \(title)")
                return
            }
            let ready = waitUntil(timeout: 8, {
                guard let transcript = activeTranscriptText(in: appElement) else { return false }
                return transcript.contains("Type commands and press Enter.")
            })
            #expect(ready, "\(title) should have initial prompt output.")
            guard ready else { return }
        }

        let round1Markers = [
            "Session 1": "s1_round1_marker_101",
            "Session 2": "s2_round1_marker_202",
            "Session 3": "s3_round1_marker_303",
        ]

        for title in sessionTitles {
            guard let marker = round1Markers[title], selectSessionTab(title, in: appElement) else {
                Issue.record("Could not select tab \(title) for round1")
                return
            }
            guard focusActiveTerminal(in: appElement) else {
                Issue.record("Could not focus terminal in \(title)")
                return
            }
            typeText("\(marker)\r")
            let echoed = waitUntil(timeout: 8, {
                guard let transcript = activeTranscriptText(in: appElement) else { return false }
                return transcript.contains("command not found: \(marker)")
            })
            #expect(echoed, "\(title) should render marker output \(marker)")
            guard echoed else { return }
        }

        guard selectSessionTab("Session 2", in: appElement), focusActiveTerminal(in: appElement) else {
            Issue.record("Could not focus Session 2 for clear.")
            return
        }
        let beforeClearTranscript = activeTranscriptText(in: appElement) ?? ""
        typeText("clear\r")
        let session2ProcessedClear = waitUntil(timeout: 8, {
            guard let transcript = activeTranscriptText(in: appElement) else { return false }
            return transcript != beforeClearTranscript
        })
        #expect(session2ProcessedClear, "Session 2 should process clear command input.")
        guard session2ProcessedClear else { return }

        for title in ["Session 1", "Session 3"] {
            guard let marker = round1Markers[title], selectSessionTab(title, in: appElement) else {
                Issue.record("Could not select \(title) to verify isolation after clear.")
                return
            }
            let unaffected = waitUntil(timeout: 6, {
                guard let transcript = activeTranscriptText(in: appElement) else { return false }
                return transcript.contains("command not found: \(marker)") && !transcript.contains("\nclear")
            })
            #expect(unaffected, "\(title) should keep its own marker after Session 2 clear.")
        }

        let round2Markers = [
            "Session 1": "s1_round2_marker_404",
            "Session 2": "s2_round2_marker_505",
            "Session 3": "s3_round2_marker_606",
        ]

        for title in sessionTitles {
            guard let marker = round2Markers[title], selectSessionTab(title, in: appElement) else {
                Issue.record("Could not select \(title) for round2.")
                return
            }
            guard focusActiveTerminal(in: appElement) else {
                Issue.record("Could not focus terminal in \(title) for round2.")
                return
            }
            typeText("\(marker)\r")
            let echoed = waitUntil(timeout: 8, {
                guard let transcript = activeTranscriptText(in: appElement) else { return false }
                return transcript.contains("command not found: \(marker)")
            })
            #expect(echoed, "\(title) should render second marker output \(marker)")
        }

        for title in sessionTitles {
            guard let marker1 = round1Markers[title],
                  let marker2 = round2Markers[title],
                  selectSessionTab(title, in: appElement)
            else {
                Issue.record("Could not validate final isolation for \(title).")
                return
            }

            guard let snapshot = activeTranscriptText(in: appElement) else {
                Issue.record("Could not read transcript for \(title) final validation.")
                return
            }

            #expect(snapshot.contains(marker1), "\(title) should keep round1 marker.")
            #expect(snapshot.contains(marker2), "\(title) should keep round2 marker.")

            for other in sessionTitles where other != title {
                if let otherMarker1 = round1Markers[other] {
                    #expect(!snapshot.contains(otherMarker1), "\(title) should not contain \(other)'s round1 marker.")
                }
                if let otherMarker2 = round2Markers[other] {
                    #expect(!snapshot.contains(otherMarker2), "\(title) should not contain \(other)'s round2 marker.")
                }
            }
        }
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

    private func hasConnectedStatus(in appElement: AXUIElement) -> Bool {
        findElement(in: appElement, matching: { element in
            guard let text = title(of: element) else { return false }
            return text.hasPrefix("Connected (")
        }) != nil
    }

    private func findElements(
        in root: AXUIElement,
        matching: (AXUIElement) -> Bool
    ) -> [AXUIElement] {
        var results: [AXUIElement] = []
        if matching(root) {
            results.append(root)
        }
        for child in children(of: root) {
            results.append(contentsOf: findElements(in: child, matching: matching))
        }
        return results
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

    private func boolAttribute(_ attr: CFString, of element: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attr, &value)
        guard status == .success, let raw = value else { return nil }
        if let number = raw as? NSNumber {
            return number.boolValue
        }
        return nil
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

    private func doubleClick(point: CGPoint) {
        for clickState in [1, 2] {
            guard let down = CGEvent(
                mouseEventSource: nil,
                mouseType: .leftMouseDown,
                mouseCursorPosition: point,
                mouseButton: .left
            ),
            let up = CGEvent(
                mouseEventSource: nil,
                mouseType: .leftMouseUp,
                mouseCursorPosition: point,
                mouseButton: .left
            ) else { return }

            down.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
            up.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            usleep(8_000)
        }
    }

    private func drag(from start: CGPoint, to end: CGPoint) {
        guard let down = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseDown,
            mouseCursorPosition: start,
            mouseButton: .left
        ),
        let drag = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseDragged,
            mouseCursorPosition: end,
            mouseButton: .left
        ),
        let up = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseUp,
            mouseCursorPosition: end,
            mouseButton: .left
        ) else { return }

        down.post(tap: .cghidEventTap)
        drag.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private func pressCommandC() {
        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: 8, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: 8, keyDown: false)
        else { return }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        usleep(20_000)
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

    private func pressDelete(repeatCount: Int) {
        guard repeatCount > 0 else { return }
        for _ in 0 ..< repeatCount {
            guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: 51, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: 51, keyDown: false)
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

    private func activeTerminalElement(in appElement: AXUIElement) -> AXUIElement? {
        let terminals = findElements(in: appElement) { identifier(of: $0) == "terminal-view" }
        if terminals.count <= 1 {
            return terminals.first
        }

        if let focused = terminals.first(where: { boolAttribute(kAXFocusedAttribute as CFString, of: $0) == true }) {
            return focused
        }

        if let visible = terminals.first(where: { boolAttribute(kAXHiddenAttribute as CFString, of: $0) != true }) {
            return visible
        }
        return terminals.first
    }

    private func activeTranscriptElement(in appElement: AXUIElement) -> AXUIElement? {
        let transcripts = findElements(in: appElement) { identifier(of: $0) == "terminal-transcript" }
        if transcripts.count <= 1 {
            return transcripts.first
        }

        if let visible = transcripts.first(where: { boolAttribute(kAXHiddenAttribute as CFString, of: $0) != true }) {
            return visible
        }
        return transcripts.first
    }

    private func activeTranscriptText(in appElement: AXUIElement) -> String? {
        guard let element = activeTranscriptElement(in: appElement) else { return nil }
        return transcriptText(from: element)
    }

    private func activeTerminalValue(in appElement: AXUIElement) -> String? {
        guard let element = activeTerminalElement(in: appElement) else { return nil }
        return stringAttribute(kAXValueAttribute as CFString, of: element)
    }

    private func focusActiveTerminal(in appElement: AXUIElement) -> Bool {
        let terminals = findElements(in: appElement) { identifier(of: $0) == "terminal-view" }
        guard let terminal = terminals.first, let terminalFrame = frame(of: terminal) else { return false }
        click(point: CGPoint(x: terminalFrame.midX, y: terminalFrame.midY))
        return waitUntil(timeout: 2) {
            activeTerminalElement(in: appElement) != nil
        }
    }

    private func sessionIndex(from title: String) -> Int? {
        guard title.hasPrefix("Session ") else { return nil }
        let raw = title.replacingOccurrences(of: "Session ", with: "")
        guard let value = Int(raw), value > 0 else { return nil }
        return value - 1
    }

    private func terminalElement(forSessionTitle title: String, in appElement: AXUIElement) -> AXUIElement? {
        guard let index = sessionIndex(from: title) else { return nil }
        let terminals = findElements(in: appElement) { identifier(of: $0) == "terminal-view" }
        guard terminals.indices.contains(index) else { return nil }
        return terminals[index]
    }

    private func transcriptElement(forSessionTitle title: String, in appElement: AXUIElement) -> AXUIElement? {
        guard let index = sessionIndex(from: title) else { return nil }
        let transcripts = findElements(in: appElement) { identifier(of: $0) == "terminal-transcript" }
        guard transcripts.indices.contains(index) else { return nil }
        return transcripts[index]
    }

    private func terminalValue(forSessionTitle title: String, in appElement: AXUIElement) -> String? {
        guard let element = terminalElement(forSessionTitle: title, in: appElement) else { return nil }
        return stringAttribute(kAXValueAttribute as CFString, of: element)
    }

    private func transcriptText(forSessionTitle title: String, in appElement: AXUIElement) -> String? {
        guard let element = transcriptElement(forSessionTitle: title, in: appElement) else { return nil }
        return transcriptText(from: element)
    }

    private func focusTerminal(forSessionTitle title: String, in appElement: AXUIElement) -> Bool {
        guard let element = terminalElement(forSessionTitle: title, in: appElement),
              let terminalFrame = frame(of: element) else { return false }
        _ = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        click(point: CGPoint(x: terminalFrame.midX, y: terminalFrame.midY))
        return true
    }

    private func selectSessionTab(_ title: String, in appElement: AXUIElement) -> Bool {
        guard let tab = waitForElement(
            in: appElement,
            timeout: 5,
            matching: { element in
                role(of: element) == kAXButtonRole as String && self.title(of: element) == title
            }
        ) else {
            return false
        }
        _ = AXUIElementPerformAction(tab, kAXPressAction as CFString)
        _ = AXUIElementPerformAction(tab, kAXPressAction as CFString)
        return true
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
