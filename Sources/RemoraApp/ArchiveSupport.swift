import Foundation

enum ArchiveFormat: String, CaseIterable, Equatable, Sendable {
    case zip
    case tar
    case tarGz = "tar.gz"
    case tgz
    case gz

    var fileExtension: String {
        switch self {
        case .zip: return ".zip"
        case .tar: return ".tar"
        case .tarGz: return ".tar.gz"
        case .tgz: return ".tgz"
        case .gz: return ".gz"
        }
    }

    var supportsCompression: Bool {
        switch self {
        case .zip, .tar, .tarGz, .tgz: return true
        case .gz: return false
        }
    }

    static func extractFormat(for fileName: String) -> ArchiveFormat? {
        let lowercased = fileName.lowercased()
        if lowercased.hasSuffix(".tar.gz") { return .tarGz }
        if lowercased.hasSuffix(".tgz") { return .tgz }
        if lowercased.hasSuffix(".tar") { return .tar }
        if lowercased.hasSuffix(".zip") { return .zip }
        if lowercased.hasSuffix(".gz") { return .gz }
        return nil
    }
}

enum ArchiveSupportError: LocalizedError, Equatable {
    case unsupportedCompressionFormat
    case unsupportedExtractionFormat
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedCompressionFormat:
            return tr("This archive format is not supported for compression yet.")
        case .unsupportedExtractionFormat:
            return tr("This archive format is not supported for extraction yet.")
        case .commandFailed(let message):
            return message
        }
    }
}

enum ArchiveSupport {
    static func createArchive(from stagingDirectoryURL: URL, destinationURL: URL, format: ArchiveFormat) throws {
        switch format {
        case .zip:
            try runLocalTool(
                executable: "/usr/bin/zip",
                arguments: ["-qry", destinationURL.path, "."],
                currentDirectoryURL: stagingDirectoryURL
            )
        case .tar:
            try runLocalTool(
                executable: "/usr/bin/tar",
                arguments: ["-cf", destinationURL.path, "-C", stagingDirectoryURL.path, "."]
            )
        case .tarGz, .tgz:
            try runLocalTool(
                executable: "/usr/bin/tar",
                arguments: ["-czf", destinationURL.path, "-C", stagingDirectoryURL.path, "."]
            )
        case .gz:
            throw ArchiveSupportError.unsupportedCompressionFormat
        }
    }

    static func extractArchive(at archiveURL: URL, to destinationDirectoryURL: URL) throws {
        guard let format = ArchiveFormat.extractFormat(for: archiveURL.lastPathComponent) else {
            throw ArchiveSupportError.unsupportedExtractionFormat
        }

        try FileManager.default.createDirectory(at: destinationDirectoryURL, withIntermediateDirectories: true)

        switch format {
        case .zip:
            try runLocalTool(
                executable: "/usr/bin/ditto",
                arguments: ["-x", "-k", archiveURL.path, destinationDirectoryURL.path]
            )
        case .tar, .tarGz, .tgz:
            try runLocalTool(
                executable: "/usr/bin/tar",
                arguments: ["-xf", archiveURL.path, "-C", destinationDirectoryURL.path]
            )
        case .gz:
            let outputName = archiveURL.deletingPathExtension().lastPathComponent
            let outputURL = destinationDirectoryURL.appendingPathComponent(outputName)
            try gunzipFile(at: archiveURL, outputURL: outputURL)
        }
    }

    static func defaultArchiveName(for selectionName: String, format: ArchiveFormat) -> String {
        selectionName + format.fileExtension
    }

    private static func gunzipFile(at archiveURL: URL, outputURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-dc", archiveURL.path]

        let pipe = Pipe()
        process.standardOutput = pipe
        let errorPipe = Pipe()
        process.standardError = errorPipe

        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let errorOutput = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw ArchiveSupportError.commandFailed(errorOutput.isEmpty ? "gzip failed" : errorOutput)
        }

        try data.write(to: outputURL)
    }

    @discardableResult
    private static func runLocalTool(
        executable: String,
        arguments: [String],
        currentDirectoryURL: URL? = nil
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectoryURL

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let errorOutput = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            let message = errorOutput.isEmpty ? output : errorOutput
            throw ArchiveSupportError.commandFailed(message.isEmpty ? "Archive tool failed" : message)
        }

        return output
    }
}
