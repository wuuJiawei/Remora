import Foundation
import Testing
@testable import RemoraCore

struct RemoteCommandPrivilegeTests {
    @Test
    func wrapsCompoundShellCommandForNonInteractiveSudo() {
        let command = #"printf '%s' "hello" && touch /tmp/remora"#

        let wrapped = RemoteCommandPrivilege.sudoNonInteractive.wrappingShellCommand(command)

        #expect(wrapped == #"sudo -n -- /bin/sh -c 'printf '\''%s'\'' "hello" && touch /tmp/remora'"#)
    }

    @Test
    func leavesCurrentUserCommandUnchanged() {
        let command = "pwd && whoami"

        #expect(RemoteCommandPrivilege.currentUser.wrappingShellCommand(command) == command)
    }

    @Test
    func hostPrivilegeRoundTripsAndLegacyPayloadDefaultsToCurrentUser() throws {
        let host = Host(
            name: "sudo-host",
            address: "10.0.0.2",
            username: "ubuntu",
            auth: HostAuth(method: .agent),
            remoteCommandPrivilege: .sudoNonInteractive
        )
        let encoded = try JSONEncoder().encode(host)
        let decoded = try JSONDecoder().decode(Host.self, from: encoded)
        #expect(decoded.remoteCommandPrivilege == .sudoNonInteractive)

        var legacyObject = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacyObject.removeValue(forKey: "remoteCommandPrivilege")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        let legacyHost = try JSONDecoder().decode(Host.self, from: legacyData)
        #expect(legacyHost.remoteCommandPrivilege == .currentUser)
    }
}
