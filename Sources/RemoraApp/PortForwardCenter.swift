import Foundation
import RemoraCore

@MainActor
final class PortForwardCenter: ObservableObject {
    typealias LeaseAcquirer = @MainActor @Sendable () async throws -> any RemoteSessionLeaseProtocol

    @Published private(set) var activeForwards: [UUID: ActivePortForward] = [:]

    private var forwards: [UUID: NativeLocalPortForward] = [:]
    private var startupTasks: [UUID: Task<Void, Never>] = [:]
    private var shutdownTasks: [UUID: Task<Void, Never>] = [:]
    private var generations: [UUID: UUID] = [:]

    func activeForward(for presetID: UUID) -> ActivePortForward? {
        activeForwards[presetID]
    }

    func isRunning(presetID: UUID) -> Bool {
        switch activeForwards[presetID]?.state {
        case .running, .starting:
            return true
        default:
            return false
        }
    }

    func startForward(
        host: RemoraCore.Host,
        preset: HostPortForwardPreset,
        acquireLease: @escaping LeaseAcquirer
    ) {
        stop(presetID: preset.id)
        let previousShutdown = shutdownTasks.removeValue(forKey: preset.id)

        let generation = UUID()
        generations[preset.id] = generation
        activeForwards[preset.id] = ActivePortForward(
            host: host,
            preset: preset,
            state: .starting
        )
        LogManager.info(
            .ssh,
            "port forward start requested preset=\(preset.id.uuidString) host=\(host.id.uuidString) localPort=\(preset.localPort) remotePort=\(preset.remotePort)"
        )

        startupTasks[preset.id] = Task { [weak self] in
            var pendingLease: (any RemoteSessionLeaseProtocol)?
            do {
                await previousShutdown?.value
                try Task.checkCancellation()
                let lease = try await acquireLease()
                pendingLease = lease
                try Task.checkCancellation()

                let forward = NativeLocalPortForward(
                    lease: lease,
                    preset: preset,
                    stateHandler: { [weak self] state in
                        Task { @MainActor in
                            self?.receive(
                                state: state,
                                presetID: preset.id,
                                generation: generation
                            )
                        }
                    },
                    diagnosticHandler: { message in
                        LogManager.debug(.ssh, "port forward \(message)")
                    }
                )
                guard let self,
                      self.generations[preset.id] == generation,
                      !Task.isCancelled
                else {
                    await lease.release()
                    return
                }

                self.forwards[preset.id] = forward
                pendingLease = nil
                try await forward.start()
                self.startupTasks.removeValue(forKey: preset.id)
            } catch is CancellationError {
                await pendingLease?.release()
            } catch {
                await pendingLease?.release()
                guard let self, self.generations[preset.id] == generation else { return }
                self.receive(
                    state: .failed(error.localizedDescription),
                    presetID: preset.id,
                    generation: generation
                )
                self.startupTasks.removeValue(forKey: preset.id)
            }
        }
    }

    func recordUnavailable(host: RemoraCore.Host, preset: HostPortForwardPreset, reason: String) {
        stop(presetID: preset.id)
        activeForwards[preset.id] = ActivePortForward(
            host: host,
            preset: preset,
            state: .failed(reason)
        )
        LogManager.error(
            .ssh,
            "port forward rejected preset=\(preset.id.uuidString) host=\(host.id.uuidString) reason=noMatchingNativeSession"
        )
    }

    func stop(presetID: UUID) {
        generations.removeValue(forKey: presetID)
        startupTasks.removeValue(forKey: presetID)?.cancel()
        let forward = forwards.removeValue(forKey: presetID)

        if var current = activeForwards[presetID] {
            current.state = .stopped
            activeForwards[presetID] = current
        }
        guard let forward else { return }
        LogManager.info(.ssh, "port forward stop requested preset=\(presetID.uuidString)")
        shutdownTasks[presetID] = Task {
            await forward.stop()
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

    private func receive(state: PortForwardState, presetID: UUID, generation: UUID) {
        guard generations[presetID] == generation,
              var current = activeForwards[presetID]
        else { return }

        current.state = state
        activeForwards[presetID] = current
        switch state {
        case .running:
            LogManager.info(.ssh, "port forward running preset=\(presetID.uuidString)")
        case .failed(let reason):
            startupTasks.removeValue(forKey: presetID)
            forwards.removeValue(forKey: presetID)
            LogManager.error(
                .ssh,
                "port forward failed preset=\(presetID.uuidString) detail=\(String(reason.prefix(512)))"
            )
        case .stopped:
            startupTasks.removeValue(forKey: presetID)
            forwards.removeValue(forKey: presetID)
        case .idle, .starting:
            break
        }
    }
}
