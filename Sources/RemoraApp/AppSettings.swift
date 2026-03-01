import Foundation

enum AppSettings {
    static let downloadDirectoryPathKey = "settings.fileManager.downloadDirectoryPath"

    static func resolvedDownloadDirectoryURL(
        from rawPath: String?,
        fileManager: FileManager = .default
    ) -> URL {
        if let rawPath {
            let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                let candidate = URL(fileURLWithPath: trimmed, isDirectory: true).standardizedFileURL
                if isWritableDirectory(candidate, fileManager: fileManager) {
                    return candidate
                }
            }
        }
        return defaultDownloadDirectoryURL(fileManager: fileManager)
    }

    static func defaultDownloadDirectoryURL(fileManager: FileManager = .default) -> URL {
        if let downloads = fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first {
            if !fileManager.fileExists(atPath: downloads.path) {
                try? fileManager.createDirectory(at: downloads, withIntermediateDirectories: true)
            }
            if isWritableDirectory(downloads, fileManager: fileManager) {
                return downloads
            }
        }

        let current = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
            .standardizedFileURL
        if isWritableDirectory(current, fileManager: fileManager) {
            return current
        }

        let home = fileManager.homeDirectoryForCurrentUser
        if isWritableDirectory(home, fileManager: fileManager) {
            return home
        }

        return fileManager.homeDirectoryForCurrentUser
    }

    static func isWritableDirectory(_ url: URL, fileManager: FileManager = .default) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return false
        }
        return fileManager.isWritableFile(atPath: url.path)
    }
}

extension Notification.Name {
    static let remoraDownloadDirectoryDidChange = Notification.Name("remora.downloadDirectoryDidChange")
    static let remoraOpenDownloadDirectorySetting = Notification.Name("remora.openDownloadDirectorySetting")
}
