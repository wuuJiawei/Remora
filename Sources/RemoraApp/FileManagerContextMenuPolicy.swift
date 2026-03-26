enum FileManagerContextMenuPolicy {
    static func isDownloadDisabled(isDirectory: Bool) -> Bool {
        false
    }

    static func downloadablePaths(for selectedPaths: Set<String>) -> [String] {
        selectedPaths.sorted()
    }

    static func isBatchDownloadDisabled(selectedPaths: Set<String>) -> Bool {
        selectedPaths.isEmpty
    }
}
