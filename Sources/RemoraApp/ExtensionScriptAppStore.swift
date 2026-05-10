import Foundation
import RemoraCore

@MainActor
final class ExtensionScriptAppStore: ObservableObject {
    static let shared = ExtensionScriptAppStore()

    @Published private(set) var scripts: [ExtensionScript] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var isLoading = false

    private let store: ExtensionScriptStore

    init(store: ExtensionScriptStore = ExtensionScriptStore()) {
        self.store = store
        Task { await load() }
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }

        do {
            let store = self.store
            let loaded = try await Task.detached {
                try store.load()
            }.value
            scripts = loaded
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func scripts(for hostID: UUID?) -> [ExtensionScript] {
        let hostIDString = hostID?.uuidString
        return scripts
            .filter { $0.isEnabled && $0.scope.applies(to: hostIDString) }
            .sorted { lhs, rhs in lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending }
    }

    func upsert(_ script: ExtensionScript) {
        var normalized = script
        normalized.name = normalized.name.trimmingCharacters(in: .whitespacesAndNewlines)
        normalized.body = normalized.body.trimmingCharacters(in: .whitespacesAndNewlines)
        normalized.timeoutSeconds = ExtensionScript.clampedTimeoutSeconds(normalized.timeoutSeconds)
        normalized.updatedAt = Date()

        if let index = scripts.firstIndex(where: { $0.id == normalized.id }) {
            normalized.createdAt = scripts[index].createdAt
            scripts[index] = normalized
        } else {
            let now = Date()
            normalized.createdAt = now
            normalized.updatedAt = now
            scripts.append(normalized)
        }
        persist()
    }

    func duplicate(_ script: ExtensionScript) {
        var copy = script
        let now = Date()
        copy = ExtensionScript(
            id: UUID(),
            name: String(format: tr("%@ Copy"), script.name),
            language: script.language,
            body: script.body,
            scope: script.scope,
            timeoutSeconds: script.timeoutSeconds,
            requireConfirmation: script.requireConfirmation,
            createdAt: now,
            updatedAt: now,
            isEnabled: script.isEnabled
        )
        scripts.append(copy)
        persist()
    }

    func delete(id: UUID) {
        scripts.removeAll { $0.id == id }
        persist()
    }

    func setEnabled(_ enabled: Bool, id: UUID) {
        guard let index = scripts.firstIndex(where: { $0.id == id }) else { return }
        scripts[index].isEnabled = enabled
        scripts[index].updatedAt = Date()
        persist()
    }

    private func persist() {
        let snapshot = scripts
        let store = self.store
        Task {
            do {
                try await Task.detached {
                    try store.save(snapshot)
                }.value
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
