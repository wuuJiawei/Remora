import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        applyDockIconIfAvailable()
        NSApp.activate(ignoringOtherApps: true)
        Task { @MainActor in
            AppKeyboardShortcutStore.shared.reportConflictsAtLaunchIfNeeded()
        }
        print("[RemoraApp] launched")
    }

    @MainActor
    private func applyDockIconIfAvailable() {
        guard let logoURL = resolveLogoURL() else {
            print("[RemoraApp] icon not found (expected logo.png)")
            return
        }

        guard let image = NSImage(contentsOf: logoURL) else {
            print("[RemoraApp] icon load failed: \(logoURL.path)")
            return
        }

        let normalized = normalizedDockIcon(from: image)
        normalized.isTemplate = false
        NSApp.applicationIconImage = normalized
        NSApp.dockTile.display()
        print("[RemoraApp] icon applied: \(logoURL.path)")

        // Some launch sequences render dock tile before icon is ready.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            NSApp.applicationIconImage = normalized
            NSApp.dockTile.display()
        }
    }

    @MainActor
    private func normalizedDockIcon(from image: NSImage) -> NSImage {
        let width = image.size.width > 0 ? image.size.width : 512
        let height = image.size.height > 0 ? image.size.height : 512
        let canvasSize = NSSize(width: width, height: height)
        let canvas = NSImage(size: canvasSize)

        // Keep a margin so the dock visual weight matches standard macOS apps.
        let insetRatio: CGFloat = 0.12
        let insetRect = NSRect(
            x: canvasSize.width * insetRatio,
            y: canvasSize.height * insetRatio,
            width: canvasSize.width * (1 - insetRatio * 2),
            height: canvasSize.height * (1 - insetRatio * 2)
        )

        canvas.lockFocus()
        image.draw(
            in: insetRect,
            from: NSRect(origin: .zero, size: image.size),
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )
        canvas.unlockFocus()
        return canvas
    }

    private func resolveLogoURL() -> URL? {
        let fileManager = FileManager.default
        var candidateDirectories: [URL] = []

        // 1) Current working directory.
        candidateDirectories.append(URL(fileURLWithPath: fileManager.currentDirectoryPath))

        // 2) Source path fallback (when launched from project root).
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        candidateDirectories.append(sourceRoot)

        // 3) Walk up from executable location to support launching outside project root.
        if let executableURL = Bundle.main.executableURL {
            var dir = executableURL.deletingLastPathComponent()
            for _ in 0 ..< 8 {
                candidateDirectories.append(dir)
                dir.deleteLastPathComponent()
            }
        }

        var visited: Set<String> = []
        for directory in candidateDirectories {
            let standardizedPath = directory.standardizedFileURL.path
            guard !visited.contains(standardizedPath) else { continue }
            visited.insert(standardizedPath)

            let prioritizedCandidates = [
                directory.appendingPathComponent("Resources/AppIcon.icns"),
                directory.appendingPathComponent("AppIcon.icns"),
                directory.appendingPathComponent("logo.png"),
            ]

            for candidate in prioritizedCandidates where fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        return nil
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
