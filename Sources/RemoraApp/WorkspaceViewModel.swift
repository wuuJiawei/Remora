import Foundation
import RemoraCore
import RemoraTerminal

enum PaneSplitOrientation: String, CaseIterable, Identifiable {
    case horizontal = "Horizontal"
    case vertical = "Vertical"

    var id: String { rawValue }
}

@MainActor
final class TerminalPaneModel: ObservableObject, Identifiable {
    let id: UUID
    let runtime: TerminalRuntime
    let terminalView: TerminalView
    let aiAssistant: TerminalAIAssistantCoordinator
    @Published var isAIAssistantVisible: Bool

    init(
        id: UUID = UUID(),
        runtime: TerminalRuntime = TerminalPaneModel.defaultRuntime(),
        terminalView: TerminalView = TerminalPaneModel.defaultTerminalView(),
        aiAssistant: TerminalAIAssistantCoordinator? = nil,
        isAIAssistantVisible: Bool = false
    ) {
        self.id = id
        self.runtime = runtime
        self.terminalView = terminalView
        self.aiAssistant = aiAssistant ?? TerminalPaneModel.defaultAIAssistant(for: runtime)
        self.isAIAssistantVisible = isAIAssistantVisible
        self.aiAssistant.bind(to: id)
    }

    private static func defaultRuntime() -> TerminalRuntime {
        if ProcessInfo.processInfo.environment["REMORA_RUN_UI_TESTS"] == "1" {
            let mockManager = SessionManager(sshClientFactory: { MockSSHClient() })
            return TerminalRuntime(localSessionManager: mockManager, sshSessionManager: mockManager)
        }
        return TerminalRuntime()
    }

    private static func defaultTerminalView() -> TerminalView {
        TerminalView(rows: 30, columns: 120)
    }

    private static func defaultAIAssistant(for runtime: TerminalRuntime) -> TerminalAIAssistantCoordinator {
        TerminalAIAssistantCoordinator {
            let hostLabel = runtime.connectedSSHHost?.name ?? runtime.connectedSSHHost?.address
            return TerminalAIRuntimeSnapshot(
                sessionMode: runtime.connectionMode.rawValue,
                hostLabel: hostLabel,
                workingDirectory: runtime.workingDirectory,
                transcript: runtime.transcriptSnapshot
            )
        }
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
    private let paneFactory: () -> TerminalPaneModel

    init(paneFactory: @escaping () -> TerminalPaneModel = { TerminalPaneModel() }) {
        self.tabs = []
        self.activeTabID = nil
        self.activePaneByTab = [:]
        self.paneFactory = paneFactory
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

    func createTab(title preferredTitle: String? = nil, connectLocalShell: Bool = true) {
        let pane = makePane()
        let baseTitle: String = {
            if let preferredTitle {
                let trimmed = preferredTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
            return "Local"
        }()
        let tab = TerminalTabModel(title: uniqueTabTitle(base: baseTitle), panes: [pane])
        tabs.append(tab)
        activeTabID = tab.id
        activePaneByTab[tab.id] = pane.id
        if connectLocalShell {
            pane.runtime.connectLocalShell()
        }
        applyPaneVisibility()
    }

    func closeTab(_ tabID: UUID) {
        closeTabs(withIDs: [tabID])
    }

    func closeAllTabs() {
        closeTabs(withIDs: Set(tabs.map(\.id)))
    }

    func closeAllInactiveTabs() {
        guard let activeTabID else { return }
        let inactiveIDs = Set(tabs.map(\.id).filter { $0 != activeTabID })
        closeTabs(withIDs: inactiveIDs)
    }

    func closeTabsLeft(of tabID: UUID) {
        guard let tabIndex = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        let leftIDs = Set(tabs.prefix(tabIndex).map(\.id))
        closeTabs(withIDs: leftIDs)
    }

    func closeTabsRight(of tabID: UUID) {
        guard let tabIndex = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        let rightIDs = Set(tabs.suffix(from: tabIndex + 1).map(\.id))
        closeTabs(withIDs: rightIDs)
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
        guard let tab = activeTab, let sourcePane = activePane else { return }
        guard tab.panes.count == 1 else { return }

        tab.splitOrientation = orientation
        let pane = makePane()
        tab.panes.append(pane)
        activePaneByTab[tab.id] = pane.id
        duplicateConnectionIfNeeded(from: sourcePane, to: pane)
        applyPaneVisibility()
    }

    func closePane(_ paneID: UUID, in tabID: UUID) {
        guard let tab = tab(id: tabID) else { return }
        guard tab.panes.count > 1 else { return }
        guard let paneIndex = tab.panes.firstIndex(where: { $0.id == paneID }) else { return }

        let closingPane = tab.panes.remove(at: paneIndex)
        closingPane.runtime.disconnect()

        if activePaneByTab[tabID] == paneID {
            activePaneByTab[tabID] = tab.panes.first?.id
        }

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

    private func uniqueTabTitle(base: String) -> String {
        let existing = Set(tabs.map { $0.title.lowercased() })
        if !existing.contains(base.lowercased()) {
            return base
        }

        var index = 2
        while existing.contains("\(base)(\(index))".lowercased()) {
            index += 1
        }
        return "\(base)(\(index))"
    }

    private func makePane() -> TerminalPaneModel {
        paneFactory()
    }

    private func duplicateConnectionIfNeeded(from sourcePane: TerminalPaneModel, to targetPane: TerminalPaneModel) {
        if let host = sourcePane.runtime.reconnectableSSHHost {
            targetPane.runtime.connectSSH(host: host)
            return
        }
        if sourcePane.runtime.connectionMode == .local {
            targetPane.runtime.connectLocalShell()
        }
    }

    private func closeTabs(withIDs tabIDs: Set<UUID>) {
        guard !tabIDs.isEmpty else { return }

        let currentTabs = tabs
        for tab in currentTabs where tabIDs.contains(tab.id) {
            tab.panes.forEach { $0.runtime.disconnect() }
        }

        tabs.removeAll { tabIDs.contains($0.id) }
        for id in tabIDs {
            activePaneByTab.removeValue(forKey: id)
        }

        if let activeTabID, tabIDs.contains(activeTabID) {
            self.activeTabID = nextActiveTabID(
                afterClosing: tabIDs,
                previousTabs: currentTabs,
                previousActiveID: activeTabID
            )
        } else if self.activeTabID == nil {
            self.activeTabID = tabs.first?.id
        }

        applyPaneVisibility()
    }

    private func nextActiveTabID(
        afterClosing closedIDs: Set<UUID>,
        previousTabs: [TerminalTabModel],
        previousActiveID: UUID
    ) -> UUID? {
        guard let previousActiveIndex = previousTabs.firstIndex(where: { $0.id == previousActiveID }) else {
            return tabs.first?.id
        }

        if let rightNeighbor = previousTabs[(previousActiveIndex + 1)...].first(where: { !closedIDs.contains($0.id) }) {
            return rightNeighbor.id
        }

        if previousActiveIndex > 0,
           let leftNeighbor = previousTabs[..<previousActiveIndex].last(where: { !closedIDs.contains($0.id) })
        {
            return leftNeighbor.id
        }

        return nil
    }
}
