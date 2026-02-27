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
}
