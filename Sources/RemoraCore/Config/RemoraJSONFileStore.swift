import Foundation

public struct RemoraJSONFileStore<Value: Codable> {
    public let fileURL: URL

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let filePermissions: NSNumber?
    private let fileManager: FileManager

    public init(
        fileURL: URL,
        fileManager: FileManager = .default,
        outputFormatting: JSONEncoder.OutputFormatting = [.prettyPrinted, .sortedKeys],
        filePermissions: NSNumber? = 0o600
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        self.filePermissions = filePermissions

        let encoder = JSONEncoder()
        encoder.outputFormatting = outputFormatting
        self.encoder = encoder
        self.decoder = JSONDecoder()
    }

    public func load() throws -> Value? {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return nil
        }

        let data = try Data(contentsOf: fileURL)
        return try decoder.decode(Value.self, from: data)
    }

    public func save(_ value: Value) throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let data = try encoder.encode(value)
        try data.write(to: fileURL, options: [.atomic])

        if let filePermissions {
            try fileManager.setAttributes(
                [.posixPermissions: filePermissions],
                ofItemAtPath: fileURL.path
            )
        }
    }

    public func remove() throws {
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        try fileManager.removeItem(at: fileURL)
    }
}
