import Foundation
import Testing
import RemoraCore
@testable import RemoraApp

private actor ProgressEventCollector {
    private var events: [HostConnectionImportProgress] = []

    func append(_ progress: HostConnectionImportProgress) {
        events.append(progress)
    }

    func snapshot() -> [HostConnectionImportProgress] {
        events
    }
}

struct HostConnectionImporterTests {
    @Test
    func importsJSONExportAndRestoresPasswordSecret() async throws {
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("remora-import-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let credentialStore = CredentialStore()
        await credentialStore.setSecret("json-pass", for: "export-pass-1")

        let hosts = [
            Host(
                name: "prod-api",
                address: "10.10.0.5",
                port: 22,
                username: "deploy",
                group: "Production",
                auth: HostAuth(method: .password, passwordReference: "export-pass-1")
            ),
        ]

        let exportURL = try await HostConnectionExporter.export(
            hosts: hosts,
            scope: .all,
            format: .json,
            includeSavedPasswords: true,
            credentialStore: credentialStore,
            now: Date(timeIntervalSince1970: 0),
            outputDirectoryOverride: tempRoot
        )

        let collector = ProgressEventCollector()
        let imported = try await HostConnectionImporter.importConnections(
            from: exportURL,
            credentialStore: credentialStore,
            progress: { progress in
                Task {
                    await collector.append(progress)
                }
            }
        )

        #expect(imported.count == 1)
        #expect(imported.first?.name == "prod-api")
        #expect(imported.first?.auth.method == .password)
        #expect(imported.first?.auth.passwordReference != nil)
        let restoredRef = imported.first?.auth.passwordReference ?? ""
        let restoredSecret = await credentialStore.secret(for: restoredRef)
        #expect(restoredSecret == "json-pass")
        _ = await waitUntil(timeout: 1.0) {
            let events = await collector.snapshot()
            return events.contains(where: { $0.phase == "Importing hosts" })
        }
        let progressEvents = await collector.snapshot()
        #expect(progressEvents.contains(where: { $0.phase == "Importing hosts" }))
    }

    @Test
    func importsCSVExport() async throws {
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("remora-import-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let csvContent = """
        id,name,address,port,username,group,tags,note,favorite,lastConnectedAt,connectCount,authMethod,privateKeyPath,password,keepAliveSeconds,connectTimeoutSeconds,terminalProfileID
        \(UUID().uuidString),staging-api,10.20.0.12,2222,ops,Staging,api|blue,,true,,4,privateKey,/Users/wuu/.ssh/id_ed25519,,15,8,default
        \(UUID().uuidString),db-admin,10.20.0.20,22,dba,Staging,database,primary,false,,1,password,,csv-pass,30,10,default
        """
        let csvURL = tempRoot.appendingPathComponent("connections.csv")
        try csvContent.data(using: .utf8)?.write(to: csvURL)

        let credentialStore = CredentialStore()
        let imported = try await HostConnectionImporter.importConnections(
            from: csvURL,
            credentialStore: credentialStore
        )

        #expect(imported.count == 2)
        let staging = imported.first(where: { $0.name == "staging-api" })
        #expect(staging?.auth.method == .privateKey)
        #expect(staging?.auth.keyReference == "/Users/wuu/.ssh/id_ed25519")

        let db = imported.first(where: { $0.name == "db-admin" })
        #expect(db?.auth.method == .password)
        let dbPasswordRef = db?.auth.passwordReference ?? ""
        let dbPassword = await credentialStore.secret(for: dbPasswordRef)
        #expect(dbPassword == "csv-pass")
    }

    @Test
    func rejectsRemoraTXTImport() async throws {
        let tempRoot = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let txtURL = tempRoot.appendingPathComponent("connections.txt")
        let content = """
        id,name,address,port,username,group,tags,note,favorite,lastConnectedAt,connectCount,authMethod,privateKeyPath,password,keepAliveSeconds,connectTimeoutSeconds,terminalProfileID
        \(UUID().uuidString),prod,10.0.0.10,22,ops,Production,,,,,0,agent,,,30,10,default
        """
        try write(content, to: txtURL)

        await #expect(throws: HostConnectionImportError.unsupportedFormat) {
            try await HostConnectionImporter.importConnections(from: txtURL)
        }
    }

    @Test
    func importsOpenSSHConfigWithInclude() async throws {
        let tempRoot = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let sshDirectory = tempRoot.appendingPathComponent(".ssh", isDirectory: true)
        try FileManager.default.createDirectory(at: sshDirectory, withIntermediateDirectories: true)

        let extraConfig = sshDirectory.appendingPathComponent("included.conf")
        let extraContent = """
        Host stage
            HostName 10.0.0.21
            User deploy
            Port 2201
            IdentityFile ~/.ssh/stage_ed25519
        """
        try write(extraContent, to: extraConfig)

        let mainConfig = sshDirectory.appendingPathComponent("config")
        let mainContent = """
        Host prod
            HostName 10.0.0.20
            User ops
            Port 2200
            ServerAliveInterval 45
            ConnectTimeout 12
            ProxyJump bastion

        Include included.conf

        Host *
            User wildcard

        Match host prod
            User ignored
        """
        try write(mainContent, to: mainConfig)

        let imported = try await HostConnectionImporter.importConnections(
            from: mainConfig,
            source: .openSSH
        )

        #expect(imported.count == 2)

        let prod = try #require(imported.first(where: { $0.name == "prod" }))
        #expect(prod.address == "10.0.0.20")
        #expect(prod.username == "ops")
        #expect(prod.port == 2200)
        #expect(prod.policies.keepAliveSeconds == 45)
        #expect(prod.policies.connectTimeoutSeconds == 12)
        #expect(prod.note?.contains("ProxyJump: bastion") == true)

        let stage = try #require(imported.first(where: { $0.name == "stage" }))
        #expect(stage.address == "10.0.0.21")
        #expect(stage.username == "deploy")
        #expect(stage.auth.method == .privateKey)
        #expect(stage.auth.keyReference == FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/stage_ed25519").path)
    }

    @Test
    func importsWindTermSSHSessionsAndSkipsShellSessions() async throws {
        let tempRoot = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let fileURL = tempRoot.appendingPathComponent("user.sessions")
        let content = """
        [
          {
            "session.protocol" : "Shell",
            "session.label" : "zsh",
            "session.target" : "/bin/zsh"
          },
          {
            "session.protocol" : "SSH",
            "session.label" : "prod-app",
            "session.target" : "10.10.10.10",
            "session.port" : 2222,
            "session.group" : "Production",
            "session.user" : "deploy",
            "session.uuid" : "A5225D31-9E36-4A0E-A26A-82844D900001",
            "ssh.identityFilePath" : "/Users/demo/.ssh/prod.pem"
          },
          {
            "session.protocol" : "SSH",
            "session.label" : "password-box",
            "session.target" : "10.10.10.11",
            "session.autoLogin" : "encrypted-token"
          }
        ]
        """
        try write(content, to: fileURL)

        let imported = try await HostConnectionImporter.importConnections(
            from: fileURL,
            source: .windTerm
        )

        #expect(imported.count == 2)

        let prod = try #require(imported.first(where: { $0.name == "prod-app" }))
        #expect(prod.address == "10.10.10.10")
        #expect(prod.port == 2222)
        #expect(prod.username == "deploy")
        #expect(prod.group == "Production")
        #expect(prod.auth.method == .privateKey)
        #expect(prod.auth.keyReference == "/Users/demo/.ssh/prod.pem")

        let passwordBox = try #require(imported.first(where: { $0.name == "password-box" }))
        #expect(passwordBox.auth.method == .password)
    }

    @Test
    func importsElectermBookmarksAndGroups() async throws {
        let tempRoot = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let fileURL = tempRoot.appendingPathComponent("bookmarks.json")
        let content = """
        {
          "bookmarkGroups": [
            {
              "id": "default",
              "title": "default",
              "bookmarkIds": ["prod-1"],
              "bookmarkGroupIds": ["nested-1"]
            },
            {
              "id": "nested-1",
              "title": "Nested",
              "bookmarkIds": ["stage-1"],
              "bookmarkGroupIds": []
            }
          ],
          "bookmarks": [
            {
              "id": "prod-1",
              "title": "prod-db",
              "host": "192.168.0.10",
              "username": "root",
              "authType": "password",
              "password": "encrypted-like-value",
              "passwordEncrypted": true,
              "port": 22,
              "type": "ssh"
            },
            {
              "id": "stage-1",
              "title": "stage-api",
              "host": "192.168.0.20",
              "username": "deploy",
              "authType": "privateKey",
              "privateKeyPath": "/Users/demo/.ssh/stage.pem",
              "port": 2202,
              "type": "ssh",
              "quickCommands": [{ "name": "ls", "command": "ls" }]
            }
          ]
        }
        """
        try write(content, to: fileURL)

        let imported = try await HostConnectionImporter.importConnections(
            from: fileURL,
            source: .electerm
        )

        #expect(imported.count == 2)

        let prod = try #require(imported.first(where: { $0.name == "prod-db" }))
        #expect(prod.group == "default")
        #expect(prod.auth.method == .password)
        #expect(prod.auth.passwordReference == nil)

        let stage = try #require(imported.first(where: { $0.name == "stage-api" }))
        #expect(stage.group == "default / Nested")
        #expect(stage.port == 2202)
        #expect(stage.auth.method == .privateKey)
        #expect(stage.note?.contains("Quick commands were not imported.") == true)
    }

    @Test
    func importsXshellFileAndArchive() async throws {
        let tempRoot = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let xshContent = """
        [CONNECTION]
        Protocol=SSH
        Host=10.20.30.40
        Port=2200
        [CONNECTION:AUTHENTICATION]
        UserName=ops
        PublicKeyFile=/Users/demo/.ssh/id_rsa
        [SESSION]
        Description=Primary app server
        """

        let xshURL = tempRoot.appendingPathComponent("prod-app.xsh")
        try write(xshContent, to: xshURL, encoding: .utf16LittleEndian)

        let rawImported = try await HostConnectionImporter.importConnections(
            from: xshURL,
            source: .xshell
        )
        #expect(rawImported.count == 1)
        let raw = try #require(rawImported.first)
        #expect(raw.name == "prod-app")
        #expect(raw.address == "10.20.30.40")
        #expect(raw.username == "ops")
        #expect(raw.port == 2200)
        #expect(raw.auth.method == .privateKey)
        #expect(raw.note == "Primary app server")

        let archiveRoot = tempRoot.appendingPathComponent("archive", isDirectory: true)
        let archiveGroup = archiveRoot.appendingPathComponent("Production", isDirectory: true)
        try FileManager.default.createDirectory(at: archiveGroup, withIntermediateDirectories: true)
        let archivedXsh = archiveGroup.appendingPathComponent("stage-app.xsh")
        try write(xshContent.replacingOccurrences(of: "10.20.30.40", with: "10.20.30.41"), to: archivedXsh, encoding: .utf16LittleEndian)

        let xtsURL = tempRoot.appendingPathComponent("sessions.xts")
        try zipDirectory(archiveRoot, outputURL: xtsURL)

        let archiveImported = try await HostConnectionImporter.importConnections(
            from: xtsURL,
            source: .xshell
        )
        #expect(archiveImported.count == 1)
        let archived = try #require(archiveImported.first)
        #expect(archived.name == "stage-app")
        #expect(archived.group == "Production")
        #expect(archived.address == "10.20.30.41")
    }

    @Test
    func importsPuTTYRegistryExport() async throws {
        let tempRoot = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let fileURL = tempRoot.appendingPathComponent("putty.reg")
        let content = """
        Windows Registry Editor Version 5.00

        [HKEY_CURRENT_USER\\Software\\SimonTatham\\PuTTY\\Sessions\\prod%20db]
        "HostName"="10.30.0.5"
        "Protocol"="ssh"
        "PortNumber"=dword:000008ae
        "UserName"="postgres"
        "PublicKeyFile"="C:\\\\Keys\\\\prod.ppk"
        "PingIntervalSecs"=dword:0000003c
        "ProxyHost"="proxy.internal"
        "ProxyPort"=dword:000001f4

        [HKEY_CURRENT_USER\\Software\\SimonTatham\\PuTTY\\Sessions\\serial-console]
        "Protocol"="serial"
        """
        try write(content, to: fileURL, encoding: .utf16LittleEndian)

        let imported = try await HostConnectionImporter.importConnections(
            from: fileURL,
            source: .puTTYRegistry
        )

        #expect(imported.count == 1)
        let host = try #require(imported.first)
        #expect(host.name == "prod db")
        #expect(host.address == "10.30.0.5")
        #expect(host.port == 2222)
        #expect(host.username == "postgres")
        #expect(host.group == "PuTTY")
        #expect(host.auth.method == .privateKey)
        #expect(host.auth.keyReference == "C:\\Keys\\prod.ppk")
        #expect(host.policies.keepAliveSeconds == 60)
        #expect(host.note?.contains("Proxy: proxy.internal:500") == true)
    }

    private func waitUntil(timeout: TimeInterval, condition: @escaping () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() {
                return true
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return await condition()
    }

    private func makeTempRoot() -> URL {
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("remora-import-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        return tempRoot
    }

    private func write(_ content: String, to url: URL, encoding: String.Encoding = .utf8) throws {
        guard let data = content.data(using: encoding) else {
            fatalError("Unable to encode fixture")
        }
        try data.write(to: url)
    }

    private func zipDirectory(_ directoryURL: URL, outputURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-q", "-r", outputURL.path, "."]
        process.currentDirectoryURL = directoryURL

        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }
}
