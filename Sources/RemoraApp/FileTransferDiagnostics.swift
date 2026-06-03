import Foundation

enum FileTransferDiagnostics {
    private static let queue = DispatchQueue(label: "io.lighting-tech.remora.file-transfer-diagnostics")

    static let logURL: URL = LogManager.logDirectoryURL.appendingPathComponent("file-transfer-diagnostics.log")

    static var displayPath: String {
        NSString(string: logURL.path).abbreviatingWithTildeInPath
    }

    static func append(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] \(message)\n"
        queue.async {
            let data = Data(line.utf8)
            if FileManager.default.fileExists(atPath: logURL.path),
               let handle = try? FileHandle(forWritingTo: logURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: logURL, options: .atomic)
            }
        }
    }

    static func failureMessage(for error: Error) -> String {
        "\(error.localizedDescription) — See log: \(displayPath)"
    }
}
