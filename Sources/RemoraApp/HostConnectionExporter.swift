import Foundation
import RemoraCore

enum HostExportFormat: String, CaseIterable, Identifiable {
    case json
    case csv

    var id: String { rawValue }

    var fileExtension: String {
        switch self {
        case .json:
            return "json"
        case .csv:
            return "csv"
        }
    }
}

enum HostExportScope: Equatable {
    case all
    case group(String)

    var label: String {
        switch self {
        case .all:
            return tr("All Connections")
        case .group(let groupName):
            return "\(tr("Group")): \(groupName)"
        }
    }

    var filenameComponent: String {
        switch self {
        case .all:
            return "all"
        case .group(let groupName):
            return "group-\(Self.sanitizedFileComponent(groupName))"
        }
    }

    private static func sanitizedFileComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let replaced = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "-")

        let scalars = replaced.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }

        let result = String(scalars)
            .replacingOccurrences(of: "--", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))

        return result.isEmpty ? "group" : result.lowercased()
    }
}

enum HostConnectionExportError: LocalizedError {
    case downloadsDirectoryUnavailable

    var errorDescription: String? {
        switch self {
        case .downloadsDirectoryUnavailable:
            return tr("Cannot locate Downloads directory.")
        }
    }
}

struct HostConnectionExporter {
    struct Record: Codable, Equatable {
        let id: UUID
        let name: String
        let address: String
        let port: Int
        let username: String
        let group: String
        let tags: String
        let note: String
        let favorite: Bool
        let lastConnectedAt: String
        let connectCount: Int
        let authMethod: String
        let privateKeyPath: String
        let password: String
        let keepAliveSeconds: Int
        let connectTimeoutSeconds: Int
        let terminalProfileID: String
    }

    static func export(
        hosts: [RemoraCore.Host],
        scope: HostExportScope,
        format: HostExportFormat,
        credentialStore: CredentialStore = CredentialStore(),
        fileManager: FileManager = .default,
        now: Date = Date(),
        outputDirectoryOverride: URL? = nil
    ) async throws -> URL {
        let scopedHosts: [RemoraCore.Host] = {
            switch scope {
            case .all:
                return hosts
            case .group(let groupName):
                return hosts.filter { $0.group == groupName }
            }
        }()

        let records = await makeRecords(from: scopedHosts, credentialStore: credentialStore)
            .sorted { lhs, rhs in
                if lhs.group != rhs.group {
                    return lhs.group.localizedCaseInsensitiveCompare(rhs.group) == .orderedAscending
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }

        let outputDirectory: URL
        if let outputDirectoryOverride {
            outputDirectory = outputDirectoryOverride
        } else {
            outputDirectory = try downloadsDirectory(fileManager: fileManager)
        }
        let outputFile = outputDirectory.appendingPathComponent(filename(scope: scope, format: format, now: now))
        let payload = try serializedData(records: records, format: format)
        try payload.write(to: outputFile, options: .atomic)
        return outputFile
    }

    private static func makeRecords(
        from hosts: [RemoraCore.Host],
        credentialStore: CredentialStore
    ) async -> [Record] {
        var records: [Record] = []
        records.reserveCapacity(hosts.count)

        for host in hosts {
            var plaintextPassword = ""
            if let passwordReference = host.auth.passwordReference,
               !passwordReference.isEmpty
            {
                plaintextPassword = await credentialStore.secret(for: passwordReference) ?? ""
            }

            let timestamp = host.lastConnectedAt.map(iso8601String) ?? ""
            records.append(
                Record(
                    id: host.id,
                    name: host.name,
                    address: host.address,
                    port: host.port,
                    username: host.username,
                    group: host.group,
                    tags: host.tags.joined(separator: "|"),
                    note: host.note ?? "",
                    favorite: host.favorite,
                    lastConnectedAt: timestamp,
                    connectCount: host.connectCount,
                    authMethod: host.auth.method.rawValue,
                    privateKeyPath: host.auth.keyReference ?? "",
                    password: plaintextPassword,
                    keepAliveSeconds: host.policies.keepAliveSeconds,
                    connectTimeoutSeconds: host.policies.connectTimeoutSeconds,
                    terminalProfileID: host.policies.terminalProfileID
                )
            )
        }

        return records
    }

    private static func serializedData(records: [Record], format: HostExportFormat) throws -> Data {
        switch format {
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return try encoder.encode(records)
        case .csv:
            return Data(csvString(records: records).utf8)
        }
    }

    private static func csvString(records: [Record]) -> String {
        let header = [
            "id", "name", "address", "port", "username", "group",
            "tags", "note", "favorite", "lastConnectedAt", "connectCount",
            "authMethod", "privateKeyPath", "password",
            "keepAliveSeconds", "connectTimeoutSeconds", "terminalProfileID",
        ]
        var lines = [header.joined(separator: ",")]
        lines.reserveCapacity(records.count + 1)

        for record in records {
            let row = [
                record.id.uuidString,
                record.name,
                record.address,
                "\(record.port)",
                record.username,
                record.group,
                record.tags,
                record.note,
                "\(record.favorite)",
                record.lastConnectedAt,
                "\(record.connectCount)",
                record.authMethod,
                record.privateKeyPath,
                record.password,
                "\(record.keepAliveSeconds)",
                "\(record.connectTimeoutSeconds)",
                record.terminalProfileID,
            ].map(escapedCSVField)
            lines.append(row.joined(separator: ","))
        }

        return lines.joined(separator: "\n") + "\n"
    }

    private static func escapedCSVField(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r") {
            return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return value
    }

    private static func filename(scope: HostExportScope, format: HostExportFormat, now: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let timestamp = formatter.string(from: now)
        return "remora-ssh-\(scope.filenameComponent)-\(timestamp).\(format.fileExtension)"
    }

    private static func iso8601String(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func downloadsDirectory(fileManager: FileManager) throws -> URL {
        if let url = fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first {
            return url
        }
        throw HostConnectionExportError.downloadsDirectoryUnavailable
    }
}
