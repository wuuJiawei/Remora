import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        Task { @MainActor in
            AppKeyboardShortcutStore.shared.reportConflictsAtLaunchIfNeeded()
        }
    }
}

@main
struct RemoraAppMain: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var keyboardShortcutStore = AppKeyboardShortcutStore.shared
    @AppStorage(AppSettings.appearanceModeKey) private var appearanceModeRawValue = AppAppearanceMode.system.rawValue
    @AppStorage(AppSettings.languageModeKey) private var languageModeRawValue = AppLanguageMode.system.rawValue

    private var preferredScheme: ColorScheme? {
        AppAppearanceMode.resolved(from: appearanceModeRawValue).colorScheme
    }

    private var preferredLocale: Locale {
        AppLanguageMode.resolved(from: languageModeRawValue).locale ?? .autoupdatingCurrent
    }

    var body: some Scene {
        WindowGroup("Remora") {
            ContentView()
                .preferredColorScheme(preferredScheme)
                .environment(\.locale, preferredLocale)
                .environmentObject(keyboardShortcutStore)
        }
        .windowResizability(.contentSize)

        Window(
            L10n.tr("Settings", fallback: "Settings"),
            id: "settings"
        ) {
            RemoraSettingsSheet()
                .preferredColorScheme(preferredScheme)
                .environment(\.locale, preferredLocale)
                .environmentObject(keyboardShortcutStore)
        }
        .defaultSize(width: 660, height: 410)
        .windowResizability(.contentSize)
        .windowToolbarStyle(.unified)

        .commands {
            CommandGroup(replacing: .appSettings) {
                commandButton(for: .openSettings)
            }

            CommandGroup(after: .sidebar) {
                commandButton(for: .toggleSSHSidebar)
            }

            CommandGroup(after: .newItem) {
                commandButton(for: .newSSHConnection)
            }

            CommandGroup(after: .importExport) {
                commandButton(for: .importConnections)
                commandButton(for: .exportConnections)
            }
        }
    }

    @ViewBuilder
    private func commandButton(for command: AppShortcutCommand) -> some View {
        Button(L10n.tr(command.titleKey, fallback: command.fallbackTitle)) {
            NotificationCenter.default.post(name: command.notificationName, object: nil)
        }
        .appKeyboardShortcut(keyboardShortcutStore.shortcut(for: command))
    }
}

private extension View {
    @ViewBuilder
    func appKeyboardShortcut(_ shortcut: AppKeyboardShortcut?) -> some View {
        if let shortcut, let keyEquivalent = shortcut.keyEquivalent {
            keyboardShortcut(keyEquivalent, modifiers: shortcut.eventModifiers)
        } else {
            self
        }
    }
}
