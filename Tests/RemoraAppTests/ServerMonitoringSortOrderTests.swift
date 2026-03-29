import Foundation
import Testing
@testable import RemoraApp

struct ServerMonitoringSortOrderTests {
    @Test
    func defaultNetworkSortPrefersBusyServices() {
        let rows = [
            ServerNetworkConnectionMetric(pid: 1263, processName: "sshd", listenAddress: "0.0.0.0", port: 22, remoteAddressCount: 1, connectionCount: 2, sentBytes: 1_433, receivedBytes: 560),
            ServerNetworkConnectionMetric(pid: 1128, processName: "python3", listenAddress: "0.0.0.0", port: 8888, remoteAddressCount: 40, connectionCount: 55, sentBytes: 0, receivedBytes: 0)
        ]

        let sorted = rows.sorted(
            using: ServerMonitoringSortOrder.comparators(
                for: .connections,
                direction: .descending
            )
        )
        #expect(sorted.first?.processName == "python3")
    }

    @Test
    func defaultProcessSortPrefersHighestCpuRows() {
        let rows = [
            ServerProcessDetailsMetric(pid: 1383, user: "redis", memoryBytes: 12_533_760, cpuPercent: 0.3, command: "redis-server", location: "/www/server/redis/src/redis-server"),
            ServerProcessDetailsMetric(pid: 783_214, user: "root", memoryBytes: 99_719_168, cpuPercent: 5.0, command: "AliYunDunMonito", location: "/usr/local/aegis/aegis_client/aegis_12_91/AliYunDunMonitor")
        ]

        let sorted = rows.sorted(
            using: ServerMonitoringSortOrder.comparators(
                for: .cpu,
                direction: .descending
            )
        )
        #expect(sorted.first?.pid == 783_214)
    }

    @Test
    func ascendingNetworkSortCanPrioritizeLowerPorts() {
        let rows = [
            ServerNetworkConnectionMetric(pid: 1263, processName: "mysql", listenAddress: "0.0.0.0", port: 3306, remoteAddressCount: 1, connectionCount: 2, sentBytes: 1_433, receivedBytes: 560),
            ServerNetworkConnectionMetric(pid: 1128, processName: "sshd", listenAddress: "0.0.0.0", port: 22, remoteAddressCount: 40, connectionCount: 55, sentBytes: 0, receivedBytes: 0)
        ]

        let sorted = rows.sorted(
            using: ServerMonitoringSortOrder.comparators(
                for: .port,
                direction: .ascending
            )
        )

        #expect(sorted.first?.port == 22)
    }
}
