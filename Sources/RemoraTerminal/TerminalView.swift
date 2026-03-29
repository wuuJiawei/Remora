import AppKit
import Foundation
@preconcurrency import SwiftTerm

public enum TerminalAction: String, CaseIterable, Equatable {
    case copy
    case paste
    case selectAll
    case clearScreen
}

public struct TerminalActionLabels: Equatable {
    public var copy: String
    public var paste: String
    public var selectAll: String
    public var clearScreen: String

    public init(
        copy: String = "Copy",
        paste: String = "Paste",
        selectAll: String = "Select All",
        clearScreen: String = "Clear Screen"
    ) {
        self.copy = copy
        self.paste = paste
        self.selectAll = selectAll
        self.clearScreen = clearScreen
    }
}

public struct TerminalContextMenuItem: Equatable {
    public let action: TerminalAction
    public let isEnabled: Bool

    public init(action: TerminalAction, isEnabled: Bool) {
        self.action = action
        self.isEnabled = isEnabled
    }
}

public struct TerminalActionShortcut: Equatable {
    public let keyEquivalent: String
    public let modifierFlags: NSEvent.ModifierFlags

    public init(keyEquivalent: String, modifierFlags: NSEvent.ModifierFlags) {
        self.keyEquivalent = keyEquivalent
        self.modifierFlags = modifierFlags
    }
}

public final class TerminalView: SwiftTerm.TerminalView, @preconcurrency SwiftTerm.TerminalViewDelegate {
    public var onInput: (@Sendable (Data) -> Void)?
    public var onFocus: (() -> Void)?
    public var onResize: ((Int, Int) -> Void)?
    public var onClearScreen: (() -> Void)?
    public var actionLabels = TerminalActionLabels()

    public init(rows: Int = 30, columns: Int = 120) {
        super.init(frame: .zero)
        configure(rows: rows, columns: columns)
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure(rows: 30, columns: 120)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            self?.focusTerminal()
        }
    }

    public override func menu(for event: NSEvent) -> NSMenu? {
        focusTerminal()
        return contextMenu()
    }

    public func feed(data: Data) {
        feed(byteArray: ArraySlice(data))
    }

    public var hasSelection: Bool {
        selectionActive
    }

    public var canPaste: Bool {
        NSPasteboard.general.availableType(from: [.string]) != nil
    }

    public var isFocusedTerminalResponder: Bool {
        window?.firstResponder === self
    }

    public func contextMenuItems() -> [TerminalContextMenuItem] {
        Self.contextMenuItems(
            hasSelection: hasSelection,
            canPaste: canPaste,
            canClearScreen: onClearScreen != nil
        )
    }

    public static func contextMenuItems(
        hasSelection: Bool,
        canPaste: Bool,
        canClearScreen: Bool
    ) -> [TerminalContextMenuItem] {
        var items: [TerminalContextMenuItem] = []
        if hasSelection {
            items.append(TerminalContextMenuItem(action: .copy, isEnabled: true))
        }
        items.append(TerminalContextMenuItem(action: .paste, isEnabled: canPaste))
        items.append(TerminalContextMenuItem(action: .selectAll, isEnabled: true))
        items.append(TerminalContextMenuItem(action: .clearScreen, isEnabled: canClearScreen))
        return items
    }

    public func performTerminalAction(_ action: TerminalAction) {
        switch action {
        case .copy:
            guard hasSelection else { return }
            copy(self)
        case .paste:
            guard canPaste else { return }
            paste(self)
        case .selectAll:
            selectAll(nil)
        case .clearScreen:
            clearScreen(self)
        }
    }

    public static func shortcut(for action: TerminalAction) -> TerminalActionShortcut {
        switch action {
        case .copy:
            return TerminalActionShortcut(keyEquivalent: "c", modifierFlags: [.command])
        case .paste:
            return TerminalActionShortcut(keyEquivalent: "v", modifierFlags: [.command])
        case .selectAll:
            return TerminalActionShortcut(keyEquivalent: "a", modifierFlags: [.command])
        case .clearScreen:
            return TerminalActionShortcut(keyEquivalent: "k", modifierFlags: [.command])
        }
    }

    public override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)):
            return hasSelection
        case #selector(paste(_:)):
            return canPaste
        case #selector(selectAll(_:)):
            return true
        case #selector(clearScreen(_:)):
            return onClearScreen != nil
        default:
            return super.validateUserInterfaceItem(item)
        }
    }

    private func configure(rows: Int, columns: Int) {
        terminalDelegate = self
        allowMouseReporting = true
        optionAsMetaKey = true
        notifyUpdateChanges = true
        resize(cols: columns, rows: rows)
        frame = getOptimalFrameSize()
        setAccessibilityIdentifier("terminal-view")
    }

    public func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
        onResize?(newCols, newRows)
    }

    public func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {}

    public func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}

    public func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
        onInput?(Data(data))
    }

    public func scrolled(source: SwiftTerm.TerminalView, position: Double) {}

    public func requestOpenLink(source: SwiftTerm.TerminalView, link: String, params: [String : String]) {
        guard let url = URL(string: link) else { return }
        NSWorkspace.shared.open(url)
    }

    public func bell(source: SwiftTerm.TerminalView) {}

    public func clipboardCopy(source: SwiftTerm.TerminalView, content: Data) {
        guard let value = String(data: content, encoding: .utf8) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
    }

    public func iTermContent(source: SwiftTerm.TerminalView, content: ArraySlice<UInt8>) {}

    public func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {}

    @objc public func clearScreen(_ sender: Any?) {
        onClearScreen?()
    }

    private func focusTerminal() {
        window?.makeFirstResponder(self)
        onFocus?()
    }

    private func contextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        for item in contextMenuItems() {
            let shortcut = Self.shortcut(for: item.action)
            let menuItem = NSMenuItem(
                title: title(for: item.action),
                action: selector(for: item.action),
                keyEquivalent: shortcut.keyEquivalent
            )
            menuItem.target = self
            menuItem.isEnabled = item.isEnabled
            menuItem.keyEquivalentModifierMask = shortcut.modifierFlags
            menu.addItem(menuItem)
        }

        return menu
    }

    private func title(for action: TerminalAction) -> String {
        switch action {
        case .copy:
            return actionLabels.copy
        case .paste:
            return actionLabels.paste
        case .selectAll:
            return actionLabels.selectAll
        case .clearScreen:
            return actionLabels.clearScreen
        }
    }

    private func selector(for action: TerminalAction) -> Selector {
        switch action {
        case .copy:
            return #selector(copy(_:))
        case .paste:
            return #selector(paste(_:))
        case .selectAll:
            return #selector(selectAll(_:))
        case .clearScreen:
            return #selector(clearScreen(_:))
        }
    }
}
