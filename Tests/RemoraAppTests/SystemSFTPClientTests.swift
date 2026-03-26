import Foundation
import Testing
@testable import RemoraCore

struct SystemSFTPClientTests {
    @Test
    func sshListFallbackAcceptsEmptyDirectoryResults() {
        #expect(SystemSFTPClient.shouldAcceptSSHListFallbackResult([]))

        let entries = [
            RemoteFileEntry(name: "README.txt", path: "/README.txt", size: 12, isDirectory: false),
        ]
        #expect(SystemSFTPClient.shouldAcceptSSHListFallbackResult(entries))
    }
}
