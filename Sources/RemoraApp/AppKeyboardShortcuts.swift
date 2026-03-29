import AppKit
import Foundation
import RemoraCore
import RemoraTerminal
import SwiftUI

enum AppShortcutCommand: String, CaseIterable, Identifiable {
    case openSettings
    case toggleSSHSidebar
    case newSSHConnection
    case importConnections
    case exportConnections
    case terminalCopy
    case terminalPaste
    case terminalClearScreen

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .openSettings:
            return "menu.remora.settings"
        case .toggleSSHSidebar:
            return "menu.remora.toggle_sidebar"
        case .newSSHConnection:
            return "menu.remora.new_ssh"
        case .importConnections:
            return "menu.remora.import"
        case .exportConnections:
            return "menu.remora.export"
        case .terminalCopy:
            return "Copy"
        case .terminalPaste:
            return "Paste"
        case .terminalClearScreen:
            return "Clear Screen"
        }
    }

    var fallbackTitle: String {
        switch self {
        case .openSettings:
            return "Settings"
        case .toggleSSHSidebar:
            return "Toggle SSH Sidebar"
        case .newSSHConnection:
            return "New SSH Connection"
        case .importConnections:
            return "Import Connections"
        case .exportConnections:
            return "Export Connections"
        case .terminalCopy:
            return "Copy"
        case .terminalPaste:
            return "Paste"
        case .terminalClearScreen:
            return "Clear Screen"
        }
    }

    var defaultShortcut: AppKeyboardShortcut? {
        switch self {
        case .openSettings:
            return AppKeyboardShortcut(keyToken: ",", modifierFlags: [.command])
        case .toggleSSHSidebar:
            return AppKeyboardShortcut(keyToken: "b", modifierFlags: [.command])
        case .newSSHConnection:
            return AppKeyboardShortcut(keyToken: "n", modifierFlags: [.command, .shift])
        case .importConnections:
            return AppKeyboardShortcut(keyToken: "i", modifierFlags: [.command])
        case .exportConnections:
            return AppKeyboardShortcut(keyToken: "e", modifierFlags: [.command])
        case .terminalCopy:
            return AppKeyboardShortcut(keyToken: "c", modifierFlags: [.command])
        case .terminalPaste:
            return AppKeyboardShortcut(keyToken: "v", modifierFlags: [.command])
        case .terminalClearScreen:
            return AppKeyboardShortcut(keyToken: "k", modifierFlags: [.command])
        }
    }

    var notificationName: Notification.Name? {
        switch self {
        case .openSettings:
            return .remoraOpenSettingsCommand
        case .toggleSSHSidebar:
            return .remoraToggleSidebarCommand
        case .newSSHConnection:
            return .remoraNewSSHConnectionCommand
        case .importConnections:
            return .remoraImportConnectionsCommand
        case .exportConnections:
            return .remoraExportConnectionsCommand
        case .terminalCopy, .terminalPaste, .terminalClearScreen:
            return nil
        }
    }

    var selector: Selector? {
        switch self {
        case .terminalCopy:
            return #selector(NSText.copy(_:))
        case .terminalPaste:
            return #selector(NSText.paste(_:))
        case .terminalClearScreen:
            return #selector(TerminalView.clearScreen(_:))
        case .openSettings, .toggleSSHSidebar, .newSSHConnection, .importConnections, .exportConnections:
            return nil
        }
    }
}

struct AppKeyboardShortcut: Codable, Hashable {
    static let supportedModifierFlags: NSEvent.ModifierFlags = [.command, .shift, .option, .control]
    static let primaryModifierFlags: NSEvent.ModifierFlags = [.command, .option, .control]
    private static let specialKeyFromCode: [UInt16: String] = [
        36: "return",
        48: "tab",
        49: "space",
        51: "delete",
        53: "escape",
        123: "leftArrow",
        124: "rightArrow",
        125: "downArrow",
        126: "upArrow",
    ]

    var keyToken: String
    var modifiersRawValue: UInt

    init(keyToken: String, modifierFlags: NSEvent.ModifierFlags) {
        self.keyToken = keyToken
        self.modifiersRawValue = Self.normalizedModifierFlags(modifierFlags).rawValue
    }

    var modifierFlags: NSEvent.ModifierFlags {
        Self.normalizedModifierFlags(NSEvent.ModifierFlags(rawValue: modifiersRawValue))
    }

    var eventModifiers: EventModifiers {
        var modifiers: EventModifiers = []
        let flags = modifierFlags
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        return modifiers
    }

    var keyEquivalent: KeyEquivalent? {
        if keyToken.count == 1, let character = keyToken.first {
            return KeyEquivalent(character)
        }

        switch keyToken {
        case "return":
            return .return
        case "tab":
            return .tab
        case "space":
            return .space
        case "delete":
            return .delete
        case "escape":
            return .escape
        case "upArrow":
            return .upArrow
        case "downArrow":
            return .downArrow
        case "leftArrow":
            return .leftArrow
        case "rightArrow":
            return .rightArrow
        default:
            return nil
        }
    }

    var signature: String {
        "\(keyToken)|\(modifiersRawValue)"
    }

    var displayText: String {
        var parts: [String] = []
        if modifierFlags.contains(.command) { parts.append("⌘") }
        if modifierFlags.contains(.shift) { parts.append("⇧") }
        if modifierFlags.contains(.option) { parts.append("⌥") }
        if modifierFlags.contains(.control) { parts.append("⌃") }

        let keyLabel: String
        switch keyToken {
        case "return":
            keyLabel = "↩"
        case "tab":
            keyLabel = "⇥"
        case "space":
            keyLabel = "␣"
        case "delete":
            keyLabel = "⌫"
        case "escape":
            keyLabel = "⎋"
        case "upArrow":
            keyLabel = "↑"
        case "downArrow":
            keyLabel = "↓"
        case "leftArrow":
            keyLabel = "←"
        case "rightArrow":
            keyLabel = "→"
        default:
            keyLabel = keyToken.uppercased()
        }
        parts.append(keyLabel)
        return parts.joined()
    }

    var usesPrimaryModifier: Bool {
        !modifierFlags.intersection(Self.primaryModifierFlags).isEmpty
    }

    var isUsable: Bool {
        usesPrimaryModifier && keyEquivalent != nil
    }

    static func from(event: NSEvent) -> AppKeyboardShortcut? {
        let modifiers = normalizedModifierFlags(event.modifierFlags)
        guard !modifiers.isEmpty else { return nil }

        if let specialToken = specialKeyFromCode[event.keyCode] {
            let shortcut = AppKeyboardShortcut(keyToken: specialToken, modifierFlags: modifiers)
            return shortcut.isUsable ? shortcut : nil
        }

        guard let characters = event.charactersIgnoringModifiers, !characters.isEmpty else {
            return nil
        }
        guard let scalar = characters.unicodeScalars.first, scalar.isASCII else {
            return nil
        }
        guard !CharacterSet.controlCharacters.contains(scalar) else {
            return nil
        }

        let token = String(scalar).lowercased()
        let shortcut = AppKeyboardShortcut(keyToken: token, modifierFlags: modifiers)
        return shortcut.isUsable ? shortcut : nil
    }

    static func normalizedModifierFlags(_ flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        flags.intersection(supportedModifierFlags)
    }
}

struct KeyboardShortcutConflict: Identifiable, Hashable {
    let shortcut: AppKeyboardShortcut
    let commands: [AppShortcutCommand]

    var id: String { shortcut.signature }
}

@MainActor
final class AppKeyboardShortcutStore: ObservableObject {
    private struct PersistedShortcuts: Codable {
        var custom: [String: AppKeyboardShortcut]
        var unbound: [String]
    }

    static let shared = AppKeyboardShortcutStore()

    @Published private(set) var conflicts: [KeyboardShortcutConflict] = []

    private let fileStore: RemoraJSONFileStore<PersistedShortcuts>
    private var customShortcuts: [AppShortcutCommand: AppKeyboardShortcut] = [:]
    private var unboundCommands: Set<AppShortcutCommand> = []
    private var launchConflictCheckFinished = false

    init(
        fileURL: URL = RemoraConfigPaths.fileURL(for: .keyboardShortcuts)
    ) {
        self.fileStore = RemoraJSONFileStore(fileURL: fileURL)
        loadFromStorage()
        recomputeConflicts(report: false, source: "init")
    }

    func shortcut(for command: AppShortcutCommand) -> AppKeyboardShortcut? {
        if unboundCommands.contains(command) {
            return nil
        }
        let resolved = customShortcuts[command] ?? command.defaultShortcut
        guard let resolved, resolved.isUsable else { return nil }
        return resolved
    }

    func setShortcut(_ shortcut: AppKeyboardShortcut, for command: AppShortcutCommand) {
        guard shortcut.isUsable else { return }
        objectWillChange.send()
        customShortcuts[command] = shortcut
        unboundCommands.remove(command)
        persistToStorage()
        recomputeConflicts(report: false, source: "set")
    }

    func unbindShortcut(for command: AppShortcutCommand) {
        objectWillChange.send()
        customShortcuts.removeValue(forKey: command)
        unboundCommands.insert(command)
        persistToStorage()
        recomputeConflicts(report: false, source: "unbind")
    }

    func restoreDefault(for command: AppShortcutCommand) {
        objectWillChange.send()
        customShortcuts.removeValue(forKey: command)
        unboundCommands.remove(command)
        persistToStorage()
        recomputeConflicts(report: false, source: "restore-default")
    }

    func restoreAllDefaults() {
        objectWillChange.send()
        customShortcuts.removeAll()
        unboundCommands.removeAll()
        persistToStorage()
        recomputeConflicts(report: false, source: "restore-all")
    }

    func hasCustomBinding(for command: AppShortcutCommand) -> Bool {
        customShortcuts[command] != nil || unboundCommands.contains(command)
    }

    func conflict(for command: AppShortcutCommand) -> KeyboardShortcutConflict? {
        conflicts.first(where: { $0.commands.contains(command) })
    }

    func reportConflictsAtLaunchIfNeeded() {
        guard !launchConflictCheckFinished else { return }
        launchConflictCheckFinished = true
        recomputeConflicts(report: true, source: "launch")
    }

    private func recomputeConflicts(report: Bool, source: String) {
        var buckets: [AppKeyboardShortcut: [AppShortcutCommand]] = [:]

        for command in AppShortcutCommand.allCases {
            guard let shortcut = shortcut(for: command) else { continue }
            buckets[shortcut, default: []].append(command)
        }

        conflicts = buckets
            .filter { $0.value.count > 1 }
            .map { bucket in
                KeyboardShortcutConflict(
                    shortcut: bucket.key,
                    commands: bucket.value.sorted { $0.rawValue < $1.rawValue }
                )
            }
            .sorted { lhs, rhs in
                lhs.shortcut.displayText.localizedStandardCompare(rhs.shortcut.displayText) == .orderedAscending
            }

        guard report, !conflicts.isEmpty else { return }

        print("[ShortcutConflict][\(source)] detected \(conflicts.count) conflict group(s)")
        for conflict in conflicts {
            let commandList = conflict.commands.map(\.rawValue).joined(separator: ", ")
            print("[ShortcutConflict][\(source)] \(conflict.shortcut.displayText): \(commandList)")
        }
    }

    private func loadFromStorage() {
        guard let payload = try? fileStore.load() else { return }

        var loadedCustom: [AppShortcutCommand: AppKeyboardShortcut] = [:]
        for (commandID, shortcut) in payload.custom {
            guard let command = AppShortcutCommand(rawValue: commandID), shortcut.isUsable else { continue }
            loadedCustom[command] = shortcut
        }
        customShortcuts = loadedCustom

        var loadedUnbound: Set<AppShortcutCommand> = []
        for commandID in payload.unbound {
            guard let command = AppShortcutCommand(rawValue: commandID) else { continue }
            loadedUnbound.insert(command)
        }
        unboundCommands = loadedUnbound
    }

    private func persistToStorage() {
        let payload = PersistedShortcuts(
            custom: Dictionary(uniqueKeysWithValues: customShortcuts.map { ($0.key.rawValue, $0.value) }),
            unbound: unboundCommands.map(\.rawValue).sorted()
        )
        try? fileStore.save(payload)
    }
}
