import Foundation
import RemoraCore

@MainActor
final class PortForwardCenter: ObservableObject {
    @Published private(set) var activeForwards: [UUID: ActivePortForward] = [:]

    private var processes: [UUID: OpenSSHPortForwardProcess] = [:]

    func activeForward(for presetID: UUID) -> ActivePortForward? {
        activeForwards[presetID]
    }

    func isRunning(presetID: UUID) -> Bool {
        if case .running = activeForwards[presetID]?.state {
            return true
        }
        return false
    }

    func startForward(host: RemoraCore.Host, preset: HostPortForwardPreset) {
        stop(presetID: preset.id)

        let active = ActivePortForward(host: host, preset: preset, state: .starting)
        activeForwards[preset.id] = active

        let process = OpenSSHPortForwardProcess(host: host, preset: preset)
        process.onStateChange = { [weak self] (state: PortForwardState) in
            Task { @MainActor in
                guard let self else { return }
                guard var current = self.activeForwards[preset.id] else { return }
                current.state = state
                self.activeForwards[preset.id] = current
                if case .stopped = state {
                    self.processes.removeValue(forKey: preset.id)
                } else if case .failed = state {
                    self.processes.removeValue(forKey: preset.id)
                }
            }
        }
        processes[preset.id] = process

        Task {
            do {
                try await process.start()
            } catch {
                await MainActor.run {
                    if var current = self.activeForwards[preset.id] {
                        current.state = .failed(error.localizedDescription)
                        self.activeForwards[preset.id] = current
                    }
                    self.processes.removeValue(forKey: preset.id)
                }
            }
        }
    }

    func stop(presetID: UUID) {
        guard let process = processes.removeValue(forKey: presetID) else {
            if var current = activeForwards[presetID] {
                current.state = .stopped
                activeForwards[presetID] = current
            }
            return
        }
        process.stop()
        if var current = activeForwards[presetID] {
            current.state = .stopped
            activeForwards[presetID] = current
        }
    }

    func stopAll(for hostID: UUID) {
        let presetIDs = activeForwards.values
            .filter { $0.host.id == hostID }
            .map(\.preset.id)
        for presetID in presetIDs {
            stop(presetID: presetID)
        }
    }

    func stopAll(forHostIDs hostIDs: Set<UUID>) {
        for hostID in hostIDs {
            stopAll(for: hostID)
        }
    }
}
