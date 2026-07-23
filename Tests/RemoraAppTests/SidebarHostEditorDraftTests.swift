import Testing
import RemoraCore
@testable import RemoraApp

@Suite("Host editor route draft")
struct SidebarHostEditorDraftTests {
    @Test("Existing direct hosts remain direct")
    func existingDirectHostRemainsDirect() {
        let host = Host(
            name: "direct",
            address: "10.0.0.4",
            username: "ops",
            auth: HostAuth(method: .agent)
        )

        let draft = SidebarHostEditorDraft(host: host)

        #expect(draft.routeMode == .direct)
        #expect(draft.connectionRoute == .direct)
    }

    @Test("Bound JumpServer route requires explicit target fields and password auth")
    func validatesBoundJumpServerRoute() {
        var draft = SidebarHostEditorDraft()
        draft.routeMode = .jumpServer
        draft.authMethod = .password
        draft.jumpServerPlatformUsername = "operator"
        #expect(!draft.canSave)

        draft.jumpServerAssetTarget = "10.0.0.8"
        draft.jumpServerAssetDisplayName = "Database"
        draft.jumpServerAccountUsername = "root"
        #expect(draft.canSave)

        draft.authMethod = .agent
        #expect(!draft.canSave)
    }

    @Test("Interactive JumpServer route is explicitly unbound")
    func buildsInteractiveJumpServerRoute() throws {
        var draft = SidebarHostEditorDraft()
        draft.routeMode = .jumpServer
        draft.authMethod = .password
        draft.jumpServerPlatformUsername = "operator"
        draft.jumpServerUsesInteractiveMenu = true

        let route = try #require(draft.connectionRoute)
        guard case .gateway(let gateway) = route else {
            Issue.record("Expected gateway route")
            return
        }
        #expect(gateway.target == nil)
        #expect(draft.canSave)
    }

    @Test("JumpServer delimiter errors disable saving")
    func rejectsInvalidDirectLoginComponents() {
        var draft = SidebarHostEditorDraft()
        draft.routeMode = .jumpServer
        draft.authMethod = .password
        draft.jumpServerPlatformUsername = "operator@example"
        draft.jumpServerUsesInteractiveMenu = true

        #expect(draft.connectionRoute == nil)
        #expect(!draft.canSave)
    }
}
