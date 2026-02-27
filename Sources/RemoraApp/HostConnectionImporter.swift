import Foundation
import RemoraCore

enum HostConnectionImportError: LocalizedError {
    case emptyFile
    case unsupportedFormat
    case invalidJSON
    case invalidCSVHeader

    var errorDescription: String? {
        switch self {
        case .emptyFile:
            return "Import file is empty."
        case .unsupportedFormat:
            return "Unsupported import format. Please select a Remora JSON/CSV export file."
        case .invalidJSON:
            return "Invalid JSON import file."
        case .invalidCSVHeader:
            return "Invalid CSV header."
        }
    }
}

enum HostConnectionImportFormat: String {
    case json
    case csv
}

struct HostConnectionImportProgress: Equatable, Sendable {
    var phase: String
    var completed: Int
    var total: Int

    var fractionCompleted: Double {
        guard total > 0 else { return 0 }
        return min(max(Double(completed) / Double(total), 0), 1)
    }
}

struct HostConnectionImporter {
    static func importConnections(
        from url: URL,
        credentialStore: CredentialStore = CredentialStore(),
        progress: (@Sendable (HostConnectionImportProgress) -> Void)? = nil
    ) async throws -> [RemoraCore.Host] {
        progress?(.init(phase: "Reading file", completed: 0, total: 1))
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { throw HostConnectionImportError.emptyFile }

        let records = try parseRecords(from: data)
        progress?(.init(phase: "Parsing records", completed: 0, total: max(records.count, 1)))

        var hosts: [RemoraCore.Host] = []
        hosts.reserveCapacity(records.count)
        var completed = 0

        for record in records {
            let host = await host(from: record, credentialStore: credentialStore)
            hosts.append(host)
            completed += 1
            progress?(.init(phase: "Importing hosts", completed: completed, total: max(records.count, 1)))
        }

        return hosts
    }

    private static func parseRecords(from data: Data) throws -> [HostConnectionExporter.Record] {
        guard let text = String(data: data, encoding: .utf8) else {
            throw HostConnectionImportError.unsupportedFormat
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw HostConnectionImportError.emptyFile
        }

        let format = try detectFormat(text: trimmed)
        switch format {
        case .json:
            let decoder = JSONDecoder()
            guard let jsonData = trimmed.data(using: .utf8) else {
                throw HostConnectionImportError.invalidJSON
            }
            do {
                return try decoder.decode([HostConnectionExporter.Record].self, from: jsonData)
            } catch {
                throw HostConnectionImportError.invalidJSON
            }
        case .csv:
            return try parseCSV(text: trimmed)
        }
    }

    private static func detectFormat(text: String) throws -> HostConnectionImportFormat {
        if text.first == "[" || text.first == "{" {
            return .json
        }

        if text.contains(",") {
            return .csv
        }

        throw HostConnectionImportError.unsupportedFormat
    }

    private static func parseCSV(text: String) throws -> [HostConnectionExporter.Record] {
        let rows = parseCSVRows(text)
        guard let headerRow = rows.first else {
            throw HostConnectionImportError.emptyFile
        }

        let headers = headerRow.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let requiredHeaders = [
            "id", "name", "address", "port", "username", "group",
            "tags", "note", "favorite", "lastConnectedAt", "connectCount",
            "authMethod", "privateKeyPath", "password",
            "keepAliveSeconds", "connectTimeoutSeconds", "terminalProfileID",
        ]
        guard Set(requiredHeaders).isSubset(of: Set(headers)) else {
            throw HostConnectionImportError.invalidCSVHeader
        }

        let headerIndexMap = Dictionary(uniqueKeysWithValues: headers.enumerated().map { ($1, $0) })
        var records: [HostConnectionExporter.Record] = []
        records.reserveCapacity(max(rows.count - 1, 0))

        for row in rows.dropFirst() {
            if row.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                continue
            }

            func field(_ key: String) -> String {
                guard let idx = headerIndexMap[key], idx < row.count else { return "" }
                return row[idx]
            }

            let id = UUID(uuidString: field("id")) ?? UUID()
            let port = Int(field("port")) ?? 22
            let favorite = parseBool(field("favorite"))
            let connectCount = Int(field("connectCount")) ?? 0
            let keepAlive = Int(field("keepAliveSeconds")) ?? 30
            let timeout = Int(field("connectTimeoutSeconds")) ?? 10

            let record = HostConnectionExporter.Record(
                id: id,
                name: field("name"),
                address: field("address"),
                port: port,
                username: field("username"),
                group: field("group"),
                tags: field("tags"),
                note: field("note"),
                favorite: favorite,
                lastConnectedAt: field("lastConnectedAt"),
                connectCount: connectCount,
                authMethod: field("authMethod"),
                privateKeyPath: field("privateKeyPath"),
                password: field("password"),
                keepAliveSeconds: keepAlive,
                connectTimeoutSeconds: timeout,
                terminalProfileID: field("terminalProfileID")
            )
            records.append(record)
        }

        return records
    }

    private static func parseCSVRows(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var isQuoted = false
        var idx = text.startIndex

        func appendField() {
            row.append(field)
            field.removeAll(keepingCapacity: true)
        }

        func appendRow() {
            if !row.isEmpty || !field.isEmpty {
                appendField()
                rows.append(row)
            }
            row.removeAll(keepingCapacity: true)
            field.removeAll(keepingCapacity: true)
        }

        while idx < text.endIndex {
            let ch = text[idx]
            let nextIndex = text.index(after: idx)

            if isQuoted {
                if ch == "\"" {
                    if nextIndex < text.endIndex && text[nextIndex] == "\"" {
                        field.append("\"")
                        idx = text.index(after: nextIndex)
                        continue
                    }
                    isQuoted = false
                    idx = nextIndex
                    continue
                }
                field.append(ch)
                idx = nextIndex
                continue
            }

            switch ch {
            case "\"":
                isQuoted = true
            case ",":
                appendField()
            case "\n":
                appendRow()
            case "\r":
                if nextIndex < text.endIndex && text[nextIndex] == "\n" {
                    idx = nextIndex
                }
                appendRow()
            default:
                field.append(ch)
            }
            idx = nextIndex
        }

        if !row.isEmpty || !field.isEmpty {
            appendField()
            rows.append(row)
        }
        return rows
    }

    private static func parseBool(_ raw: String) -> Bool {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value == "true" || value == "1" || value == "yes" || value == "y"
    }

    private static func parseDate(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = fractional.date(from: trimmed) {
            return parsed
        }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: trimmed)
    }

    private static func parseAuthMethod(_ raw: String) -> AuthenticationMethod {
        AuthenticationMethod(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines)) ?? .agent
    }

    private static func passwordReference(for hostID: UUID) -> String {
        "imported-password-\(hostID.uuidString.lowercased())"
    }

    private static func sanitizedTags(_ raw: String) -> [String] {
        raw.split(separator: "|")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func normalizedNonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func host(
        from record: HostConnectionExporter.Record,
        credentialStore: CredentialStore
    ) async -> RemoraCore.Host {
        let authMethod = parseAuthMethod(record.authMethod)
        let id = record.id

        var auth: HostAuth
        switch authMethod {
        case .password:
            let password = record.password.trimmingCharacters(in: .whitespacesAndNewlines)
            if password.isEmpty {
                auth = HostAuth(method: .password)
            } else {
                let reference = passwordReference(for: id)
                await credentialStore.setSecret(password, for: reference)
                auth = HostAuth(method: .password, passwordReference: reference)
            }
        case .privateKey:
            auth = HostAuth(method: .privateKey, keyReference: normalizedNonEmpty(record.privateKeyPath))
        case .agent:
            auth = HostAuth(method: .agent)
        }

        let policy = HostPolicies(
            keepAliveSeconds: record.keepAliveSeconds,
            connectTimeoutSeconds: record.connectTimeoutSeconds,
            terminalProfileID: normalizedNonEmpty(record.terminalProfileID) ?? "default"
        )

        return RemoraCore.Host(
            id: id,
            name: record.name,
            address: record.address,
            port: record.port,
            username: record.username,
            group: normalizedNonEmpty(record.group) ?? "Default",
            tags: sanitizedTags(record.tags),
            note: normalizedNonEmpty(record.note),
            favorite: record.favorite,
            lastConnectedAt: parseDate(record.lastConnectedAt),
            connectCount: max(0, record.connectCount),
            auth: auth,
            policies: policy
        )
    }
}
