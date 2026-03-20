import Foundation

public enum RemoraConfigFile: String, Sendable {
    case credentials = "credentials.json"
    case connections = "connections.json"
    case settings = "settings.json"
    case keyboardShortcuts = "keyboard-shortcuts.json"
}

public enum RemoraConfigPaths {
    public static func rootDirectoryURL(
        fileManager: FileManager = .default,
        homeDirectoryURL: URL? = nil
    ) -> URL {
        let home = homeDirectoryURL ?? fileManager.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".config/remora", isDirectory: true)
    }

    public static func fileURL(
        for file: RemoraConfigFile,
        fileManager: FileManager = .default,
        homeDirectoryURL: URL? = nil
    ) -> URL {
        rootDirectoryURL(fileManager: fileManager, homeDirectoryURL: homeDirectoryURL)
            .appendingPathComponent(file.rawValue, isDirectory: false)
    }
}
