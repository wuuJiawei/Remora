import Foundation
import Darwin

/// Cleans up SSH processes and ControlMaster sockets created by Remora.
public enum SSHControlMasterCleanup {
    /// Kill all Remora SSH processes and clean up sockets.
    /// Safe to call from applicationWillTerminate.
    public static func killAll() {
        killSSHProcesses()
        cleanupSockets()
    }

    private static func killSSHProcesses() {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        proc.arguments = ["-f", "ControlPath=/tmp/remora-"]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try? proc.run()
        proc.waitUntilExit()
    }

    private static func cleanupSockets() {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(atPath: "/tmp") else { return }
        for name in contents where name.hasPrefix("remora-") && name.hasSuffix(".sock") {
            try? fm.removeItem(atPath: "/tmp/\(name)")
        }
    }
}
