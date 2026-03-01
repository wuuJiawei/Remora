import Foundation
import Testing
@testable import RemoraApp

struct AppSettingsTests {
    @Test
    func resolvedDownloadDirectoryUsesProvidedWritableDirectory() throws {
        let tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("remora-app-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let resolved = AppSettings.resolvedDownloadDirectoryURL(from: tempDirectory.path)
        func normalizePath(_ path: String) -> String {
            let standardized = NSString(string: path).standardizingPath
            if standardized.hasSuffix("/") && standardized.count > 1 {
                return String(standardized.dropLast())
            }
            return standardized
        }
        let resolvedPath = normalizePath(resolved.path)
        let expectedPath = normalizePath(tempDirectory.path)
        #expect(resolvedPath == expectedPath)
    }

    @Test
    func resolvedDownloadDirectoryFallsBackWhenPathInvalid() {
        let invalidPath = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("remora-app-settings-missing-\(UUID().uuidString)")
            .path

        let resolved = AppSettings.resolvedDownloadDirectoryURL(from: invalidPath)
        #expect(resolved.path != invalidPath)
        #expect(AppSettings.isWritableDirectory(resolved))
    }
}
