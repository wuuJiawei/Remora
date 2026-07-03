import Foundation
import Darwin

private actor SSHControlMasterCleanupRegistry {
    private var paths: Set<String> = []

    func register(_ path: String) {
        paths.insert(path)
    }

    func snapshot() -> [String] {
        Array(paths)
    }

    func remove(_ path: String) {
        paths.remove(path)
    }
}

/// Cleans up SSH processes and ControlMaster sockets created by Remora.
public enum SSHControlMasterCleanup {
    private static let registry = SSHControlMasterCleanupRegistry()

    public static func registerControlPath(_ path: String) {
        Task {
            await registry.register(path)
        }
    }

    public static func removeControlPath(_ path: String) {
        Task {
            await registry.remove(path)
        }
        removeSocket(at: path)
    }

    /// Kill all Remora SSH processes and clean up sockets.
    /// Safe to call from applicationWillTerminate.
    public static func killAll() {
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            let paths = await registry.snapshot()
            killSSHProcesses(for: paths)
            cleanupSockets(for: paths)
            semaphore.signal()
        }
        semaphore.wait()
    }

    private static func killSSHProcesses(for paths: [String]) {
        for path in paths {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            proc.arguments = ["-f", "ControlPath=\(path)"]
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            try? proc.run()
            proc.waitUntilExit()
        }
    }

    private static func cleanupSockets(for paths: [String]) {
        for path in paths {
            removeSocket(at: path)
        }
    }

    private static func removeSocket(at path: String) {
        let fm = FileManager.default
        guard let attributes = try? fm.attributesOfItem(atPath: path),
              let fileType = attributes[.type] as? FileAttributeType,
              fileType == .typeSocket
        else {
            return
        }
        try? fm.removeItem(atPath: path)
    }
}
