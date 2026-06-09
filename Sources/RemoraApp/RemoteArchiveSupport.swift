import Foundation

func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

struct RemoteArchiveToolchain: Equatable, Sendable {
    var tarAvailable: Bool
    var zipAvailable: Bool
    var unzipAvailable: Bool
    var sevenZipCommand: String?
    var unrarAvailable: Bool
    var gzipAvailable: Bool
}

struct RemoteArchiveMissingToolContext: Equatable, Sendable {
    var tool: String
    var actionDescription: String
    var installCommand: String
    var installHint: String
}

enum RemoteArchiveOperationAction: Sendable {
    case compress(ArchiveFormat)
    case extract(ArchiveFormat)

    var missingToolMessageActionKey: String {
        switch self {
        case .compress(let format):
            return String(format: tr("create %@ archives"), format.fileExtension)
        case .extract(let format):
            return String(format: tr("extract %@ archives"), format.fileExtension)
        }
    }
}

enum RemoteArchiveCommandBuilder {
    private static let markerPrefix = "# remora-archive "

    static func capabilityProbeScript() -> String {
        [
            markerComment(["op": "probe"]),
            "command -v tar >/dev/null 2>&1 && echo 'tar=OK' || echo 'tar=MISSING'",
            "command -v zip >/dev/null 2>&1 && echo 'zip=OK' || echo 'zip=MISSING'",
            "command -v unzip >/dev/null 2>&1 && echo 'unzip=OK' || echo 'unzip=MISSING'",
            "command -v 7z >/dev/null 2>&1 && echo 'sevenZip=7z' || (command -v 7zz >/dev/null 2>&1 && echo 'sevenZip=7zz' || echo 'sevenZip=MISSING')",
            "command -v unrar >/dev/null 2>&1 && echo 'unrar=OK' || echo 'unrar=MISSING'",
            "command -v gzip >/dev/null 2>&1 && echo 'gzip=OK' || echo 'gzip=MISSING'",
        ].joined(separator: "\n")
    }

    static func parseCapabilityProbeOutput(_ output: String) -> RemoteArchiveToolchain {
        var values: [String: String] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            values[parts[0]] = parts[1]
        }
        return RemoteArchiveToolchain(
            tarAvailable: values["tar"] == "OK",
            zipAvailable: values["zip"] == "OK",
            unzipAvailable: values["unzip"] == "OK",
            sevenZipCommand: {
                let value = values["sevenZip"]
                return value == "MISSING" ? nil : value
            }(),
            unrarAvailable: values["unrar"] == "OK",
            gzipAvailable: values["gzip"] == "OK"
        )
    }

    static func missingToolContext(
        tool: String,
        action: RemoteArchiveOperationAction
    ) -> RemoteArchiveMissingToolContext {
        .init(
            tool: tool,
            actionDescription: action.missingToolMessageActionKey,
            installCommand: installCommand(for: tool),
            installHint: installHint(for: tool)
        )
    }

    static func ensureCompressionSupport(
        format: ArchiveFormat,
        toolchain: RemoteArchiveToolchain
    ) throws {
        guard format.supportsCompression else {
            throw ArchiveSupportError.unsupportedCompressionFormat
        }
        switch format {
        case .tar, .tarGz, .tgz:
            guard toolchain.tarAvailable else {
                throw missingToolError(tool: "tar", action: .compress(format))
            }
        case .zip:
            guard toolchain.zipAvailable else {
                throw missingToolError(tool: "zip", action: .compress(format))
            }
        case .sevenZip:
            guard toolchain.sevenZipCommand != nil else {
                throw missingToolError(tool: "7z", action: .compress(format))
            }
        case .tarBz2, .tbz2, .tarXz, .txz, .rar, .gz:
            throw ArchiveSupportError.unsupportedCompressionFormat
        }
    }

    static func ensureExtractionSupport(
        format: ArchiveFormat,
        toolchain: RemoteArchiveToolchain
    ) throws {
        switch format {
        case .tar, .tarGz, .tgz, .tarBz2, .tbz2, .tarXz, .txz:
            guard toolchain.tarAvailable else {
                throw missingToolError(tool: "tar", action: .extract(format))
            }
        case .zip:
            guard toolchain.unzipAvailable || toolchain.sevenZipCommand != nil else {
                throw missingToolError(tool: "unzip", action: .extract(format))
            }
        case .sevenZip:
            guard toolchain.sevenZipCommand != nil else {
                throw missingToolError(tool: "7z", action: .extract(format))
            }
        case .rar:
            guard toolchain.unrarAvailable || toolchain.sevenZipCommand != nil else {
                throw missingToolError(tool: "unrar", action: .extract(format))
            }
        case .gz:
            guard toolchain.gzipAvailable else {
                throw missingToolError(tool: "gzip", action: .extract(format))
            }
        }
    }

    static func compressionScript(
        parentDirectory: String,
        sourceNames: [String],
        destinationPath: String,
        format: ArchiveFormat,
        toolchain: RemoteArchiveToolchain
    ) throws -> String {
        try ensureCompressionSupport(format: format, toolchain: toolchain)
        let quotedParent = shellQuote(parentDirectory)
        let quotedDestination = shellQuote(destinationPath)
        let quotedNames = sourceNames.map(shellQuote).joined(separator: " ")
        let command: String

        switch format {
        case .tar:
            command = "tar -cf \(quotedDestination) -C \(quotedParent) \(quotedNames)"
        case .tarGz, .tgz:
            command = "tar -czf \(quotedDestination) -C \(quotedParent) \(quotedNames)"
        case .zip:
            command = "cd \(quotedParent) && zip -r \(quotedDestination) \(quotedNames)"
        case .sevenZip:
            let sevenZip = shellQuote(toolchain.sevenZipCommand ?? "7z")
            command = "cd \(quotedParent) && \(sevenZip) a \(quotedDestination) \(quotedNames)"
        case .tarBz2, .tbz2, .tarXz, .txz, .rar, .gz:
            throw ArchiveSupportError.unsupportedCompressionFormat
        }

        return [
            markerComment([
                "op": "compress",
                "format": format.rawValue,
                "parent": parentDirectory,
                "destination": destinationPath,
                "sources": sourceNames,
            ]),
            "set -e",
            command,
        ].joined(separator: "\n")
    }

    static func listArchiveEntriesScript(
        archivePath: String,
        format: ArchiveFormat,
        toolchain: RemoteArchiveToolchain
    ) throws -> String {
        try ensureExtractionSupport(format: format, toolchain: toolchain)
        let quotedArchive = shellQuote(archivePath)
        let command: String

        switch format {
        case .tar, .tarGz, .tgz, .tarBz2, .tbz2, .tarXz, .txz:
            command = "tar -tf \(quotedArchive)"
        case .zip:
            if toolchain.unzipAvailable {
                command = "unzip -Z1 \(quotedArchive)"
            } else {
                let sevenZip = shellQuote(toolchain.sevenZipCommand ?? "7z")
                command = "\(sevenZip) l -slt \(quotedArchive)"
            }
        case .sevenZip:
            let sevenZip = shellQuote(toolchain.sevenZipCommand ?? "7z")
            command = "\(sevenZip) l -slt \(quotedArchive)"
        case .rar:
            if toolchain.unrarAvailable {
                command = "unrar lb \(quotedArchive)"
            } else {
                let sevenZip = shellQuote(toolchain.sevenZipCommand ?? "7z")
                command = "\(sevenZip) l -slt \(quotedArchive)"
            }
        case .gz:
            command = "basename \(quotedArchive)"
        }

        return [
            markerComment([
                "op": "list",
                "format": format.rawValue,
                "archive": archivePath,
            ]),
            "set -e",
            command,
        ].joined(separator: "\n")
    }

    static func extractArchiveScript(
        archivePath: String,
        destinationDirectory: String,
        format: ArchiveFormat,
        toolchain: RemoteArchiveToolchain
    ) throws -> String {
        try ensureExtractionSupport(format: format, toolchain: toolchain)
        let quotedArchive = shellQuote(archivePath)
        let quotedDestination = shellQuote(destinationDirectory)
        let command: String

        switch format {
        case .tar, .tarGz, .tgz, .tarBz2, .tbz2, .tarXz, .txz:
            command = "tar -xf \(quotedArchive) -C \(quotedDestination)"
        case .zip:
            if toolchain.unzipAvailable {
                command = "unzip -o \(quotedArchive) -d \(quotedDestination)"
            } else {
                let sevenZip = shellQuote(toolchain.sevenZipCommand ?? "7z")
                command = "\(sevenZip) x \(quotedArchive) " + shellQuote("-o\(destinationDirectory)") + " -y"
            }
        case .sevenZip:
            let sevenZip = shellQuote(toolchain.sevenZipCommand ?? "7z")
            command = "\(sevenZip) x \(quotedArchive) " + shellQuote("-o\(destinationDirectory)") + " -y"
        case .rar:
            if toolchain.unrarAvailable {
                command = "unrar x -o+ \(quotedArchive) \(shellQuote(destinationDirectory + "/"))"
            } else {
                let sevenZip = shellQuote(toolchain.sevenZipCommand ?? "7z")
                command = "\(sevenZip) x \(quotedArchive) " + shellQuote("-o\(destinationDirectory)") + " -y"
            }
        case .gz:
            let outputName = strippedName(for: archivePath, format: .gz)
            let targetPath = destinationDirectory == "/"
                ? "/\(outputName)"
                : destinationDirectory + "/" + outputName
            command = "gzip -dc \(quotedArchive) > \(shellQuote(targetPath))"
        }

        return [
            markerComment([
                "op": "extract",
                "format": format.rawValue,
                "archive": archivePath,
                "destination": destinationDirectory,
            ]),
            "set -e",
            "mkdir -p \(quotedDestination)",
            command,
        ].joined(separator: "\n")
    }

    static func parseListedEntries(
        output: String,
        archivePath: String,
        format: ArchiveFormat,
        toolchain: RemoteArchiveToolchain
    ) -> [String] {
        switch format {
        case .tar, .tarGz, .tgz, .tarBz2, .tbz2, .tarXz, .txz, .zip, .rar, .gz:
            if usesSevenZipListing(format: format, toolchain: toolchain) {
                return parseSevenZipListOutput(output, archivePath: archivePath)
            }
            if format == .gz {
                return [strippedName(for: archivePath, format: .gz)]
            }
            return output
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        case .sevenZip:
            return parseSevenZipListOutput(output, archivePath: archivePath)
        }
    }

    static func validateSafeArchiveEntries(_ entries: [String]) throws {
        let hasUnsafeEntry = entries.contains { entry in
            let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return false }
            return trimmed.hasPrefix("/")
                || trimmed == ".."
                || trimmed.contains("../")
                || trimmed.contains("..\\")
                || trimmed.hasPrefix("../")
        }
        if hasUnsafeEntry {
            throw ArchiveSupportError.unsafeArchiveEntries
        }
    }

    static func parentDirectory(for normalizedPaths: [String]) throws -> String {
        let parents = Set(normalizedPaths.map { path in
            let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
            return parent.isEmpty ? "/" : parent
        })
        guard parents.count == 1, let parent = parents.first else {
            throw ArchiveSupportError.selectedItemsMustShareDirectory
        }
        return parent
    }

    static func defaultArchiveName(
        for paths: [String],
        currentDirectory: String,
        format: ArchiveFormat
    ) -> String {
        let baseName: String
        if paths.count == 1, let onlyPath = paths.first {
            baseName = URL(fileURLWithPath: onlyPath).lastPathComponent
        } else {
            let currentDirectoryName = URL(fileURLWithPath: currentDirectory).lastPathComponent
            baseName = currentDirectoryName.isEmpty ? tr("Archive") : currentDirectoryName
        }
        return ArchiveSupport.defaultArchiveName(for: baseName, format: format)
    }

    static func sameNameDirectory(for archivePath: String, format: ArchiveFormat) -> String {
        let normalizedArchivePath = archivePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let parent = URL(fileURLWithPath: normalizedArchivePath).deletingLastPathComponent().path
        let baseName = strippedName(for: normalizedArchivePath, format: format)
        if parent.isEmpty || parent == "/" {
            return "/" + baseName
        }
        return parent + "/" + baseName
    }

    private static func usesSevenZipListing(
        format: ArchiveFormat,
        toolchain: RemoteArchiveToolchain
    ) -> Bool {
        switch format {
        case .zip:
            return !toolchain.unzipAvailable && toolchain.sevenZipCommand != nil
        case .rar:
            return !toolchain.unrarAvailable && toolchain.sevenZipCommand != nil
        default:
            return false
        }
    }

    private static func parseSevenZipListOutput(_ output: String, archivePath: String) -> [String] {
        let archiveName = URL(fileURLWithPath: archivePath).lastPathComponent
        var entries: [String] = []
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("Path = ") else { continue }
            let value = String(trimmed.dropFirst("Path = ".count))
            guard !value.isEmpty else { continue }
            entries.append(value)
        }
        if entries.first == archiveName {
            entries.removeFirst()
        }
        return entries
    }

    private static func strippedName(for archivePath: String, format: ArchiveFormat) -> String {
        let lastComponent = URL(fileURLWithPath: archivePath).lastPathComponent
        let lowercased = lastComponent.lowercased()
        let suffix = format.fileExtension.lowercased()
        guard lowercased.hasSuffix(suffix) else {
            return URL(fileURLWithPath: archivePath).deletingPathExtension().lastPathComponent
        }
        return String(lastComponent.dropLast(suffix.count))
    }

    private static func missingToolError(
        tool: String,
        action: RemoteArchiveOperationAction
    ) -> ArchiveSupportError {
        .missingRemoteTool(
            missingToolContext(tool: tool, action: action)
        )
    }

    private static func installCommand(for tool: String) -> String {
        switch tool {
        case "zip", "unzip":
            return "sudo apt-get update && sudo apt-get install -y zip unzip"
        case "7z":
            return "sudo apt-get update && sudo apt-get install -y p7zip-full"
        case "unrar":
            return "sudo apt-get update && sudo apt-get install -y unrar"
        case "gzip":
            return "sudo apt-get update && sudo apt-get install -y gzip"
        default:
            return "sudo apt-get update && sudo apt-get install -y tar"
        }
    }

    private static func installHint(for tool: String) -> String {
        switch tool {
        case "zip", "unzip":
            return """
            Debian / Ubuntu: sudo apt-get update && sudo apt-get install -y zip unzip
            CentOS / RHEL / Rocky: sudo yum install -y zip unzip
            Alpine: sudo apk add zip unzip
            """
        case "7z":
            return """
            Debian / Ubuntu: sudo apt-get update && sudo apt-get install -y p7zip-full
            CentOS / RHEL / Rocky: sudo yum install -y p7zip p7zip-plugins
            Alpine: sudo apk add p7zip
            """
        case "unrar":
            return """
            Debian / Ubuntu: sudo apt-get update && sudo apt-get install -y unrar
            CentOS / RHEL / Rocky: sudo yum install -y unrar
            Alpine: sudo apk add unrar
            """
        case "gzip":
            return """
            Debian / Ubuntu: sudo apt-get update && sudo apt-get install -y gzip
            CentOS / RHEL / Rocky: sudo yum install -y gzip
            Alpine: sudo apk add gzip
            """
        default:
            return """
            Debian / Ubuntu: sudo apt-get update && sudo apt-get install -y tar
            CentOS / RHEL / Rocky: sudo yum install -y tar
            Alpine: sudo apk add tar
            """
        }
    }

    private static func markerComment(_ payload: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
        let text = String(data: data, encoding: .utf8) ?? "{}"
        return markerPrefix + text
    }
}
