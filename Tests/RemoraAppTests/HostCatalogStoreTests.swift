import Testing
@testable import RemoraApp
import RemoraCore

@MainActor
struct HostCatalogStoreTests {
    @Test
    func quickConnectSupportsExactAndFuzzyMatch() {
        let store = HostCatalogStore()

        let exact = store.quickConnectMatch(input: "prod-api")
        #expect(exact?.name == "prod-api")

        let fuzzy = store.quickConnectMatch(input: "staging")
        #expect(fuzzy?.name == "staging-api")

        let missing = store.quickConnectMatch(input: "unknown-host")
        #expect(missing == nil)
    }

    @Test
    func marksRecentHostsInOrder() {
        let store = HostCatalogStore()
        let first = store.hosts[0]
        let second = store.hosts[1]

        store.markConnected(hostID: first.id)
        store.markConnected(hostID: second.id)
        store.markConnected(hostID: first.id)

        let recents = store.recents(matching: "")
        #expect(recents.first?.id == first.id)
        #expect(recents.dropFirst().first?.id == second.id)
    }

    @Test
    func supportsGroupAndThreadCrud() {
        let store = HostCatalogStore()

        let groupName = store.addGroup(named: "Threads")
        #expect(store.groups.contains(groupName))

        let host = store.addHost(in: groupName)
        #expect(store.host(id: host.id)?.group == groupName)
        #expect(store.groupSections(matching: "").contains(where: { $0.name == groupName && $0.hosts.contains(where: { $0.id == host.id }) }))

        store.deleteHost(id: host.id)
        #expect(store.host(id: host.id) == nil)

        store.deleteGroup(named: groupName)
        #expect(store.groups.contains(groupName) == false)
    }

    @Test
    func supportsRenamePinAndArchiveForHostAndGroup() {
        let store = HostCatalogStore()
        let originalGroup = store.groups.first ?? store.addGroup(named: "Default")
        let host = store.addHost(in: originalGroup)

        let renamedGroup = store.renameGroup(from: originalGroup, to: "Renamed Group")
        #expect(renamedGroup != nil)
        #expect(store.groups.contains("Renamed Group"))
        #expect(store.host(id: host.id)?.group == "Renamed Group")

        let renamedHost = store.renameHost(id: host.id, to: "my-ssh")
        #expect(renamedHost == "my-ssh")
        #expect(store.host(id: host.id)?.name == "my-ssh")

        store.toggleFavorite(hostID: host.id)
        #expect(store.host(id: host.id)?.favorite == true)

        store.archiveHost(id: host.id)
        #expect(store.host(id: host.id)?.group == "Archived")
        #expect(store.groups.contains("Archived"))
    }

    @Test
    func supportsDetailedHostCreateAndEdit() {
        let store = HostCatalogStore()

        let created = store.addHost(
            Host(
                name: " ",
                address: "192.168.50.10",
                port: 2201,
                username: "ops",
                group: "Ops",
                auth: HostAuth(method: .password, passwordReference: "cred-1")
            )
        )

        #expect(store.groups.contains("Ops"))
        #expect(created.name == "new-ssh")
        #expect(created.auth.method == .password)
        #expect(created.auth.passwordReference == "cred-1")

        var edited = created
        edited.name = "prod-api"
        edited.port = 0
        edited.group = " "
        edited.auth = HostAuth(method: .privateKey, keyReference: "")

        let updated = store.updateHost(edited)
        #expect(updated != nil)
        #expect(updated?.name == "prod-api-2")
        #expect(updated?.port == 22)
        #expect(updated?.group == "New Group")
        #expect(updated?.auth.method == .agent)
        #expect(store.groups.contains("New Group"))
    }

    @Test
    func importsHostsAndUpdatesExistingRecords() {
        let store = HostCatalogStore()
        let existing = store.hosts[0]

        let updatedExisting = Host(
            id: existing.id,
            name: "prod-api-updated",
            address: "10.0.0.99",
            port: 2200,
            username: "deploy",
            group: "Production",
            tags: ["imported"],
            favorite: true,
            auth: HostAuth(method: .agent)
        )

        let newHost = Host(
            name: "new-imported-host",
            address: "192.168.100.20",
            port: 22,
            username: "ops",
            group: "Imported",
            tags: ["batch"],
            auth: HostAuth(method: .agent)
        )

        let summary = store.importHosts([updatedExisting, newHost])

        #expect(summary.total == 2)
        #expect(summary.updated == 1)
        #expect(summary.created == 1)
        #expect(store.host(id: existing.id)?.address == "10.0.0.99")
        #expect(store.hosts.contains(where: { $0.name == "new-imported-host" }))
        #expect(store.groups.contains("Imported"))
    }
}
