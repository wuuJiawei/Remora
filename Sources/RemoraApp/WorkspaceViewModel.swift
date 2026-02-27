import Foundation
import RemoraCore

enum PaneSplitOrientation: String, CaseIterable, Identifiable {
    case horizontal = "Horizontal"
    case vertical = "Vertical"

    var id: String { rawValue }
}

@MainActor
final class TerminalPaneModel: ObservableObject, Identifiable {
    let id: UUID
    let runtime: TerminalRuntime

    init(id: UUID = UUID(), runtime: TerminalRuntime = TerminalPaneModel.defaultRuntime()) {
        self.id = id
        self.runtime = runtime
    }

    private static func defaultRuntime() -> TerminalRuntime {
        if ProcessInfo.processInfo.environment["REMORA_RUN_UI_TESTS"] == "1" {
            let mockManager = SessionManager(sshClientFactory: { MockSSHClient() })
            return TerminalRuntime(localSessionManager: mockManager, sshSessionManager: mockManager)
        }
        return TerminalRuntime()
    }
}

@MainActor
final class TerminalTabModel: ObservableObject, Identifiable {
    let id: UUID
    @Published var title: String
    @Published var panes: [TerminalPaneModel]
    @Published var splitOrientation: PaneSplitOrientation

    init(
        id: UUID = UUID(),
        title: String,
        panes: [TerminalPaneModel],
        splitOrientation: PaneSplitOrientation = .horizontal
    ) {
        self.id = id
        self.title = title
        self.panes = panes
        self.splitOrientation = splitOrientation
    }
}

@MainActor
final class WorkspaceViewModel: ObservableObject {
    @Published var tabs: [TerminalTabModel]
    @Published var activeTabID: UUID?
    @Published var activePaneByTab: [UUID: UUID]

    init() {
        let firstPane = TerminalPaneModel()
        let firstTab = TerminalTabModel(title: "Session 1", panes: [firstPane])
        self.tabs = [firstTab]
        self.activeTabID = firstTab.id
        self.activePaneByTab = [firstTab.id: firstPane.id]
        applyPaneVisibility()
    }

    var activeTab: TerminalTabModel? {
        tab(id: activeTabID)
    }

    var activePane: TerminalPaneModel? {
        guard let tab = activeTab else { return nil }
        let preferredPaneID = activePaneByTab[tab.id]
        if let preferredPaneID,
           let pane = tab.panes.first(where: { $0.id == preferredPaneID })
        {
            return pane
        }
        return tab.panes.first
    }

    func tab(id: UUID?) -> TerminalTabModel? {
        guard let id else { return nil }
        return tabs.first(where: { $0.id == id })
    }

    func createTab() {
        let pane = TerminalPaneModel()
        let tab = TerminalTabModel(title: "Session \(tabs.count + 1)", panes: [pane])
        tabs.append(tab)
        activeTabID = tab.id
        activePaneByTab[tab.id] = pane.id
        pane.runtime.connectLocalShell()
        applyPaneVisibility()
    }

    func closeTab(_ tabID: UUID) {
        guard tabs.count > 1 else { return }
        if let tab = tab(id: tabID) {
            tab.panes.forEach { $0.runtime.disconnect() }
        }

        tabs.removeAll { $0.id == tabID }
        activePaneByTab.removeValue(forKey: tabID)

        if activeTabID == tabID {
            activeTabID = tabs.first?.id
        }
        applyPaneVisibility()
    }

    func renameTab(_ tabID: UUID, title: String) {
        guard let tab = tab(id: tabID) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        tab.title = trimmed
    }

    func selectTab(_ tabID: UUID) {
        activeTabID = tabID
        if activePaneByTab[tabID] == nil,
           let pane = tab(id: tabID)?.panes.first
        {
            activePaneByTab[tabID] = pane.id
        }

        applyPaneVisibility()
    }

    func selectPane(_ paneID: UUID, in tabID: UUID) {
        activePaneByTab[tabID] = paneID
    }

    func splitActiveTab(orientation: PaneSplitOrientation) {
        guard let tab = activeTab else { return }
        guard tab.panes.count == 1 else { return }

        tab.splitOrientation = orientation
        let pane = TerminalPaneModel()
        tab.panes.append(pane)
        activePaneByTab[tab.id] = pane.id
        applyPaneVisibility()
    }

    func connectActivePane(host: RemoraCore.Host, template: HostSessionTemplate?) {
        guard let pane = activePane else { return }

        let finalUser = template?.usernameOverride ?? host.username
        let finalPort = template?.portOverride ?? host.port
        let finalKey = template?.privateKeyPath ?? host.auth.keyReference

        var resolvedHost = host
        resolvedHost.username = finalUser
        resolvedHost.port = finalPort

        if let templateKey = template?.privateKeyPath {
            let trimmedTemplateKey = templateKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedTemplateKey.isEmpty {
                if host.auth.method == .privateKey {
                    resolvedHost.auth = HostAuth(method: .agent)
                }
            } else {
                resolvedHost.auth = HostAuth(method: .privateKey, keyReference: trimmedTemplateKey)
            }
        } else if let finalKey {
            let trimmedFinalKey = finalKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if resolvedHost.auth.method == .privateKey {
                resolvedHost.auth = HostAuth(
                    method: .privateKey,
                    keyReference: trimmedFinalKey.isEmpty ? nil : trimmedFinalKey
                )
            }
        }

        pane.runtime.connectSSH(host: resolvedHost)
    }

    func disconnectActivePane() {
        activePane?.runtime.disconnect()
    }

    func applyPaneVisibility() {
        for tab in tabs {
            let isVisible = tab.id == activeTabID
            for pane in tab.panes {
                pane.runtime.setPaneActive(isVisible)
            }
        }
    }
}
