import Foundation
import Testing
import RemoraCore
@testable import RemoraApp

@MainActor
struct WorkspaceViewModelTests {
    private func waitUntil(
        timeout: TimeInterval,
        interval: TimeInterval = 0.02,
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
        return condition()
    }

    private func makeWorkspace() -> WorkspaceViewModel {
        WorkspaceViewModel(
            paneFactory: {
                let manager = SessionManager(sshClientFactory: { MockSSHClient() })
                let runtime = TerminalRuntime(localSessionManager: manager, sshSessionManager: manager, remoteShellIntegrationInstaller: { _ in })
                return TerminalPaneModel(runtime: runtime)
            }
        )
    }

    @Test
    func startsWithoutDefaultSessionTab() {
        let workspace = makeWorkspace()

        #expect(workspace.tabs.isEmpty)
        #expect(workspace.activeTabID == nil)
        #expect(workspace.activePane == nil)
    }

    @Test
    func createAndCloseTab() {
        let workspace = makeWorkspace()

        #expect(workspace.tabs.count == 0)

        workspace.createTab()
        #expect(workspace.tabs.count == 1)
        guard let createdTabID = workspace.activeTabID else {
            Issue.record("Expected active tab after creating one.")
            return
        }

        workspace.closeTab(createdTabID)
        #expect(workspace.tabs.count == 0)
        #expect(workspace.activeTabID == nil)
    }

    @Test
    func splitActiveTabCreatesSecondPane() {
        let workspace = makeWorkspace()
        workspace.createTab(connectLocalShell: false)
        guard let tab = workspace.tabs.first else {
            Issue.record("Expected tab before split.")
            return
        }

        workspace.splitActiveTab(orientation: .vertical)

        #expect(tab.panes.count == 2)
        #expect(tab.splitOrientation == .vertical)
        #expect(workspace.activePane != nil)
    }

    @Test
    func customTabTitleUsesSuffixToAvoidDuplicates() {
        let workspace = makeWorkspace()

        workspace.createTab(title: "prod-api")
        workspace.createTab(title: "prod-api")
        workspace.createTab(title: "prod-api")

        let titles = workspace.tabs.map(\.title)
        #expect(titles.contains("prod-api"))
        #expect(titles.contains("prod-api(2)"))
        #expect(titles.contains("prod-api(3)"))
    }

    @Test
    func defaultLocalTabsUseLocalTitleWithSequence() {
        let workspace = makeWorkspace()

        workspace.createTab(connectLocalShell: false)
        workspace.createTab(connectLocalShell: false)
        workspace.createTab(connectLocalShell: false)

        let titles = workspace.tabs.map(\.title)
        #expect(titles == ["Local", "Local(2)", "Local(3)"])
    }

    @Test
    func createTabCanSkipLocalAutoConnect() async {
        let workspace = makeWorkspace()

        workspace.createTab(title: "ssh-target", connectLocalShell: false)
        guard let activePane = workspace.activePane else {
            Issue.record("Expected active pane after creating tab.")
            return
        }

        try? await Task.sleep(nanoseconds: 250_000_000)
        #expect(activePane.runtime.connectionState == "Idle")
    }

    @Test
    func closeTabCanRemoveLastTab() {
        let workspace = makeWorkspace()
        workspace.createTab(connectLocalShell: false)
        guard let firstTabID = workspace.tabs.first?.id else {
            Issue.record("Expected tab for close-last test.")
            return
        }

        workspace.closeTab(firstTabID)

        #expect(workspace.tabs.isEmpty)
        #expect(workspace.activeTabID == nil)
    }

    @Test
    func closeAllInactiveTabsKeepsActiveTab() {
        let workspace = makeWorkspace()

        workspace.createTab(title: "Session 1", connectLocalShell: false)
        workspace.createTab(title: "Session 2", connectLocalShell: false)
        let secondTabID = workspace.tabs.last?.id
        workspace.createTab(title: "Session 3", connectLocalShell: false)
        workspace.createTab(title: "Session 4", connectLocalShell: false)

        guard let secondTabID else {
            Issue.record("Expected Session 2 tab id.")
            return
        }

        workspace.selectTab(secondTabID)
        workspace.closeAllInactiveTabs()

        #expect(workspace.tabs.count == 1)
        #expect(workspace.tabs.first?.id == secondTabID)
        #expect(workspace.activeTabID == secondTabID)
    }

    @Test
    func closeTabsLeftAndRightUseReferenceTab() {
        let workspace = makeWorkspace()

        workspace.createTab(title: "Session 1", connectLocalShell: false)
        workspace.createTab(title: "Session 2", connectLocalShell: false)
        workspace.createTab(title: "Session 3", connectLocalShell: false)
        workspace.createTab(title: "Session 4", connectLocalShell: false)
        workspace.createTab(title: "Session 5", connectLocalShell: false)

        let tabIDs = workspace.tabs.map(\.id)
        guard tabIDs.count == 5 else {
            Issue.record("Expected five tabs for close-left/right test.")
            return
        }
        let referenceTabID = tabIDs[2]

        workspace.closeTabsLeft(of: referenceTabID)

        #expect(workspace.tabs.map(\.id) == [tabIDs[2], tabIDs[3], tabIDs[4]])

        workspace.closeTabsRight(of: referenceTabID)

        #expect(workspace.tabs.map(\.id) == [tabIDs[2]])
    }

    @Test
    func closeAllTabsRemovesEverything() {
        let workspace = makeWorkspace()

        workspace.createTab(title: "Session 1", connectLocalShell: false)
        workspace.createTab(title: "Session 2", connectLocalShell: false)
        workspace.createTab(title: "Session 3", connectLocalShell: false)

        workspace.closeAllTabs()

        #expect(workspace.tabs.isEmpty)
        #expect(workspace.activeTabID == nil)
        #expect(workspace.activePane == nil)
    }

    @Test
    func splitActiveTabReconnectsCurrentSSHInNewPane() async {
        let workspace = makeWorkspace()
        let host = Host(
            name: "prod-api",
            address: "47.100.100.215",
            username: "root",
            group: "Production",
            auth: HostAuth(method: .agent)
        )

        workspace.createTab(connectLocalShell: false)
        guard let originalPane = workspace.activePane,
              let tab = workspace.activeTab
        else {
            Issue.record("Expected active pane before SSH split.")
            return
        }
        let originalTerminalView = originalPane.terminalView

        workspace.connectActivePane(host: host, template: nil)
        let firstConnected = await waitUntil(timeout: 2.0) {
            originalPane.runtime.connectedSSHHost?.id == host.id
                && originalPane.runtime.connectionState.contains("Connected (SSH)")
        }
        #expect(firstConnected, "Expected original pane to connect before splitting.")
        guard firstConnected else { return }

        workspace.splitActiveTab(orientation: .horizontal)

        #expect(tab.panes.count == 2)
        guard let splitPane = tab.panes.last else {
            Issue.record("Expected split pane after splitting.")
            return
        }
        #expect(originalPane.terminalView === originalTerminalView)
        #expect(splitPane.id != originalPane.id)
        #expect(workspace.activePane?.id == splitPane.id)

        let secondConnected = await waitUntil(timeout: 2.0) {
            splitPane.runtime.connectedSSHHost?.id == host.id
                && splitPane.runtime.connectionState.contains("Connected (SSH)")
        }
        #expect(secondConnected, "Expected split pane to reconnect using the current SSH host.")
        #expect(originalPane.runtime.connectedSSHHost?.id == host.id)

        tab.panes.forEach { $0.runtime.disconnect() }
    }

    @Test
    func closePaneRemovesSplitPaneAndKeepsRemainingPaneActive() async {
        let workspace = makeWorkspace()
        let host = Host(
            name: "prod-api",
            address: "47.100.100.215",
            username: "root",
            group: "Production",
            auth: HostAuth(method: .agent)
        )

        workspace.createTab(connectLocalShell: false)
        guard let originalPane = workspace.activePane,
              let tab = workspace.activeTab
        else {
            Issue.record("Expected active pane before close-pane test.")
            return
        }
        let originalTerminalView = originalPane.terminalView

        workspace.connectActivePane(host: host, template: nil)
        let firstConnected = await waitUntil(timeout: 2.0) {
            originalPane.runtime.connectedSSHHost?.id == host.id
        }
        #expect(firstConnected)
        guard firstConnected else { return }

        workspace.splitActiveTab(orientation: .vertical)
        guard let splitPane = tab.panes.last else {
            Issue.record("Expected split pane before closing.")
            return
        }

        let secondConnected = await waitUntil(timeout: 2.0) {
            splitPane.runtime.connectedSSHHost?.id == host.id
        }
        #expect(secondConnected)
        guard secondConnected else { return }

        workspace.closePane(splitPane.id, in: tab.id)

        #expect(tab.panes.count == 1)
        #expect(tab.panes.first?.id == originalPane.id)
        #expect(tab.panes.first?.terminalView === originalTerminalView)
        #expect(workspace.activePaneByTab[tab.id] == originalPane.id)
        #expect(workspace.activePane?.id == originalPane.id)
        #expect(originalPane.runtime.connectedSSHHost?.id == host.id)

        originalPane.runtime.disconnect()
    }
}
