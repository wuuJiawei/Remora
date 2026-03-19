import Testing
@testable import RemoraApp

struct BottomPanelVisibilityStateTests {
    @Test
    func collapsingTerminalOpensFileManagerWhenTerminalWasLastVisiblePanel() {
        var state = BottomPanelVisibilityState(terminal: true, fileManager: false)

        state.toggleTerminal(fileManagerAvailable: true)

        #expect(state.terminal == false)
        #expect(state.fileManager == true)
    }

    @Test
    func collapsingFileManagerOpensTerminalWhenFileManagerWasLastVisiblePanel() {
        var state = BottomPanelVisibilityState(terminal: false, fileManager: true)

        state.toggleFileManager(fileManagerAvailable: true)

        #expect(state.terminal == true)
        #expect(state.fileManager == false)
    }

    @Test
    func collapsingOnePanelKeepsTheOtherOpenWhenBothAreVisible() {
        var state = BottomPanelVisibilityState(terminal: true, fileManager: true)

        state.toggleTerminal(fileManagerAvailable: true)

        #expect(state.terminal == false)
        #expect(state.fileManager == true)
    }

    @Test
    func expandingClosedFileManagerAllowsBothPanelsToBeVisible() {
        var state = BottomPanelVisibilityState(terminal: true, fileManager: false)

        state.toggleFileManager(fileManagerAvailable: true)

        #expect(state.terminal == true)
        #expect(state.fileManager == true)
    }

    @Test
    func fileManagerUnavailabilityForcesTerminalToRemainVisible() {
        var state = BottomPanelVisibilityState(terminal: false, fileManager: true)

        state.normalize(fileManagerAvailable: false)

        #expect(state.terminal == true)
        #expect(state.fileManager == false)
    }

    @Test
    func collapsedTerminalLetsFileManagerTakeRemainingHeight() {
        let state = BottomPanelVisibilityState(terminal: false, fileManager: true)

        #expect(state.sessionShouldFillRemainingHeight(fileManagerAvailable: true) == false)
        #expect(state.fileManagerShouldFillRemainingHeight(fileManagerAvailable: true) == true)
    }

    @Test
    func visibleTerminalKeepsSessionAsPrimaryFlexibleRegion() {
        let state = BottomPanelVisibilityState(terminal: true, fileManager: true)

        #expect(state.sessionShouldFillRemainingHeight(fileManagerAvailable: true) == true)
        #expect(state.fileManagerShouldFillRemainingHeight(fileManagerAvailable: true) == false)
    }
}

struct SSHRefreshActionDecisionTests {
    @Test
    func connectedSSHChoosesRefresh() {
        let decision = SSHRefreshActionDecision.resolve(
            connectionState: "Connected (SSH)",
            hasReconnectableHost: true
        )

        #expect(decision == .refresh)
    }

    @Test
    func failedSSHChoosesReconnect() {
        let decision = SSHRefreshActionDecision.resolve(
            connectionState: "Failed: timeout",
            hasReconnectableHost: true
        )

        #expect(decision == .reconnect)
    }

    @Test
    func disconnectedSSHChoosesReconnect() {
        let decision = SSHRefreshActionDecision.resolve(
            connectionState: "Disconnected",
            hasReconnectableHost: true
        )

        #expect(decision == .reconnect)
    }

    @Test
    func missingReconnectableHostFallsBackToRefresh() {
        let decision = SSHRefreshActionDecision.resolve(
            connectionState: "Failed: timeout",
            hasReconnectableHost: false
        )

        #expect(decision == .refresh)
    }
}
