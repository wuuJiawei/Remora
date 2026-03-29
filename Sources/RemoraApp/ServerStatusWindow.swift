import AppKit
import SwiftUI
import RemoraCore

@MainActor
final class ServerStatusWindowManager: NSObject, ObservableObject, NSWindowDelegate {
    private let context = ServerStatusWindowContext()
    private var window: NSWindow?
    private weak var metricsCenter: ServerMetricsCenter?

    func present(
        host: RemoraCore.Host,
        runtime: TerminalRuntime,
        metricsCenter: ServerMetricsCenter
    ) {
        self.metricsCenter = metricsCenter
        context.host = host
        context.runtime = runtime
        metricsCenter.setObservedWindowHost(host)

        if window == nil {
            createWindow(metricsCenter: metricsCenter)
        }
        updateWindowTitle(for: host)
        applyAppearanceMode()
        positionWindowBesidePrimaryWindow()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func createWindow(metricsCenter: ServerMetricsCenter) {
        let rootView = ServerStatusWindowView(context: context, metricsCenter: metricsCenter)
        let hostingController = NSHostingController(rootView: rootView)
        let nextWindow = NSWindow(contentViewController: hostingController)
        nextWindow.title = L10n.tr("Server Monitoring", fallback: "Server Monitoring")
        nextWindow.identifier = NSUserInterfaceItemIdentifier("remora.server-status-window")
        nextWindow.styleMask = [.titled, .closable, .miniaturizable]
        nextWindow.setContentSize(NSSize(width: 592, height: 720))
        nextWindow.minSize = NSSize(width: 532, height: 560)
        nextWindow.isReleasedWhenClosed = false
        nextWindow.delegate = self
        window = nextWindow
    }

    private func applyAppearanceMode() {
        guard let window else { return }
        let rawValue = AppPreferences.shared.value(for: \.appearanceModeRawValue)
        let mode = AppAppearanceMode.resolved(from: rawValue)
        if let appearanceName = mode.nsAppearanceName {
            window.appearance = NSAppearance(named: appearanceName)
        } else {
            window.appearance = nil
        }
    }

    private func positionWindowBesidePrimaryWindow() {
        guard let window else { return }

        let anchorWindow: NSWindow? = {
            if let keyWindow = NSApp.keyWindow, keyWindow != window {
                return keyWindow
            }
            if let mainWindow = NSApp.mainWindow, mainWindow != window {
                return mainWindow
            }
            return NSApp.windows.first(where: { $0.isVisible && $0 != window })
        }()

        guard let anchorWindow else { return }

        let anchorFrame = anchorWindow.frame
        var targetFrame = window.frame
        targetFrame.origin.x = anchorFrame.maxX + 14
        targetFrame.origin.y = anchorFrame.maxY - targetFrame.height

        let visibleFrame = (anchorWindow.screen ?? NSScreen.main)?.visibleFrame
            ?? NSScreen.screens.first?.visibleFrame
        if let visibleFrame {
            if targetFrame.maxX > visibleFrame.maxX {
                targetFrame.origin.x = visibleFrame.maxX - targetFrame.width
            }
            if targetFrame.minY < visibleFrame.minY {
                targetFrame.origin.y = visibleFrame.minY
            }
            if targetFrame.maxY > visibleFrame.maxY {
                targetFrame.origin.y = visibleFrame.maxY - targetFrame.height
            }
            if targetFrame.minX < visibleFrame.minX {
                targetFrame.origin.x = visibleFrame.minX
            }
        }

        window.setFrame(targetFrame, display: true)
    }

    private func updateWindowTitle(for host: RemoraCore.Host) {
        guard let window else { return }
        let format = L10n.tr("%@ - Server Monitoring", fallback: "%@ - Server Monitoring")
        window.title = String(format: format, displayHostName(for: host))
    }

    private func displayHostName(for host: RemoraCore.Host) -> String {
        let trimmedName = host.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedName.isEmpty {
            return trimmedName
        }
        return "\(host.username)@\(host.address):\(host.port)"
    }

    func windowWillClose(_ notification: Notification) {
        metricsCenter?.setObservedWindowHost(nil)
        context.host = nil
        context.runtime = nil
    }
}

@MainActor
final class ServerStatusWindowContext: ObservableObject {
    @Published var host: RemoraCore.Host?
    @Published var runtime: TerminalRuntime?
}

private struct ServerStatusWindowView: View {
    @ObservedObject var context: ServerStatusWindowContext
    @ObservedObject var metricsCenter: ServerMetricsCenter

    var body: some View {
        ZStack {
            VisualStyle.rightPanelBackground
                .ignoresSafeArea()
            if let host = context.host {
                statusContent(for: host)
            } else {
                ContentUnavailableView(
                    tr("No Server Selected"),
                    systemImage: "waveform.path.ecg",
                    description: Text(tr("Click metrics bars in a session tab to inspect server status."))
                )
            }
        }
        .frame(minWidth: 532, minHeight: 560)
    }

    private func statusContent(for host: RemoraCore.Host) -> some View {
        let state = metricsCenter.state(for: host) ?? .idle
        return ServerMetricsPanel(
            hostTitle: displayHostName(for: host),
            hostSubtitle: "\(host.username)@\(host.address):\(host.port)",
            connectionState: localizedConnectionState(context.runtime?.connectionState ?? "Disconnected"),
            state: state
        )
        .padding(16)
    }

    private func displayHostName(for host: RemoraCore.Host) -> String {
        let trimmedName = host.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedName.isEmpty {
            return trimmedName
        }
        return "\(host.username)@\(host.address):\(host.port)"
    }
}
