import Foundation
import OSLog

enum LogLevel: String {
    case debug = "DEBUG"
    case info = "INFO"
    case error = "ERROR"
}

enum LogCategory: String {
    case app = "APP"
    case docker = "Docker"
    case fileManager = "FileManager"
    case editor = "Editor"
    case ssh = "SSH"
}

enum LogManager {
    private static let subsystem = "io.lighting-tech.remora"
    private static let backend = LogFileBackend()

    static var logDirectoryURL: URL {
        LogFileBackend.logDirectoryURL
    }

    static var activeLogURL: URL {
        LogFileBackend.activeLogURL
    }

    static var displayLogDirectoryPath: String {
        NSString(string: logDirectoryURL.path).abbreviatingWithTildeInPath
    }

    static var displayActiveLogPath: String {
        NSString(string: activeLogURL.path).abbreviatingWithTildeInPath
    }

    static func bootstrap() {
        Task {
            await backend.bootstrapIfNeeded()
        }
        info(.app, "log bootstrap requested path=\(displayActiveLogPath)")
    }

    static func debug(_ category: LogCategory, _ message: @autoclosure () -> String) {
        log(.debug, category, message())
    }

    static func info(_ category: LogCategory, _ message: @autoclosure () -> String) {
        log(.info, category, message())
    }

    static func error(_ category: LogCategory, _ message: @autoclosure () -> String) {
        log(.error, category, message())
    }

    private static func log(_ level: LogLevel, _ category: LogCategory, _ message: String) {
        let sanitized = message.replacingOccurrences(of: "\n", with: "\\n")
        writeToUnifiedLog(level: level, category: category, message: sanitized)
        Task {
            await backend.append(level: level, category: category, message: sanitized)
        }
    }

    private static func writeToUnifiedLog(level: LogLevel, category: LogCategory, message: String) {
        let logger = Logger(subsystem: subsystem, category: category.rawValue)
        switch level {
        case .debug:
            logger.debug("\(message, privacy: .public)")
        case .info:
            logger.info("\(message, privacy: .public)")
        case .error:
            logger.error("\(message, privacy: .public)")
        }
    }
}

actor LogFileBackend {
    static let logDirectoryURL: URL = {
        let fileManager = FileManager.default
        let baseDirectory = fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("Remora", isDirectory: true)
            ?? fileManager.temporaryDirectory.appendingPathComponent("Remora", isDirectory: true)
        try? fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        return baseDirectory
    }()

    static let activeLogURL: URL = logDirectoryURL.appendingPathComponent("app.log")

    private let maxFileSizeBytes = 10 * 1024 * 1024
    private let maxLogFiles = 7
    private let maxLogAge: TimeInterval = 14 * 24 * 60 * 60
    private let fileManager = FileManager.default
    private let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    private var didBootstrap = false

    func bootstrapIfNeeded() {
        guard !didBootstrap else { return }
        didBootstrap = true
        try? fileManager.createDirectory(at: Self.logDirectoryURL, withIntermediateDirectories: true)
        cleanupExpiredLogs()
        rotateIfNeeded()
    }

    func append(level: LogLevel, category: LogCategory, message: String) {
        bootstrapIfNeeded()
        rotateIfNeeded()
        let line = "\(timestampFormatter.string(from: Date())) [\(level.rawValue)] [\(category.rawValue)] \(message)\n"
        let data = Data(line.utf8)
        if fileManager.fileExists(atPath: Self.activeLogURL.path),
           let handle = try? FileHandle(forWritingTo: Self.activeLogURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: Self.activeLogURL, options: .atomic)
        }
    }

    private func rotateIfNeeded() {
        let currentSize = (try? fileManager.attributesOfItem(atPath: Self.activeLogURL.path)[.size] as? NSNumber)?.intValue ?? 0
        guard currentSize >= maxFileSizeBytes else { return }

        let oldestURL = rotatedLogURL(index: maxLogFiles - 1)
        try? fileManager.removeItem(at: oldestURL)

        for index in stride(from: maxLogFiles - 2, through: 1, by: -1) {
            let sourceURL = rotatedLogURL(index: index)
            let destinationURL = rotatedLogURL(index: index + 1)
            if fileManager.fileExists(atPath: sourceURL.path) {
                try? fileManager.removeItem(at: destinationURL)
                try? fileManager.moveItem(at: sourceURL, to: destinationURL)
            }
        }

        if fileManager.fileExists(atPath: Self.activeLogURL.path) {
            let rotatedURL = rotatedLogURL(index: 1)
            try? fileManager.removeItem(at: rotatedURL)
            try? fileManager.moveItem(at: Self.activeLogURL, to: rotatedURL)
        }
    }

    private func cleanupExpiredLogs() {
        guard let logFiles = try? fileManager.contentsOfDirectory(
            at: Self.logDirectoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let expirationDate = Date().addingTimeInterval(-maxLogAge)
        for url in logFiles where url.lastPathComponent.hasPrefix("app") && url.pathExtension == "log" {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            if let modifiedAt = values?.contentModificationDate, modifiedAt < expirationDate {
                try? fileManager.removeItem(at: url)
            }
        }
    }

    private func rotatedLogURL(index: Int) -> URL {
        Self.logDirectoryURL.appendingPathComponent("app.\(index).log")
    }
}
