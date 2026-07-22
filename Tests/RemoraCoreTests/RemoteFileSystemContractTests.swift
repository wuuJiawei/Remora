import Foundation
import Testing
@testable import RemoraCore

@Suite("Remote filesystem contract")
struct RemoteFileSystemContractTests {
    @Test("Open options preserve independent protocol flags")
    func openOptionsPreserveIndependentFlags() {
        let options: RemoteFileOpenOptions = [.write, .create, .truncate]
        #expect(options.contains(.write))
        #expect(options.contains(.create))
        #expect(options.contains(.truncate))
        #expect(!options.contains(.read))
        #expect(!options.contains(.append))
    }

    @Test("Filesystem errors keep status separate from paths")
    func filesystemErrorsKeepTypedStatus() {
        let error = RemoteFileSystemOperationError(
            status: .permissionDenied,
            path: "/root/private"
        )
        #expect(error.status == .permissionDenied)
        #expect(error.path == "/root/private")
    }
}
