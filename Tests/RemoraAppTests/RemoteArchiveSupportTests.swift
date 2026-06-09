import Foundation
import Testing
@testable import RemoraApp
@testable import RemoraCore

struct RemoteArchiveSupportTests {
    @Test
    func capabilityProbeParsesAvailableTools() {
        let toolchain = RemoteArchiveCommandBuilder.parseCapabilityProbeOutput(
            """
            tar=OK
            zip=OK
            unzip=MISSING
            sevenZip=7zz
            unrar=MISSING
            gzip=OK
            """
        )

        #expect(toolchain.tarAvailable)
        #expect(toolchain.zipAvailable)
        #expect(toolchain.unzipAvailable == false)
        #expect(toolchain.sevenZipCommand == "7zz")
        #expect(toolchain.unrarAvailable == false)
        #expect(toolchain.gzipAvailable)
    }

    @Test
    func sameNameDirectoryDropsArchiveSuffix() {
        #expect(
            RemoteArchiveCommandBuilder.sameNameDirectory(
                for: "/home/app/logs.tar.gz",
                format: .tarGz
            ) == "/home/app/logs"
        )
        #expect(
            RemoteArchiveCommandBuilder.sameNameDirectory(
                for: "/backup/demo.7z",
                format: .sevenZip
            ) == "/backup/demo"
        )
    }

    @Test
    func unsafeArchiveEntriesAreRejected() throws {
        #expect(throws: ArchiveSupportError.self) {
            try RemoteArchiveCommandBuilder.validateSafeArchiveEntries([
                "logs/app.log",
                "../etc/passwd",
            ])
        }
    }

    @Test
    func compressionScriptUsesRemoteCommandsOnly() throws {
        let toolchain = RemoteArchiveToolchain(
            tarAvailable: true,
            zipAvailable: true,
            unzipAvailable: true,
            sevenZipCommand: "7z",
            unrarAvailable: true,
            gzipAvailable: true
        )

        let script = try RemoteArchiveCommandBuilder.compressionScript(
            parentDirectory: "/srv/app",
            sourceNames: ["logs", "README.md"],
            destinationPath: "/srv/app/archive.tar.gz",
            format: .tarGz,
            toolchain: toolchain
        )

        #expect(script.contains("tar -czf"))
        #expect(script.contains("-C '/srv/app'"))
        #expect(script.contains("'logs' 'README.md'"))
        #expect(!script.contains("upload"))
        #expect(!script.contains("download"))
    }

    @Test
    func mockSFTPClientExecutesRemoteArchiveRoundTrip() async throws {
        let client = MockSFTPClient()
        let toolchain = RemoteArchiveToolchain(
            tarAvailable: true,
            zipAvailable: true,
            unzipAvailable: true,
            sevenZipCommand: "7z",
            unrarAvailable: true,
            gzipAvailable: true
        )

        let compressCommand = try RemoteArchiveCommandBuilder.compressionScript(
            parentDirectory: "/",
            sourceNames: ["logs"],
            destinationPath: "/logs-backup.tar.gz",
            format: .tarGz,
            toolchain: toolchain
        )
        _ = try await client.executeRemoteShellCommand(compressCommand, timeout: 30)

        let archive = try await client.stat(path: "/logs-backup.tar.gz")
        #expect(archive.isDirectory == false)

        let listCommand = try RemoteArchiveCommandBuilder.listArchiveEntriesScript(
            archivePath: "/logs-backup.tar.gz",
            format: .tarGz,
            toolchain: toolchain
        )
        let listed = try await client.executeRemoteShellCommand(listCommand, timeout: 30)
        #expect(listed.contains("logs/app.log"))

        let extractCommand = try RemoteArchiveCommandBuilder.extractArchiveScript(
            archivePath: "/logs-backup.tar.gz",
            destinationDirectory: "/restored",
            format: .tarGz,
            toolchain: toolchain
        )
        _ = try await client.executeRemoteShellCommand(extractCommand, timeout: 30)

        let restored = try await client.stat(path: "/restored/logs/app.log")
        #expect(restored.isDirectory == false)
    }
}
