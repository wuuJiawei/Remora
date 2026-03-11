import Foundation
import RemoraCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

enum HostConnectionImportError: LocalizedError {
    case emptyFile
    case unsupportedFormat
    case invalidJSON
    case invalidCSVHeader
    case invalidOpenSSHConfig
    case invalidWindTermJSON
    case invalidElectermJSON
    case invalidXshellFile
    case invalidPuTTYRegistryExport
    case noImportableHosts

    var errorDescription: String? {
        switch self {
        case .emptyFile:
            return tr("Import file is empty.")
        case .unsupportedFormat:
            return tr("Unsupported import format for the selected source.")
        case .invalidJSON:
            return tr("Invalid JSON import file.")
        case .invalidCSVHeader:
            return tr("Invalid CSV header.")
        case .invalidOpenSSHConfig:
            return tr("Invalid OpenSSH config file.")
        case .invalidWindTermJSON:
            return tr("Invalid WindTerm session file.")
        case .invalidElectermJSON:
            return tr("Invalid electerm bookmark export.")
        case .invalidXshellFile:
            return tr("Invalid Xshell session file.")
        case .invalidPuTTYRegistryExport:
            return tr("Invalid PuTTY registry export.")
        case .noImportableHosts:
            return tr("No importable SSH hosts were found in the selected file.")
        }
    }
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

private struct HostConnectionImportRecord {
    var id = UUID()
    var name: String
    var address: String
    var port: Int = 22
    var username: String
    var group: String
    var tags: [String] = []
    var note: String?
    var favorite = false
    var lastConnectedAt: Date?
    var connectCount = 0
    var authMethod: AuthenticationMethod = .agent
    var privateKeyPath: String?
    var password: String?
    var keepAliveSeconds = 30
    var connectTimeoutSeconds = 10
    var terminalProfileID = "default"
}

struct HostConnectionImporter {
    static func importConnections(
        from url: URL,
        credentialStore: CredentialStore = CredentialStore(),
        progress: (@Sendable (HostConnectionImportProgress) -> Void)? = nil
    ) async throws -> [RemoraCore.Host] {
        try await importConnections(
            from: url,
            source: .remoraJSONCSV,
            credentialStore: credentialStore,
            progress: progress
        )
    }

    static func importConnections(
        from url: URL,
        source: HostConnectionImportSource,
        credentialStore: CredentialStore = CredentialStore(),
        progress: (@Sendable (HostConnectionImportProgress) -> Void)? = nil
    ) async throws -> [RemoraCore.Host] {
        progress?(.init(phase: tr("Reading file"), completed: 0, total: 1))
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { throw HostConnectionImportError.emptyFile }

        let records = try parseRecords(from: data, url: url, source: source, progress: progress)
        guard !records.isEmpty else {
            throw HostConnectionImportError.noImportableHosts
        }

        progress?(.init(phase: tr("Parsing records"), completed: 0, total: max(records.count, 1)))

        var hosts: [RemoraCore.Host] = []
        hosts.reserveCapacity(records.count)

        for (index, record) in records.enumerated() {
            let host = await host(from: record, credentialStore: credentialStore)
            hosts.append(host)
            progress?(.init(phase: tr("Importing hosts"), completed: index + 1, total: max(records.count, 1)))
        }

        return hosts
    }

    private static func parseRecords(
        from data: Data,
        url: URL,
        source: HostConnectionImportSource,
        progress: (@Sendable (HostConnectionImportProgress) -> Void)?
    ) throws -> [HostConnectionImportRecord] {
        switch source {
        case .remoraJSONCSV:
            return try parseRemoraRecords(from: data, url: url)
        case .openSSH:
            progress?(.init(phase: tr("Resolving config files"), completed: 0, total: 1))
            return try parseOpenSSHRecords(from: url)
        case .windTerm:
            return try parseWindTermRecords(from: data)
        case .electerm:
            return try parseElectermRecords(from: data)
        case .xshell:
            progress?(.init(phase: tr("Extracting sessions"), completed: 0, total: 1))
            return try parseXshellRecords(from: data, url: url)
        case .puTTYRegistry:
            return try parsePuTTYRegistryRecords(from: data)
        case .shellSessions, .finalShell, .termius:
            throw HostConnectionImportError.unsupportedFormat
        }
    }

    private static func parseRemoraRecords(from data: Data, url: URL) throws -> [HostConnectionImportRecord] {
        let pathExtension = url.pathExtension.lowercased()
        guard pathExtension == "json" || pathExtension == "csv" else {
            throw HostConnectionImportError.unsupportedFormat
        }

        guard let text = decodeText(data, encodings: [.utf8]) else {
            throw HostConnectionImportError.unsupportedFormat
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw HostConnectionImportError.emptyFile
        }

        if trimmed.first == "[" || trimmed.first == "{" {
            let decoder = JSONDecoder()
            guard let jsonData = trimmed.data(using: .utf8) else {
                throw HostConnectionImportError.invalidJSON
            }

            do {
                let exported = try decoder.decode([HostConnectionExporter.Record].self, from: jsonData)
                return exported.map(remoraRecordToImportRecord)
            } catch {
                throw HostConnectionImportError.invalidJSON
            }
        }

        if trimmed.contains(",") {
            return try parseRemoraCSV(text: trimmed)
        }

        throw HostConnectionImportError.unsupportedFormat
    }

    private static func remoraRecordToImportRecord(_ record: HostConnectionExporter.Record) -> HostConnectionImportRecord {
        HostConnectionImportRecord(
            id: record.id,
            name: record.name,
            address: record.address,
            port: record.port,
            username: record.username,
            group: record.group,
            tags: sanitizedTags(record.tags),
            note: normalizedNonEmpty(record.note),
            favorite: record.favorite,
            lastConnectedAt: parseDate(record.lastConnectedAt),
            connectCount: max(0, record.connectCount),
            authMethod: parseAuthMethod(record.authMethod),
            privateKeyPath: normalizedNonEmpty(record.privateKeyPath),
            password: normalizedNonEmpty(record.password),
            keepAliveSeconds: record.keepAliveSeconds,
            connectTimeoutSeconds: record.connectTimeoutSeconds,
            terminalProfileID: normalizedNonEmpty(record.terminalProfileID) ?? "default"
        )
    }

    private static func parseRemoraCSV(text: String) throws -> [HostConnectionImportRecord] {
        let rows = parseCSVRows(text)
        guard let headerRow = rows.first else {
            throw HostConnectionImportError.emptyFile
        }

        let headers = headerRow.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
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
        var records: [HostConnectionImportRecord] = []

        for row in rows.dropFirst() {
            if row.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                continue
            }

            func field(_ key: String) -> String {
                guard let idx = headerIndexMap[key], idx < row.count else { return "" }
                return row[idx]
            }

            records.append(
                HostConnectionImportRecord(
                    id: UUID(uuidString: field("id")) ?? UUID(),
                    name: field("name"),
                    address: field("address"),
                    port: Int(field("port")) ?? 22,
                    username: field("username"),
                    group: field("group"),
                    tags: sanitizedTags(field("tags")),
                    note: normalizedNonEmpty(field("note")),
                    favorite: parseBool(field("favorite")),
                    lastConnectedAt: parseDate(field("lastConnectedAt")),
                    connectCount: max(0, Int(field("connectCount")) ?? 0),
                    authMethod: parseAuthMethod(field("authMethod")),
                    privateKeyPath: normalizedNonEmpty(field("privateKeyPath")),
                    password: normalizedNonEmpty(field("password")),
                    keepAliveSeconds: Int(field("keepAliveSeconds")) ?? 30,
                    connectTimeoutSeconds: Int(field("connectTimeoutSeconds")) ?? 10,
                    terminalProfileID: normalizedNonEmpty(field("terminalProfileID")) ?? "default"
                )
            )
        }

        return records
    }

    private static func parseOpenSSHRecords(from url: URL) throws -> [HostConnectionImportRecord] {
        var parser = OpenSSHConfigParser()
        try parser.parseFile(at: url)
        return parser.importRecords()
    }

    private static func parseWindTermRecords(from data: Data) throws -> [HostConnectionImportRecord] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw HostConnectionImportError.invalidWindTermJSON
        }

        let sessions = root.compactMap { dictionary -> HostConnectionImportRecord? in
            let protocolName = stringValue(dictionary["session.protocol"])?.lowercased()
            guard protocolName == "ssh" else { return nil }

            let label = normalizedNonEmpty(stringValue(dictionary["session.label"]))
            let target = normalizedNonEmpty(stringValue(dictionary["session.target"]))
            guard let address = target else { return nil }

            let privateKeyPath = normalizedNonEmpty(
                stringValue(dictionary["ssh.identityFilePath"])
                    ?? stringValue(dictionary["session.identityFilePath"])
            )
            let hasEncryptedAutoLogin = normalizedNonEmpty(stringValue(dictionary["session.autoLogin"])) != nil

            let authMethod: AuthenticationMethod = {
                if privateKeyPath != nil {
                    return .privateKey
                }
                if hasEncryptedAutoLogin {
                    return .password
                }
                return .agent
            }()

            return HostConnectionImportRecord(
                id: UUID(uuidString: stringValue(dictionary["session.uuid"]) ?? "") ?? UUID(),
                name: label ?? address,
                address: address,
                port: intValue(dictionary["session.port"]) ?? 22,
                username: normalizedNonEmpty(
                    stringValue(dictionary["session.user"])
                        ?? stringValue(dictionary["session.username"])
                        ?? stringValue(dictionary["ssh.user"])
                ) ?? "",
                group: normalizedNonEmpty(stringValue(dictionary["session.group"])) ?? "WindTerm",
                authMethod: authMethod,
                privateKeyPath: privateKeyPath
            )
        }

        return sessions
    }

    private static func parseElectermRecords(from data: Data) throws -> [HostConnectionImportRecord] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let bookmarks = root["bookmarks"] as? [[String: Any]],
              let bookmarkGroups = root["bookmarkGroups"] as? [[String: Any]] else {
            throw HostConnectionImportError.invalidElectermJSON
        }

        let bookmarkGroupMap = Dictionary(
            uniqueKeysWithValues: bookmarkGroups.compactMap { group -> (String, [String: Any])? in
                guard let id = normalizedNonEmpty(stringValue(group["id"]) ?? stringValue(group["_id"])) else {
                    return nil
                }
                return (id, group)
            }
        )
        let referencedGroupIDs = Set(
            bookmarkGroups.flatMap { group in
                stringArray(group["bookmarkGroupIds"])
            }
        )
        let rootGroups = bookmarkGroups.filter { group in
            guard let id = normalizedNonEmpty(stringValue(group["id"]) ?? stringValue(group["_id"])) else {
                return false
            }
            return !referencedGroupIDs.contains(id)
        }

        var bookmarkGroupLookup: [String: String] = [:]

        func visitGroup(_ group: [String: Any], parentPath: String?) {
            let rawTitle = normalizedNonEmpty(stringValue(group["title"])) ?? "electerm"
            let path = [parentPath, rawTitle].compactMap { $0 }.joined(separator: " / ")

            for bookmarkID in stringArray(group["bookmarkIds"]) where bookmarkGroupLookup[bookmarkID] == nil {
                bookmarkGroupLookup[bookmarkID] = path
            }

            for childID in stringArray(group["bookmarkGroupIds"]) {
                guard let child = bookmarkGroupMap[childID] else { continue }
                visitGroup(child, parentPath: path)
            }
        }

        for group in rootGroups {
            visitGroup(group, parentPath: nil)
        }
        if bookmarkGroupLookup.isEmpty {
            for group in bookmarkGroups {
                visitGroup(group, parentPath: nil)
            }
        }

        return bookmarks.compactMap { bookmark in
            let type = normalizedNonEmpty(stringValue(bookmark["type"]))?.lowercased() ?? "ssh"
            guard type == "ssh" else { return nil }

            let address = normalizedNonEmpty(stringValue(bookmark["host"]))
            guard let address else { return nil }

            let authType = normalizedNonEmpty(stringValue(bookmark["authType"]))?.lowercased() ?? ""
            let usesAgent = parseBoolValue(bookmark["useSshAgent"])
            let keyPath = normalizedNonEmpty(
                stringValue(bookmark["privateKeyPath"])
                    ?? stringValue(bookmark["publicKeyFile"])
                    ?? pathLikeStringValue(bookmark["privateKey"])
            )
            let passwordEncrypted = parseBoolValue(bookmark["passwordEncrypted"])
            let plaintextPassword = passwordEncrypted ? nil : normalizedNonEmpty(stringValue(bookmark["password"]))

            let authMethod: AuthenticationMethod = {
                if let keyPath, !keyPath.isEmpty {
                    return .privateKey
                }
                if authType == "password" {
                    return .password
                }
                if usesAgent {
                    return .agent
                }
                return .agent
            }()

            let bookmarkID = normalizedNonEmpty(stringValue(bookmark["id"]) ?? stringValue(bookmark["_id"]))
            let note = makeJoinedNote([
                connectionHoppingNote(bookmark["connectionHoppings"]),
                quickCommandsNote(bookmark["quickCommands"]),
            ])

            return HostConnectionImportRecord(
                id: UUID(),
                name: normalizedNonEmpty(stringValue(bookmark["title"])) ?? address,
                address: address,
                port: intValue(bookmark["port"]) ?? 22,
                username: normalizedNonEmpty(stringValue(bookmark["username"])) ?? "",
                group: (bookmarkID.flatMap { bookmarkGroupLookup[$0] }) ?? "electerm",
                note: note,
                authMethod: authMethod,
                privateKeyPath: keyPath,
                password: plaintextPassword
            )
        }
    }

    private static func parseXshellRecords(from data: Data, url: URL) throws -> [HostConnectionImportRecord] {
        let ext = url.pathExtension.lowercased()
        if ext == "xsh" {
            return try [parseXshellSession(data: data, fallbackName: url.deletingPathExtension().lastPathComponent, group: nil)]
        }

        if ext == "xts" || ext == "zip" {
            let entries = try unzipListEntries(archiveURL: url).filter { $0.lowercased().hasSuffix(".xsh") }
            guard !entries.isEmpty else {
                throw HostConnectionImportError.invalidXshellFile
            }

            return try entries.compactMap { entry in
                let entryData = try unzipEntryData(archiveURL: url, entry: entry)
                let entryPath = entry as NSString
                let directoryPath = entryPath.deletingLastPathComponent
                let components = directoryPath
                    .split(separator: "/")
                    .map(String.init)
                    .filter { !$0.isEmpty && $0 != "." }
                let group = components.isEmpty ? nil : components.joined(separator: " / ")
                return try? parseXshellSession(
                    data: entryData,
                    fallbackName: (entryPath.deletingPathExtension as NSString).lastPathComponent,
                    group: group
                )
            }
        }

        throw HostConnectionImportError.invalidXshellFile
    }

    private static func parseXshellSession(
        data: Data,
        fallbackName: String,
        group: String?
    ) throws -> HostConnectionImportRecord {
        guard let text = decodeText(data, encodings: [.utf16LittleEndian, .utf16, .utf8]) else {
            throw HostConnectionImportError.invalidXshellFile
        }

        let values = parseINIValues(text)
        let protocolName = normalizedNonEmpty(values["protocol"])?.lowercased() ?? "ssh"
        guard protocolName == "ssh" else {
            throw HostConnectionImportError.invalidXshellFile
        }

        let address = normalizedNonEmpty(values["host"])
        guard let address else {
            throw HostConnectionImportError.invalidXshellFile
        }

        let description = normalizedNonEmpty(values["description"])
        let publicKeyFile = normalizedNonEmpty(values["publickeyfile"])
        let hasPasswordMaterial = normalizedNonEmpty(values["password"]) != nil || normalizedNonEmpty(values["passwordv2"]) != nil
        let authMethod: AuthenticationMethod = {
            if publicKeyFile != nil {
                return .privateKey
            }
            if hasPasswordMaterial {
                return .password
            }
            return .agent
        }()

        return HostConnectionImportRecord(
            name: fallbackName,
            address: address,
            port: Int(values["port"] ?? "") ?? 22,
            username: normalizedNonEmpty(values["username"]) ?? "",
            group: normalizedNonEmpty(group) ?? "Xshell",
            note: description,
            authMethod: authMethod,
            privateKeyPath: publicKeyFile
        )
    }

    private static func parsePuTTYRegistryRecords(from data: Data) throws -> [HostConnectionImportRecord] {
        guard let text = decodeText(data, encodings: [.utf16LittleEndian, .utf16, .utf8]) else {
            throw HostConnectionImportError.invalidPuTTYRegistryExport
        }

        let sessionPrefix = #"HKEY_CURRENT_USER\Software\SimonTatham\PuTTY\Sessions\"#
        var currentSessionName: String?
        var currentValues: [String: String] = [:]
        var records: [HostConnectionImportRecord] = []

        func flushCurrentSession() {
            defer {
                currentValues = [:]
                currentSessionName = nil
            }

            guard let currentSessionName else { return }
            let protocolName = normalizedNonEmpty(currentValues["Protocol"])?.lowercased() ?? "ssh"
            guard protocolName == "ssh" else { return }

            guard let address = normalizedNonEmpty(currentValues["HostName"]) else { return }
            let keyPath = normalizedNonEmpty(currentValues["PublicKeyFile"])
            let authMethod: AuthenticationMethod = keyPath == nil ? .agent : .privateKey

            let proxyPort = parseRegistryInteger(currentValues["ProxyPort"])

            records.append(
                HostConnectionImportRecord(
                    name: currentSessionName.removingPercentEncoding ?? currentSessionName,
                    address: address,
                    port: parseRegistryInteger(currentValues["PortNumber"]) ?? 22,
                    username: normalizedNonEmpty(currentValues["UserName"]) ?? "",
                    group: "PuTTY",
                    note: makeJoinedNote([
                        proxyNote(host: currentValues["ProxyHost"], port: proxyPort),
                        normalizedNonEmpty(currentValues["RemoteCommand"]).map { "RemoteCommand: \($0)" },
                    ]),
                    authMethod: authMethod,
                    privateKeyPath: keyPath,
                    keepAliveSeconds: parseRegistryInteger(currentValues["PingIntervalSecs"]) ?? 30
                )
            )
        }

        for rawLine in text.components(separatedBy: CharacterSet.newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if line.hasPrefix(";") { continue }

            if line.hasPrefix("[") && line.hasSuffix("]") {
                flushCurrentSession()
                let section = String(line.dropFirst().dropLast())
                if section.hasPrefix(sessionPrefix) {
                    currentSessionName = String(section.dropFirst(sessionPrefix.count))
                }
                continue
            }

            guard currentSessionName != nil,
                  line.hasPrefix("\""),
                  let separator = line.range(of: "=") else {
                continue
            }

            let keyRange = line.index(after: line.startIndex)..<separator.lowerBound
            let key = String(line[keyRange]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let value = String(line[separator.upperBound...])
            currentValues[key] = parseRegistryValue(value)
        }

        flushCurrentSession()
        return records
    }

    private static func parseCSVRows(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var isQuoted = false
        var index = text.startIndex

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

        while index < text.endIndex {
            let character = text[index]
            let nextIndex = text.index(after: index)

            if isQuoted {
                if character == "\"" {
                    if nextIndex < text.endIndex && text[nextIndex] == "\"" {
                        field.append("\"")
                        index = text.index(after: nextIndex)
                        continue
                    }
                    isQuoted = false
                    index = nextIndex
                    continue
                }

                field.append(character)
                index = nextIndex
                continue
            }

            switch character {
            case "\"":
                isQuoted = true
            case ",":
                appendField()
            case "\n":
                appendRow()
            case "\r":
                if nextIndex < text.endIndex && text[nextIndex] == "\n" {
                    index = nextIndex
                }
                appendRow()
            default:
                field.append(character)
            }

            index = nextIndex
        }

        if !row.isEmpty || !field.isEmpty {
            appendField()
            rows.append(row)
        }

        return rows
    }

    private static func parseINIValues(_ text: String) -> [String: String] {
        var values: [String: String] = [:]

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if line.hasPrefix(";") || line.hasPrefix("#") || line.hasPrefix("[") {
                continue
            }
            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if values[key] == nil {
                values[key] = value
            }
        }

        return values
    }

    private static func unzipListEntries(archiveURL: URL) throws -> [String] {
        let result = try runProcess(executablePath: "/usr/bin/unzip", arguments: ["-Z1", archiveURL.path])
        guard result.status == 0 else {
            throw HostConnectionImportError.invalidXshellFile
        }
        guard let listing = String(data: result.stdout, encoding: .utf8) else {
            throw HostConnectionImportError.invalidXshellFile
        }
        return listing
            .components(separatedBy: CharacterSet.newlines)
            .filter { !$0.isEmpty }
    }

    private static func unzipEntryData(archiveURL: URL, entry: String) throws -> Data {
        let result = try runProcess(executablePath: "/usr/bin/unzip", arguments: ["-p", archiveURL.path, entry])
        guard result.status == 0 else {
            throw HostConnectionImportError.invalidXshellFile
        }
        return result.stdout
    }

    private static func runProcess(executablePath: String, arguments: [String]) throws -> (status: Int32, stdout: Data, stderr: Data) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        return (
            status: process.terminationStatus,
            stdout: stdoutPipe.fileHandleForReading.readDataToEndOfFile(),
            stderr: stderrPipe.fileHandleForReading.readDataToEndOfFile()
        )
    }

    fileprivate static func decodeText(_ data: Data, encodings: [String.Encoding]) -> String? {
        for encoding in encodings {
            if let text = String(data: data, encoding: encoding) {
                return text
            }
        }
        return nil
    }

    private static func parseRegistryValue(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.hasPrefix("\""), trimmed.hasSuffix("\"") {
            let inner = String(trimmed.dropFirst().dropLast())
            return inner
                .replacingOccurrences(of: "\\\\", with: "\\")
                .replacingOccurrences(of: "\\\"", with: "\"")
        }

        return trimmed
    }

    private static func parseRegistryInteger(_ raw: String?) -> Int? {
        guard let raw = normalizedNonEmpty(raw) else { return nil }

        if raw.lowercased().hasPrefix("dword:") {
            return Int(raw.dropFirst("dword:".count), radix: 16)
        }

        return Int(raw)
    }

    private static func parseBool(_ raw: String) -> Bool {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value == "true" || value == "1" || value == "yes" || value == "y"
    }

    private static func parseBoolValue(_ value: Any?) -> Bool {
        switch value {
        case let number as NSNumber:
            return number.boolValue
        case let string as String:
            return parseBool(string)
        default:
            return false
        }
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

    fileprivate static func normalizedNonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func stringValue(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            return string
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }

    private static func intValue(_ value: Any?) -> Int? {
        switch value {
        case let number as NSNumber:
            return number.intValue
        case let string as String:
            return Int(string)
        default:
            return nil
        }
    }

    private static func stringArray(_ value: Any?) -> [String] {
        guard let array = value as? [Any] else { return [] }
        return array.compactMap { normalizedNonEmpty(stringValue($0)) }
    }

    private static func pathLikeStringValue(_ value: Any?) -> String? {
        guard let string = normalizedNonEmpty(stringValue(value)) else { return nil }
        if string.hasPrefix("/") || string.hasPrefix("~") {
            return string
        }
        return nil
    }

    fileprivate static func makeJoinedNote(_ parts: [String?]) -> String? {
        let filtered = parts.compactMap(normalizedNonEmpty)
        guard !filtered.isEmpty else { return nil }
        return filtered.joined(separator: "\n")
    }

    private static func connectionHoppingNote(_ value: Any?) -> String? {
        guard let array = value as? [Any], !array.isEmpty else { return nil }
        return tr("Connection hopping settings were not imported.")
    }

    private static func quickCommandsNote(_ value: Any?) -> String? {
        guard let array = value as? [Any], !array.isEmpty else { return nil }
        return tr("Quick commands were not imported.")
    }

    private static func proxyNote(host: String?, port: Int?) -> String? {
        guard let host = normalizedNonEmpty(host) else { return nil }
        if let port {
            return "Proxy: \(host):\(port)"
        }
        return "Proxy: \(host)"
    }

    private static func host(
        from record: HostConnectionImportRecord,
        credentialStore: CredentialStore
    ) async -> RemoraCore.Host {
        let id = record.id

        let auth: HostAuth
        switch record.authMethod {
        case .password:
            if let password = normalizedNonEmpty(record.password) {
                let reference = passwordReference(for: id)
                await credentialStore.setSecret(password, for: reference)
                auth = HostAuth(method: .password, passwordReference: reference)
            } else {
                auth = HostAuth(method: .password)
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
            tags: record.tags,
            note: normalizedNonEmpty(record.note),
            favorite: record.favorite,
            lastConnectedAt: record.lastConnectedAt,
            connectCount: max(0, record.connectCount),
            auth: auth,
            policies: policy
        )
    }
}

private struct OpenSSHConfigParser {
    struct HostDraft {
        var alias: String
        var hostName: String?
        var user: String?
        var port: Int?
        var identityFile: String?
        var proxyJump: String?
        var keepAliveSeconds: Int?
        var connectTimeoutSeconds: Int?

        func withAlias(_ alias: String) -> Self {
            var copy = self
            copy.alias = alias
            return copy
        }
    }

    private var visitedPaths: Set<String> = []
    private var globalDefaults = HostDraft(alias: "__global__")
    private var currentAliases: [String]?
    private var hosts: [String: HostDraft] = [:]

    mutating func parseFile(at url: URL) throws {
        let normalizedURL = url.resolvingSymlinksInPath().standardizedFileURL
        let normalizedPath = normalizedURL.path
        guard visitedPaths.insert(normalizedPath).inserted else { return }

        let data = try Data(contentsOf: normalizedURL)
        guard !data.isEmpty else { return }
        guard let text = HostConnectionImporter.decodeText(data, encodings: [.utf8, .utf16, .utf16LittleEndian]) else {
            throw HostConnectionImportError.invalidOpenSSHConfig
        }

        for rawLine in text.components(separatedBy: CharacterSet.newlines) {
            let tokens = tokenize(rawLine)
            guard let directive = tokens.first?.lowercased() else { continue }

            switch directive {
            case "host":
                currentAliases = tokens.dropFirst().compactMap { token in
                    let trimmed = token.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return nil }
                    guard !trimmed.hasPrefix("!"), !trimmed.contains("*"), !trimmed.contains("?") else {
                        return nil
                    }
                    return trimmed
                }
                for alias in currentAliases ?? [] where hosts[alias] == nil {
                    hosts[alias] = globalDefaults.withAlias(alias)
                }
            case "match":
                currentAliases = []
            case "include":
                let baseDirectory = normalizedURL.deletingLastPathComponent()
                let includes = tokens.dropFirst().flatMap { resolveIncludePaths(pattern: $0, baseDirectory: baseDirectory) }
                for includeURL in includes {
                    try parseFile(at: includeURL)
                }
            case "hostname":
                applyString(tokens, keyPath: \.hostName)
            case "user":
                applyString(tokens, keyPath: \.user)
            case "port":
                applyInt(tokens, keyPath: \.port)
            case "identityfile":
                applyExpandedPath(tokens, baseDirectory: normalizedURL.deletingLastPathComponent(), keyPath: \.identityFile)
            case "proxyjump":
                applyString(tokens, keyPath: \.proxyJump)
            case "serveraliveinterval":
                applyInt(tokens, keyPath: \.keepAliveSeconds)
            case "connecttimeout":
                applyInt(tokens, keyPath: \.connectTimeoutSeconds)
            default:
                continue
            }
        }
    }

    func importRecords() -> [HostConnectionImportRecord] {
        hosts.keys.sorted().compactMap { alias -> HostConnectionImportRecord? in
            guard let host = hosts[alias] else { return nil }
            let address = host.hostName ?? alias
            return HostConnectionImportRecord(
                name: alias,
                address: address,
                port: host.port ?? 22,
                username: host.user ?? "",
                group: "OpenSSH",
                note: HostConnectionImporter.makeJoinedNote([
                    HostConnectionImporter.normalizedNonEmpty(host.proxyJump).map { "ProxyJump: \($0)" },
                ]),
                authMethod: host.identityFile == nil ? .agent : .privateKey,
                privateKeyPath: host.identityFile,
                keepAliveSeconds: host.keepAliveSeconds ?? 30,
                connectTimeoutSeconds: host.connectTimeoutSeconds ?? 10
            )
        }
    }

    private mutating func applyString(_ tokens: [String], keyPath: WritableKeyPath<HostDraft, String?>) {
        guard let value = HostConnectionImporter.normalizedNonEmpty(tokens.dropFirst().joined(separator: " ")) else { return }
        mutateCurrentHosts { draft in
            if draft[keyPath: keyPath] == nil {
                draft[keyPath: keyPath] = value
            }
        }
    }

    private mutating func applyInt(_ tokens: [String], keyPath: WritableKeyPath<HostDraft, Int?>) {
        guard let value = Int(tokens.dropFirst().joined(separator: " ")) else { return }
        mutateCurrentHosts { draft in
            if draft[keyPath: keyPath] == nil {
                draft[keyPath: keyPath] = value
            }
        }
    }

    private mutating func applyExpandedPath(
        _ tokens: [String],
        baseDirectory: URL,
        keyPath: WritableKeyPath<HostDraft, String?>
    ) {
        guard let raw = HostConnectionImporter.normalizedNonEmpty(tokens.dropFirst().joined(separator: " ")) else { return }
        let resolved = resolvePath(raw, baseDirectory: baseDirectory)
        mutateCurrentHosts { draft in
            if draft[keyPath: keyPath] == nil {
                draft[keyPath: keyPath] = resolved
            }
        }
    }

    private mutating func mutateCurrentHosts(_ update: (inout HostDraft) -> Void) {
        if let currentAliases {
            guard !currentAliases.isEmpty else { return }
            for alias in currentAliases {
                var draft = hosts[alias] ?? globalDefaults.withAlias(alias)
                update(&draft)
                hosts[alias] = draft
            }
            return
        }

        update(&globalDefaults)
    }

    private func resolveIncludePaths(pattern: String, baseDirectory: URL) -> [URL] {
        let resolvedPattern = resolvePath(pattern, baseDirectory: baseDirectory)
        return expandGlob(pattern: resolvedPattern)
    }

    private func resolvePath(_ raw: String, baseDirectory: URL) -> String {
        let expandedTilde = NSString(string: raw).expandingTildeInPath
        if expandedTilde.hasPrefix("/") {
            return expandedTilde
        }
        return baseDirectory.appendingPathComponent(expandedTilde).path
    }

    private func expandGlob(pattern: String) -> [URL] {
        var result = glob_t()
        let flags = Int32(GLOB_TILDE)
        let status = pattern.withCString { glob($0, flags, nil, &result) }
        defer { globfree(&result) }
        guard status == 0 else { return [] }

        let count = Int(result.gl_matchc)
        return (0..<count).compactMap { index in
            guard let pathPointer = result.gl_pathv[index] else { return nil }
            return URL(fileURLWithPath: String(cString: pathPointer))
        }
    }

    private func tokenize(_ rawLine: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var isQuoted = false
        var escaping = false

        func pushCurrent() {
            guard !current.isEmpty else { return }
            tokens.append(current)
            current.removeAll(keepingCapacity: true)
        }

        for character in rawLine {
            if escaping {
                current.append(character)
                escaping = false
                continue
            }

            if character == "\\" && isQuoted {
                escaping = true
                continue
            }

            if character == "\"" {
                isQuoted.toggle()
                continue
            }

            if character == "#" && !isQuoted {
                break
            }

            if (character == " " || character == "\t" || character == "=") && !isQuoted {
                pushCurrent()
                continue
            }

            current.append(character)
        }

        pushCurrent()
        return tokens
    }
}
