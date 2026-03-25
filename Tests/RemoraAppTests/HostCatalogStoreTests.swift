import Foundation
import Testing
@testable import RemoraApp
import RemoraCore

@Suite(.serialized)
@MainActor
struct HostCatalogStoreTests {
    @Test
    func malformedPersistedCatalogIsNotOverwrittenAfterLoadFailure() async throws {
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("remora-host-catalog-corrupt-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: baseDirectory) }

        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        let fileURL = baseDirectory.appendingPathComponent("connections.json")
        let originalData = Data("{not-valid-json".utf8)
        try originalData.write(to: fileURL)

        let store = HostCatalogStore(
            persistenceStore: HostCatalogPersistenceStore(baseDirectoryURL: baseDirectory),
            persistenceEnabled: true
        )

        #expect(await waitUntil(timeout: 1.0) { !store.isLoading })

        _ = store.addGroup(named: "Ops")
        try await Task.sleep(nanoseconds: 200_000_000)

        let reloaded = try Data(contentsOf: fileURL)
        #expect(reloaded == originalData)
    }

    @Test
    func startsWithEmptyCatalogByDefault() {
        let store = HostCatalogStore()
        #expect(store.hosts.isEmpty)
        #expect(store.groups.isEmpty)
    }

    @Test
    func quickConnectSupportsExactAndFuzzyMatch() {
        let store = HostCatalogStore()
        _ = store.addHost(
            Host(
                name: "prod-api",
                address: "10.0.0.10",
                username: "deploy",
                group: "Production",
                tags: ["api"],
                auth: HostAuth(method: .agent)
            )
        )
        _ = store.addHost(
            Host(
                name: "staging-api",
                address: "10.0.1.10",
                username: "deploy",
                group: "Staging",
                tags: ["api"],
                auth: HostAuth(method: .agent)
            )
        )

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
        let first = store.addHost(
            Host(
                name: "first",
                address: "10.0.0.1",
                username: "root",
                group: "Ops",
                auth: HostAuth(method: .agent)
            )
        )
        let second = store.addHost(
            Host(
                name: "second",
                address: "10.0.0.2",
                username: "root",
                group: "Ops",
                auth: HostAuth(method: .agent)
            )
        )

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
    func supportsRenameForHostAndGroup() {
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
    }

    @Test
    func deletingGroupCanKeepHostsInUngroupedSection() {
        let store = HostCatalogStore()
        let groupName = store.addGroup(named: "Production")
        let host = store.addHost(
            Host(
                name: "prod-api",
                address: "10.0.0.10",
                username: "deploy",
                group: groupName,
                auth: HostAuth(method: .agent)
            )
        )

        store.deleteGroup(named: groupName, deleteHosts: false)

        #expect(store.groups.contains(groupName) == false)
        #expect(store.host(id: host.id)?.group == HostCatalogStore.ungroupedGroupIdentifier)
        #expect(store.ungroupedHosts(matching: "").contains(where: { $0.id == host.id }))
    }

    @Test
    func deletingGroupCanAlsoDeleteContainedHosts() {
        let store = HostCatalogStore()
        let groupName = store.addGroup(named: "Production")
        let host = store.addHost(
            Host(
                name: "prod-api",
                address: "10.0.0.10",
                username: "deploy",
                group: groupName,
                auth: HostAuth(method: .agent)
            )
        )

        store.deleteGroup(named: groupName, deleteHosts: true)

        #expect(store.groups.contains(groupName) == false)
        #expect(store.host(id: host.id) == nil)
        #expect(store.ungroupedHosts(matching: "").contains(where: { $0.id == host.id }) == false)
    }

    @Test
    func internalUngroupedIdentifierCannotBeManagedAsUserGroup() {
        let store = HostCatalogStore()

        let created = store.addGroup(named: HostCatalogStore.ungroupedGroupIdentifier)
        #expect(created == "New Group")
        #expect(store.groups.contains(HostCatalogStore.ungroupedGroupIdentifier) == false)

        let renamed = store.renameGroup(from: "New Group", to: HostCatalogStore.ungroupedGroupIdentifier)
        #expect(renamed == "New Group")
        #expect(store.groups.contains(HostCatalogStore.ungroupedGroupIdentifier) == false)

        store.deleteGroup(named: HostCatalogStore.ungroupedGroupIdentifier, deleteHosts: true)
        #expect(store.groups.contains(HostCatalogStore.ungroupedGroupIdentifier) == false)
    }

    @Test
    func supportsDetailedHostCreateAndEdit() {
        let store = HostCatalogStore()
        _ = store.addHost(
            Host(
                name: "prod-api",
                address: "10.0.0.10",
                username: "deploy",
                group: "Production",
                auth: HostAuth(method: .agent)
            )
        )

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
        #expect(updated?.group == HostCatalogStore.ungroupedGroupIdentifier)
        #expect(updated?.auth.method == .agent)
        #expect(store.groups.contains("New Group") == false)
    }

    @Test
    func moveHostCanReorderAcrossUngroupedAndGroups() {
        let store = HostCatalogStore()
        let alpha = store.addGroup(named: "Alpha")
        let beta = store.addGroup(named: "Beta")

        let ungrouped = store.addHost(
            Host(name: "ungrouped", address: "10.0.0.1", username: "root", group: "", auth: HostAuth(method: .agent))
        )
        let alphaFirst = store.addHost(
            Host(name: "alpha-1", address: "10.0.0.2", username: "root", group: alpha, auth: HostAuth(method: .agent))
        )
        let alphaSecond = store.addHost(
            Host(name: "alpha-2", address: "10.0.0.3", username: "root", group: alpha, auth: HostAuth(method: .agent))
        )
        let betaOnly = store.addHost(
            Host(name: "beta-1", address: "10.0.0.4", username: "root", group: beta, auth: HostAuth(method: .agent))
        )

        store.moveHost(id: alphaSecond.id, toGroup: HostCatalogStore.ungroupedGroupIdentifier, before: ungrouped.id)
        #expect(store.ungroupedHosts(matching: "").map(\.id) == [alphaSecond.id, ungrouped.id])

        store.moveHost(id: ungrouped.id, toGroup: beta, before: betaOnly.id)
        let betaHosts = store.groupSections(matching: "")
            .first(where: { $0.name == beta })?
            .hosts
            .map(\.id)
        #expect(betaHosts == [ungrouped.id, betaOnly.id])

        let alphaHosts = store.groupSections(matching: "")
            .first(where: { $0.name == alpha })?
            .hosts
            .map(\.id)
        #expect(alphaHosts == [alphaFirst.id])
    }

    @Test
    func moveGroupCanReorderTopLevelGroups() {
        let store = HostCatalogStore()
        _ = store.addGroup(named: "Alpha")
        _ = store.addGroup(named: "Beta")
        _ = store.addGroup(named: "Gamma")

        store.moveGroup(named: "Gamma", before: "Beta")
        #expect(store.groups == ["Alpha", "Gamma", "Beta"])

        store.moveGroup(named: "Alpha", before: nil)
        #expect(store.groups == ["Gamma", "Beta", "Alpha"])
    }

    @Test
    func supportsQuickCommandCrud() {
        let store = HostCatalogStore()
        let host = store.addHost(
            Host(
                name: "ops",
                address: "10.0.0.20",
                username: "root",
                group: "Ops",
                auth: HostAuth(method: .agent)
            )
        )

        let first = store.addQuickCommand(hostID: host.id, name: "Deploy", command: " ./deploy.sh ")
        #expect(first?.name == "Deploy")
        #expect(first?.command == "./deploy.sh")

        let second = store.addQuickCommand(hostID: host.id, name: "Deploy", command: "echo done")
        #expect(second?.name == "Deploy 2")

        let updated = store.updateQuickCommand(
            hostID: host.id,
            quickCommand: HostQuickCommand(
                id: first?.id ?? UUID(),
                name: "Deploy 2",
                command: " ./deploy-safe.sh "
            )
        )
        #expect(updated?.name == "Deploy 2 2")
        #expect(updated?.command == "./deploy-safe.sh")

        let rejected = store.updateQuickCommand(
            hostID: host.id,
            quickCommand: HostQuickCommand(
                id: first?.id ?? UUID(),
                name: "Invalid",
                command: "   "
            )
        )
        #expect(rejected == nil)

        if let second {
            store.deleteQuickCommand(hostID: host.id, quickCommandID: second.id)
        }
        #expect(store.quickCommands(for: host.id).count == 1)
    }

    @Test
    func supportsQuickPathCrud() {
        let store = HostCatalogStore()
        let host = store.addHost(
            Host(
                name: "ops",
                address: "10.0.0.21",
                username: "root",
                group: "Ops",
                auth: HostAuth(method: .agent)
            )
        )

        let first = store.addQuickPath(hostID: host.id, name: "Logs", path: " /var/log ")
        #expect(first?.name == "Logs")
        #expect(first?.path == "/var/log")

        let second = store.addQuickPath(hostID: host.id, name: "Logs", path: "/srv/app")
        #expect(second?.name == "Logs 2")

        let updated = store.updateQuickPath(
            hostID: host.id,
            quickPath: HostQuickPath(
                id: first?.id ?? UUID(),
                name: "Logs 2",
                path: "tmp"
            )
        )
        #expect(updated?.name == "Logs 2 2")
        #expect(updated?.path == "/tmp")

        let rejected = store.updateQuickPath(
            hostID: host.id,
            quickPath: HostQuickPath(
                id: first?.id ?? UUID(),
                name: "Invalid",
                path: "   "
            )
        )
        #expect(rejected == nil)

        if let second {
            store.deleteQuickPath(hostID: host.id, quickPathID: second.id)
        }
        #expect(store.quickPaths(for: host.id).count == 1)
    }

    @Test
    func normalizesQuickCommandsDuringHostSave() {
        let store = HostCatalogStore()
        let host = store.addHost(
            Host(
                name: "qa",
                address: "10.0.0.30",
                username: "qa",
                group: "QA",
                auth: HostAuth(method: .agent),
                quickCommands: [
                    HostQuickCommand(name: " ", command: " ls -la "),
                    HostQuickCommand(name: "Deploy", command: "echo one"),
                    HostQuickCommand(name: "Deploy", command: "echo two"),
                    HostQuickCommand(name: "Drop", command: "   "),
                ]
            )
        )

        let names = host.quickCommands.map(\.name)
        let commands = host.quickCommands.map(\.command)
        #expect(names == ["Command", "Deploy", "Deploy 2"])
        #expect(commands == ["ls -la", "echo one", "echo two"])
    }

    @Test
    func normalizesQuickPathsDuringHostSave() {
        let store = HostCatalogStore()
        let host = store.addHost(
            Host(
                name: "qa",
                address: "10.0.0.31",
                username: "qa",
                group: "QA",
                auth: HostAuth(method: .agent),
                quickPaths: [
                    HostQuickPath(name: " ", path: " /var/log "),
                    HostQuickPath(name: "Logs", path: "/srv/app"),
                    HostQuickPath(name: "Logs", path: "srv/app/releases"),
                    HostQuickPath(name: "Drop", path: "   "),
                ]
            )
        )

        let names = host.quickPaths.map(\.name)
        let paths = host.quickPaths.map(\.path)
        #expect(names == ["Path", "Logs", "Logs 2"])
        #expect(paths == ["/var/log", "/srv/app", "/srv/app/releases"])
    }

    @Test
    func importsHostsAndUpdatesExistingRecords() {
        let store = HostCatalogStore()
        let existing = store.addHost(
            Host(
                name: "existing",
                address: "10.0.0.10",
                username: "deploy",
                group: "Production",
                auth: HostAuth(method: .agent)
            )
        )

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

@MainActor
private func waitUntil(timeout: TimeInterval, condition: @escaping @MainActor () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() {
            return true
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    return condition()
}
