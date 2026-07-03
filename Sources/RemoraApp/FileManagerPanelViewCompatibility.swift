import Foundation

enum FileManagerPanelView {
    static func parentDirectoryPath(for path: String) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "/" else { return nil }

        let normalized = trimmed.hasSuffix("/")
            ? String(trimmed.dropLast())
            : trimmed
        guard !normalized.isEmpty, normalized != "/" else { return nil }

        let url = URL(fileURLWithPath: normalized, isDirectory: true)
        let parent = url.deletingLastPathComponent().path
        return parent == normalized || parent.isEmpty ? nil : parent
    }
}
