import Foundation
import RemoraCore

struct HostSessionTemplate: Identifiable, Equatable, Hashable, Codable {
    let id: UUID
    var hostID: UUID
    var name: String
    var usernameOverride: String?
    var portOverride: Int?
    var privateKeyPath: String?

    init(
        id: UUID = UUID(),
        hostID: UUID,
        name: String,
        usernameOverride: String? = nil,
        portOverride: Int? = nil,
        privateKeyPath: String? = nil
    ) {
        self.id = id
        self.hostID = hostID
        self.name = name
        self.usernameOverride = usernameOverride
        self.portOverride = portOverride
        self.privateKeyPath = privateKeyPath
    }
}

struct HostGroupSection: Identifiable, Equatable {
    let name: String
    let hosts: [RemoraCore.Host]

    var id: String { name }
}

struct HostImportSummary: Equatable {
    var total: Int
    var created: Int
    var updated: Int
}

@MainActor
final class HostCatalogStore: ObservableObject {
    @Published private(set) var hosts: [RemoraCore.Host] {
        didSet { persistSnapshotIfNeeded() }
    }
    @Published private(set) var templates: [HostSessionTemplate] {
        didSet { persistSnapshotIfNeeded() }
    }
    @Published private(set) var recentHostIDs: [UUID] {
        didSet { persistSnapshotIfNeeded() }
    }
    @Published private(set) var groups: [String] {
        didSet { persistSnapshotIfNeeded() }
    }
    @Published private(set) var isLoading: Bool

    private let persistenceStore: HostCatalogPersistenceStore
    private let persistenceEnabled: Bool
    private var suppressPersistence = false

    init(
        persistenceStore: HostCatalogPersistenceStore = HostCatalogPersistenceStore(),
        persistenceEnabled: Bool = HostCatalogStore.defaultPersistenceEnabled
    ) {
        let defaults = Self.makeDefaultCatalog()
        self.hosts = defaults.hosts
        self.templates = defaults.templates
        self.recentHostIDs = defaults.recentHostIDs
        self.groups = defaults.groups
        self.persistenceStore = persistenceStore
        self.persistenceEnabled = persistenceEnabled
        self.isLoading = persistenceEnabled

        guard persistenceEnabled else { return }
        Task { [weak self] in
            await self?.loadPersistedCatalog()
        }
    }

    func host(id: UUID?) -> RemoraCore.Host? {
        guard let id else { return nil }
        return hosts.first(where: { $0.id == id })
    }

    func templates(for hostID: UUID?) -> [HostSessionTemplate] {
        guard let hostID else { return [] }
        return templates.filter { $0.hostID == hostID }
    }

    func quickCommands(for hostID: UUID?) -> [HostQuickCommand] {
        guard let hostID, let host = host(id: hostID) else { return [] }
        return host.quickCommands
    }

    func quickPaths(for hostID: UUID?) -> [HostQuickPath] {
        guard let hostID, let host = host(id: hostID) else { return [] }
        return host.quickPaths
    }

    @discardableResult
    func addQuickCommand(
        hostID: UUID,
        name: String,
        command: String
    ) -> HostQuickCommand? {
        guard let hostIndex = hosts.firstIndex(where: { $0.id == hostID }) else { return nil }
        let trimmedCommand = normalizeQuickCommandBody(command)
        guard !trimmedCommand.isEmpty else { return nil }

        let normalizedName = uniqueQuickCommandName(
            base: normalizeQuickCommandName(name),
            in: hosts[hostIndex].quickCommands,
            excludingID: nil
        )

        let quickCommand = HostQuickCommand(name: normalizedName, command: trimmedCommand)
        hosts[hostIndex].quickCommands.append(quickCommand)
        return quickCommand
    }

    @discardableResult
    func updateQuickCommand(
        hostID: UUID,
        quickCommand: HostQuickCommand
    ) -> HostQuickCommand? {
        guard let hostIndex = hosts.firstIndex(where: { $0.id == hostID }) else { return nil }
        guard let commandIndex = hosts[hostIndex].quickCommands.firstIndex(where: { $0.id == quickCommand.id }) else {
            return nil
        }

        let trimmedCommand = normalizeQuickCommandBody(quickCommand.command)
        guard !trimmedCommand.isEmpty else { return nil }

        let normalizedName = uniqueQuickCommandName(
            base: normalizeQuickCommandName(quickCommand.name),
            in: hosts[hostIndex].quickCommands,
            excludingID: quickCommand.id
        )

        hosts[hostIndex].quickCommands[commandIndex] = HostQuickCommand(
            id: quickCommand.id,
            name: normalizedName,
            command: trimmedCommand
        )
        return hosts[hostIndex].quickCommands[commandIndex]
    }

    func deleteQuickCommand(hostID: UUID, quickCommandID: UUID) {
        guard let hostIndex = hosts.firstIndex(where: { $0.id == hostID }) else { return }
        hosts[hostIndex].quickCommands.removeAll { $0.id == quickCommandID }
    }

    @discardableResult
    func addQuickPath(
        hostID: UUID,
        name: String,
        path: String
    ) -> HostQuickPath? {
        guard let hostIndex = hosts.firstIndex(where: { $0.id == hostID }) else { return nil }
        guard let normalizedPath = normalizeQuickPathValue(path) else { return nil }

        let normalizedName = uniqueQuickPathName(
            base: normalizeQuickPathName(name),
            in: hosts[hostIndex].quickPaths,
            excludingID: nil
        )

        let quickPath = HostQuickPath(name: normalizedName, path: normalizedPath)
        hosts[hostIndex].quickPaths.append(quickPath)
        return quickPath
    }

    @discardableResult
    func updateQuickPath(
        hostID: UUID,
        quickPath: HostQuickPath
    ) -> HostQuickPath? {
        guard let hostIndex = hosts.firstIndex(where: { $0.id == hostID }) else { return nil }
        guard let pathIndex = hosts[hostIndex].quickPaths.firstIndex(where: { $0.id == quickPath.id }) else {
            return nil
        }
        guard let normalizedPath = normalizeQuickPathValue(quickPath.path) else { return nil }

        let normalizedName = uniqueQuickPathName(
            base: normalizeQuickPathName(quickPath.name),
            in: hosts[hostIndex].quickPaths,
            excludingID: quickPath.id
        )

        hosts[hostIndex].quickPaths[pathIndex] = HostQuickPath(
            id: quickPath.id,
            name: normalizedName,
            path: normalizedPath
        )
        return hosts[hostIndex].quickPaths[pathIndex]
    }

    func deleteQuickPath(hostID: UUID, quickPathID: UUID) {
        guard let hostIndex = hosts.firstIndex(where: { $0.id == hostID }) else { return }
        hosts[hostIndex].quickPaths.removeAll { $0.id == quickPathID }
    }

    func markConnected(hostID: UUID) {
        recentHostIDs.removeAll { $0 == hostID }
        recentHostIDs.insert(hostID, at: 0)
        if recentHostIDs.count > 10 {
            recentHostIDs.removeLast(recentHostIDs.count - 10)
        }
    }

    func recents(matching query: String) -> [RemoraCore.Host] {
        let mapped = recentHostIDs.compactMap { id in
            hosts.first(where: { $0.id == id })
        }
        return filter(mapped, query: query)
    }

    func grouped(matching query: String) -> [(String, [RemoraCore.Host])] {
        groupSections(matching: query).map { ($0.name, $0.hosts) }
    }

    func groupSections(matching query: String) -> [HostGroupSection] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filteredHosts = filter(hosts, query: query)

        return groups.compactMap { groupName in
            let sectionHosts = filteredHosts
                .filter { $0.group == groupName }
                .sorted { lhs, rhs in
                    lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }

            if q.isEmpty {
                return HostGroupSection(name: groupName, hosts: sectionHosts)
            }

            let groupMatches = groupName.lowercased().contains(q)
            if groupMatches || !sectionHosts.isEmpty {
                return HostGroupSection(name: groupName, hosts: sectionHosts)
            }
            return nil
        }
    }

    @discardableResult
    func addGroup(named requestedName: String? = nil) -> String {
        let base = normalizedGroupName(requestedName ?? "New Group")
        let unique = uniqueGroupName(base: base)
        groups.append(unique)
        return unique
    }

    @discardableResult
    func renameGroup(from oldName: String, to requestedName: String) -> String? {
        guard let groupIndex = groups.firstIndex(of: oldName) else { return nil }
        let normalized = normalizedGroupName(requestedName)
        guard !normalized.isEmpty else { return nil }

        let finalName: String
        if normalized == oldName {
            finalName = oldName
        } else if groups.contains(normalized) {
            finalName = uniqueGroupName(base: normalized)
        } else {
            finalName = normalized
        }

        groups[groupIndex] = finalName
        for idx in hosts.indices where hosts[idx].group == oldName {
            hosts[idx].group = finalName
        }
        return finalName
    }

    func deleteGroup(named groupName: String) {
        let removedHostIDs = Set(hosts.filter { $0.group == groupName }.map(\.id))
        hosts.removeAll { $0.group == groupName }
        templates.removeAll { removedHostIDs.contains($0.hostID) }
        recentHostIDs.removeAll { removedHostIDs.contains($0) }
        groups.removeAll { $0 == groupName }
    }

    @discardableResult
    func addHost(in groupName: String) -> RemoraCore.Host {
        let host = RemoraCore.Host(
            name: uniqueHostName(base: "new-ssh"),
            address: "127.0.0.1",
            username: "root",
            group: groupName,
            tags: ["new"],
            auth: HostAuth(method: .agent)
        )
        return addHost(host)
    }

    @discardableResult
    func addHost(_ host: RemoraCore.Host) -> RemoraCore.Host {
        let normalized = normalizedHostForStorage(host, excludingID: nil)
        hosts.append(normalized)
        return normalized
    }

    @discardableResult
    func updateHost(_ host: RemoraCore.Host) -> RemoraCore.Host? {
        guard let idx = hosts.firstIndex(where: { $0.id == host.id }) else { return nil }
        let normalized = normalizedHostForStorage(host, excludingID: host.id)
        hosts[idx] = normalized
        return normalized
    }

    func deleteHost(id: UUID) {
        hosts.removeAll { $0.id == id }
        templates.removeAll { $0.hostID == id }
        recentHostIDs.removeAll { $0 == id }
    }

    @discardableResult
    func renameHost(id: UUID, to requestedName: String) -> String? {
        guard let idx = hosts.firstIndex(where: { $0.id == id }) else { return nil }
        let trimmed = requestedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let uniqueName = uniqueHostName(base: trimmed, excludingID: id)
        hosts[idx].name = uniqueName
        return uniqueName
    }

    @discardableResult
    func importHosts(_ importedHosts: [RemoraCore.Host]) -> HostImportSummary {
        guard !importedHosts.isEmpty else {
            return HostImportSummary(total: 0, created: 0, updated: 0)
        }

        suppressPersistence = true
        var created = 0
        var updated = 0

        for host in importedHosts {
            if let existingIndex = hosts.firstIndex(where: { $0.id == host.id }) {
                hosts[existingIndex] = normalizedHostForStorage(host, excludingID: host.id)
                updated += 1
            } else {
                hosts.append(normalizedHostForStorage(host, excludingID: nil))
                created += 1
            }
        }

        suppressPersistence = false
        persistSnapshotIfNeeded()
        return HostImportSummary(total: importedHosts.count, created: created, updated: updated)
    }

    func quickConnectMatch(input: String) -> RemoraCore.Host? {
        let normalized = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }

        if let exact = hosts.first(where: { $0.name.lowercased() == normalized || $0.address.lowercased() == normalized }) {
            return exact
        }

        return hosts.first(where: {
            $0.name.lowercased().contains(normalized)
                || $0.address.lowercased().contains(normalized)
                || $0.tags.contains(where: { $0.lowercased().contains(normalized) })
        })
    }

    private func loadPersistedCatalog() async {
        defer { isLoading = false }

        do {
            guard let snapshot = try await persistenceStore.load() else { return }
            apply(snapshot: snapshot)
        } catch {
            print("[HostCatalogStore] load failed: \(error.localizedDescription)")
        }
    }

    private func apply(snapshot: PersistedHostCatalog) {
        suppressPersistence = true
        defer { suppressPersistence = false }

        hosts = []
        groups = []
        let normalizedHosts = snapshot.hosts.map { normalizedHostForStorage($0, excludingID: $0.id) }
        hosts = normalizedHosts
        templates = snapshot.templates.filter { template in
            normalizedHosts.contains(where: { $0.id == template.hostID })
        }
        recentHostIDs = snapshot.recentHostIDs.filter { id in
            normalizedHosts.contains(where: { $0.id == id })
        }

        let mergedGroups = snapshot.groups + Self.orderedUniqueGroups(from: normalizedHosts)
        groups = Self.orderedUniqueStrings(from: mergedGroups)
    }

    private func persistSnapshotIfNeeded() {
        guard persistenceEnabled, !suppressPersistence else { return }
        let snapshot = PersistedHostCatalog(
            hosts: hosts,
            templates: templates,
            recentHostIDs: recentHostIDs,
            groups: groups
        )
        Task {
            do {
                try await persistenceStore.save(snapshot)
            } catch {
                print("[HostCatalogStore] save failed: \(error.localizedDescription)")
            }
        }
    }

    private func filter(_ hosts: [RemoraCore.Host], query: String) -> [RemoraCore.Host] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return hosts }

        return hosts.filter { host in
            host.name.lowercased().contains(q)
                || host.address.lowercased().contains(q)
                || host.tags.contains(where: { $0.lowercased().contains(q) })
        }
    }

    private static func orderedUniqueGroups(from hosts: [RemoraCore.Host]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []

        for host in hosts {
            let groupName = host.group.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !groupName.isEmpty else { continue }
            if !seen.contains(groupName) {
                seen.insert(groupName)
                ordered.append(groupName)
            }
        }
        return ordered
    }

    private static func orderedUniqueStrings(from values: [String]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !seen.contains(trimmed) else { continue }
            seen.insert(trimmed)
            ordered.append(trimmed)
        }
        return ordered
    }

    private static func makeDefaultCatalog() -> PersistedHostCatalog {
        if ProcessInfo.processInfo.environment["REMORA_RUN_UI_TESTS"] == "1" {
            return makeUIAutomationSeedCatalog()
        }

        return PersistedHostCatalog(
            hosts: [],
            templates: [],
            recentHostIDs: [],
            groups: []
        )
    }

    private static func makeUIAutomationSeedCatalog() -> PersistedHostCatalog {
        let production = RemoraCore.Host(
            name: "prod-api",
            address: "10.0.0.10",
            username: "deploy",
            group: "Production",
            tags: ["api", "critical"],
            favorite: true,
            auth: HostAuth(method: .privateKey, keyReference: "/Users/wuu/.ssh/id_ed25519")
        )

        let staging = RemoraCore.Host(
            name: "staging-api",
            address: "10.0.1.10",
            username: "deploy",
            group: "Staging",
            tags: ["api"],
            auth: HostAuth(method: .agent)
        )

        let jump = RemoraCore.Host(
            name: "jump-box",
            address: "127.0.0.1",
            username: NSUserName(),
            group: "Local",
            tags: ["local"],
            favorite: true,
            auth: HostAuth(method: .agent)
        )

        let initialHosts = [production, staging, jump]
        return PersistedHostCatalog(
            hosts: initialHosts,
            templates: [
                HostSessionTemplate(hostID: production.id, name: "Prod Readonly", usernameOverride: "readonly"),
                HostSessionTemplate(hostID: production.id, name: "Prod Deploy", usernameOverride: "deploy"),
                HostSessionTemplate(hostID: staging.id, name: "Staging Ops", usernameOverride: "ops"),
            ],
            recentHostIDs: [],
            groups: orderedUniqueGroups(from: initialHosts)
        )
    }

    private static var defaultPersistenceEnabled: Bool {
        let env = ProcessInfo.processInfo.environment
        if env["REMORA_DISABLE_HOST_PERSISTENCE"] == "1" { return false }
        if env["REMORA_RUN_UI_TESTS"] == "1" { return false }
        if env["XCTestConfigurationFilePath"] != nil { return false }
        return true
    }

    private func normalizedGroupName(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "New Group" : trimmed
    }

    private func uniqueGroupName(base: String) -> String {
        if !groups.contains(base) {
            return base
        }
        var idx = 2
        while groups.contains("\(base) \(idx)") {
            idx += 1
        }
        return "\(base) \(idx)"
    }

    private func ensureGroupExists(_ value: String) -> String {
        let normalized = normalizedGroupName(value)
        if groups.contains(normalized) {
            return normalized
        }
        groups.append(normalized)
        return normalized
    }

    private func uniqueHostName(base: String, excludingID: UUID? = nil) -> String {
        let existing = Set(
            hosts
                .filter { host in
                    guard let excludingID else { return true }
                    return host.id != excludingID
                }
                .map { $0.name.lowercased() }
        )
        if !existing.contains(base.lowercased()) {
            return base
        }
        var idx = 2
        while existing.contains("\(base)-\(idx)".lowercased()) {
            idx += 1
        }
        return "\(base)-\(idx)"
    }

    private func normalizedHostForStorage(_ host: RemoraCore.Host, excludingID: UUID?) -> RemoraCore.Host {
        var normalized = host
        let trimmedName = normalized.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAddress = normalized.address.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUser = normalized.username.trimmingCharacters(in: .whitespacesAndNewlines)

        let baseName = trimmedName.isEmpty ? "new-ssh" : trimmedName
        normalized.name = uniqueHostName(base: baseName, excludingID: excludingID)
        normalized.address = trimmedAddress.isEmpty ? "127.0.0.1" : trimmedAddress
        normalized.username = trimmedUser.isEmpty ? "root" : trimmedUser
        normalized.port = (1...65_535).contains(normalized.port) ? normalized.port : 22
        normalized.group = ensureGroupExists(normalized.group)

        let keyRef = normalized.auth.keyReference?.trimmingCharacters(in: .whitespacesAndNewlines)
        let passwordRef = normalized.auth.passwordReference?.trimmingCharacters(in: .whitespacesAndNewlines)

        switch normalized.auth.method {
        case .privateKey:
            if let keyRef, !keyRef.isEmpty {
                normalized.auth = HostAuth(method: .privateKey, keyReference: keyRef)
            } else {
                normalized.auth = HostAuth(method: .agent)
            }
        case .password:
            if let passwordRef, !passwordRef.isEmpty {
                normalized.auth = HostAuth(method: .password, passwordReference: passwordRef)
            } else {
                normalized.auth = HostAuth(method: .password)
            }
        case .agent:
            normalized.auth = HostAuth(method: .agent)
        }

        let existingQuickCommands = normalized.quickCommands
        normalized.quickCommands = []
        for quickCommand in existingQuickCommands {
            let commandBody = normalizeQuickCommandBody(quickCommand.command)
            guard !commandBody.isEmpty else { continue }
            let name = uniqueQuickCommandName(
                base: normalizeQuickCommandName(quickCommand.name),
                in: normalized.quickCommands,
                excludingID: nil
            )
            normalized.quickCommands.append(
                HostQuickCommand(id: quickCommand.id, name: name, command: commandBody)
            )
        }

        let existingQuickPaths = normalized.quickPaths
        normalized.quickPaths = []
        for quickPath in existingQuickPaths {
            guard let path = normalizeQuickPathValue(quickPath.path) else { continue }
            let name = uniqueQuickPathName(
                base: normalizeQuickPathName(quickPath.name),
                in: normalized.quickPaths,
                excludingID: nil
            )
            normalized.quickPaths.append(
                HostQuickPath(id: quickPath.id, name: name, path: path)
            )
        }

        return normalized
    }

    private func normalizeQuickCommandName(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Command" : trimmed
    }

    private func normalizeQuickCommandBody(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizeQuickPathName(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Path" : trimmed
    }

    private func normalizeQuickPathValue(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let prefixed = trimmed.hasPrefix("/") ? trimmed : "/\(trimmed)"
        let collapsed = prefixed.replacingOccurrences(of: "//", with: "/")
        return collapsed.isEmpty ? nil : collapsed
    }

    private func uniqueQuickCommandName(
        base: String,
        in commands: [HostQuickCommand],
        excludingID: UUID?
    ) -> String {
        let existing = Set(
            commands
                .filter { command in
                    guard let excludingID else { return true }
                    return command.id != excludingID
                }
                .map { $0.name.lowercased() }
        )
        if !existing.contains(base.lowercased()) {
            return base
        }

        var index = 2
        while existing.contains("\(base) \(index)".lowercased()) {
            index += 1
        }
        return "\(base) \(index)"
    }

    private func uniqueQuickPathName(
        base: String,
        in quickPaths: [HostQuickPath],
        excludingID: UUID?
    ) -> String {
        let existing = Set(
            quickPaths
                .filter { quickPath in
                    guard let excludingID else { return true }
                    return quickPath.id != excludingID
                }
                .map { $0.name.lowercased() }
        )
        if !existing.contains(base.lowercased()) {
            return base
        }

        var index = 2
        while existing.contains("\(base) \(index)".lowercased()) {
            index += 1
        }
        return "\(base) \(index)"
    }
}
