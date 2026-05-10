import Foundation

public struct ExtensionScriptStore: Sendable {
    private let fileURL: URL

    public init(fileURL: URL = RemoraConfigPaths.fileURL(for: .extensionScripts)) {
        self.fileURL = fileURL
    }

    public func load() throws -> [ExtensionScript] {
        try jsonStore.load()?.scripts ?? []
    }

    public func save(_ scripts: [ExtensionScript]) throws {
        let sorted = scripts.sorted { lhs, rhs in
            lhs.updatedAt > rhs.updatedAt
        }
        try jsonStore.save(ExtensionScriptCollection(scripts: sorted))
    }

    private var jsonStore: RemoraJSONFileStore<ExtensionScriptCollection> {
        RemoraJSONFileStore<ExtensionScriptCollection>(fileURL: fileURL)
    }
}
