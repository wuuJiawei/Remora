import Testing
@testable import RemoraApp

@MainActor
struct WorkspaceViewModelTests {
    @Test
    func createAndCloseTab() {
        let workspace = WorkspaceViewModel()

        #expect(workspace.tabs.count == 1)
        let firstTabID = workspace.tabs[0].id

        workspace.createTab()
        #expect(workspace.tabs.count == 2)
        #expect(workspace.activeTabID != firstTabID)

        workspace.closeTab(firstTabID)
        #expect(workspace.tabs.count == 1)
    }

    @Test
    func splitActiveTabCreatesSecondPane() {
        let workspace = WorkspaceViewModel()
        let tab = workspace.tabs[0]

        workspace.splitActiveTab(orientation: .vertical)

        #expect(tab.panes.count == 2)
        #expect(tab.splitOrientation == .vertical)
        #expect(workspace.activePane != nil)
    }

    @Test
    func customTabTitleUsesSuffixToAvoidDuplicates() {
        let workspace = WorkspaceViewModel()

        workspace.createTab(title: "prod-api")
        workspace.createTab(title: "prod-api")
        workspace.createTab(title: "prod-api")

        let titles = workspace.tabs.map(\.title)
        #expect(titles.contains("prod-api"))
        #expect(titles.contains("prod-api(1)"))
        #expect(titles.contains("prod-api(2)"))
    }

    @Test
    func createTabCanSkipLocalAutoConnect() async {
        let workspace = WorkspaceViewModel()

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
        let workspace = WorkspaceViewModel()
        let firstTabID = workspace.tabs[0].id

        workspace.closeTab(firstTabID)

        #expect(workspace.tabs.isEmpty)
        #expect(workspace.activeTabID == nil)
    }

    @Test
    func closeAllInactiveTabsKeepsActiveTab() {
        let workspace = WorkspaceViewModel()

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
        let workspace = WorkspaceViewModel()

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
        let workspace = WorkspaceViewModel()

        workspace.createTab(title: "Session 2", connectLocalShell: false)
        workspace.createTab(title: "Session 3", connectLocalShell: false)

        workspace.closeAllTabs()

        #expect(workspace.tabs.isEmpty)
        #expect(workspace.activeTabID == nil)
        #expect(workspace.activePane == nil)
    }
}
