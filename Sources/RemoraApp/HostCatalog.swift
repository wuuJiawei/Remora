import Foundation
import RemoraCore

struct HostSessionTemplate: Identifiable, Equatable, Hashable {
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

@MainActor
final class HostCatalogStore: ObservableObject {
    @Published private(set) var hosts: [RemoraCore.Host]
    @Published private(set) var templates: [HostSessionTemplate]
    @Published private(set) var recentHostIDs: [UUID]
    @Published private(set) var groups: [String]

    init() {
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
        self.hosts = initialHosts
        self.templates = [
            HostSessionTemplate(hostID: production.id, name: "Prod Readonly", usernameOverride: "readonly"),
            HostSessionTemplate(hostID: production.id, name: "Prod Deploy", usernameOverride: "deploy"),
            HostSessionTemplate(hostID: staging.id, name: "Staging Ops", usernameOverride: "ops"),
        ]
        self.recentHostIDs = []
        self.groups = Self.orderedUniqueGroups(from: initialHosts)
    }

    func host(id: UUID?) -> RemoraCore.Host? {
        guard let id else { return nil }
        return hosts.first(where: { $0.id == id })
    }

    func templates(for hostID: UUID?) -> [HostSessionTemplate] {
        guard let hostID else { return [] }
        return templates.filter { $0.hostID == hostID }
    }

    func markConnected(hostID: UUID) {
        recentHostIDs.removeAll { $0 == hostID }
        recentHostIDs.insert(hostID, at: 0)
        if recentHostIDs.count > 10 {
            recentHostIDs.removeLast(recentHostIDs.count - 10)
        }
    }

    func favorites(matching query: String) -> [RemoraCore.Host] {
        filter(hosts.filter(\.favorite), query: query)
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

    func toggleFavorite(hostID: UUID) {
        guard let idx = hosts.firstIndex(where: { $0.id == hostID }) else { return }
        hosts[idx].favorite.toggle()
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

    func archiveHost(id: UUID) {
        guard let idx = hosts.firstIndex(where: { $0.id == id }) else { return }
        let archivedGroup = ensureGroupExists("Archived")
        hosts[idx].group = archivedGroup
        hosts[idx].favorite = false
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

        return normalized
    }
}
