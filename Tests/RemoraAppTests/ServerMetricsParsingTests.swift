import Foundation
import Testing
@testable import RemoraApp

struct ServerMetricsParsingTests {
    @Test
    func parseSnapshotParsesExpectedFractionsAndDetails() {
        let output = """
        cpu_permille=425
        mem_total_kb=8192000
        mem_used_kb=2048000
        disk_total_kb=1024000
        disk_used_kb=256000
        load1=0.58
        uptime_s=3661
        proc_count=212
        net_rx_bytes=1048576
        net_tx_bytes=524288
        disk_read_bytes=8192
        disk_write_bytes=4096
        """

        let sampledAt = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = RemoteServerMetricsProbe.parseSnapshot(from: output, sampledAt: sampledAt)
        #expect(snapshot != nil)
        guard let snapshot else { return }

        #expect(abs((snapshot.cpuFraction ?? -1) - 0.425) < 0.0001)
        #expect(abs((snapshot.memoryFraction ?? -1) - 0.25) < 0.0001)
        #expect(abs((snapshot.diskFraction ?? -1) - 0.25) < 0.0001)
        #expect(snapshot.memoryTotalBytes == 8_388_608_000)
        #expect(snapshot.memoryUsedBytes == 2_097_152_000)
        #expect(snapshot.diskTotalBytes == 1_048_576_000)
        #expect(snapshot.diskUsedBytes == 262_144_000)
        #expect(snapshot.loadAverage1 == 0.58)
        #expect(snapshot.uptimeSeconds == 3_661)
        #expect(snapshot.processCount == 212)
        #expect(snapshot.networkRXBytes == 1_048_576)
        #expect(snapshot.networkTXBytes == 524_288)
        #expect(snapshot.diskReadBytes == 8_192)
        #expect(snapshot.diskWriteBytes == 4_096)
        #expect(snapshot.sampledAt == sampledAt)
    }

    @Test
    func parseSnapshotReturnsNilWhenAllMetricsUnavailable() {
        let output = """
        cpu_permille=-1
        mem_total_kb=-1
        mem_used_kb=-1
        disk_total_kb=-1
        disk_used_kb=-1
        load1=-1
        uptime_s=-1
        proc_count=-1
        net_rx_bytes=-1
        net_tx_bytes=-1
        disk_read_bytes=-1
        disk_write_bytes=-1
        """

        let snapshot = RemoteServerMetricsProbe.parseSnapshot(from: output)
        #expect(snapshot == nil)
    }

    @Test
    func parseSnapshotClampsFractionsToValidRange() {
        let output = """
        cpu_permille=1200
        mem_total_kb=100
        mem_used_kb=180
        disk_total_kb=200
        disk_used_kb=300
        load1=1.25
        uptime_s=120
        proc_count=12
        net_rx_bytes=1024
        net_tx_bytes=2048
        disk_read_bytes=4096
        disk_write_bytes=8192
        """

        let snapshot = RemoteServerMetricsProbe.parseSnapshot(from: output)
        #expect(snapshot != nil)
        guard let snapshot else { return }

        #expect(snapshot.cpuFraction == 1)
        #expect(snapshot.memoryFraction == 1)
        #expect(snapshot.diskFraction == 1)
    }

    @Test
    func parseSnapshotParsesExtendedSections() {
        let output = """
        cpu_permille=425
        mem_total_kb=8192000
        mem_used_kb=2048000
        swap_total_kb=4096000
        swap_used_kb=512000
        disk_total_kb=1024000
        disk_used_kb=256000
        load1=0.58
        load5=0.42
        load15=0.27
        uptime_s=3661
        proc_count=212
        net_rx_bytes=1048576
        net_tx_bytes=524288
        disk_read_bytes=8192
        disk_write_bytes=4096
        proc_0=1843200|3.3|java
        proc_1=116736|1.7|mysqld
        fs_0=/|44040192|24444928
        fs_1=/dev/shm|1992294|1992294
        """

        let snapshot = RemoteServerMetricsProbe.parseSnapshot(from: output)
        #expect(snapshot != nil)
        guard let snapshot else { return }

        #expect(abs((snapshot.swapFraction ?? -1) - 0.125) < 0.0001)
        #expect(snapshot.swapUsedBytes == 524_288_000)
        #expect(snapshot.swapTotalBytes == 4_194_304_000)
        #expect(snapshot.loadAverage5 == 0.42)
        #expect(snapshot.loadAverage15 == 0.27)
        #expect(snapshot.topProcesses.count == 2)
        #expect(snapshot.topProcesses.first?.command == "java")
        #expect(snapshot.topProcesses.first?.memoryBytes == 1_887_436_800)
        #expect(abs((snapshot.topProcesses.first?.cpuPercent ?? -1) - 3.3) < 0.0001)
        #expect(snapshot.filesystems.count == 2)
        #expect(snapshot.filesystems.first?.mountPath == "/")
        #expect(snapshot.filesystems.first?.availableBytes == 45_097_156_608)
        #expect(snapshot.filesystems.first?.totalBytes == 25_031_606_272)
    }

    @Test
    func parseSnapshotParsesNetworkAndProcessMonitoringRows() {
        let output = """
        cpu_permille=425
        mem_total_kb=8192000
        mem_used_kb=2048000
        disk_total_kb=1024000
        disk_used_kb=256000
        net_0=1263|sshd|0.0.0.0|22|1|2|1433|560
        net_1=1128|python3|0.0.0.0|8888|40|55|0|0
        ps_0=783214|root|97382|5.0|AliYunDunMonito|/usr/local/aegis/aegis_client/aegis_12_91/AliYunDunMonitor
        ps_1=1383|redis|12240|0.3|redis-server|/www/server/redis/src/redis-server
        """

        let snapshot = RemoteServerMetricsProbe.parseSnapshot(from: output)
        #expect(snapshot != nil)
        guard let snapshot else { return }

        #expect(snapshot.networkConnections.count == 2)
        #expect(snapshot.networkConnections.first?.pid == 1263)
        #expect(snapshot.networkConnections.first?.processName == "sshd")
        #expect(snapshot.networkConnections.first?.listenAddress == "0.0.0.0")
        #expect(snapshot.networkConnections.first?.port == 22)
        #expect(snapshot.networkConnections.first?.remoteAddressCount == 1)
        #expect(snapshot.networkConnections.first?.connectionCount == 2)
        #expect(snapshot.networkConnections.first?.sentBytes == 1_433)
        #expect(snapshot.networkConnections.first?.receivedBytes == 560)

        #expect(snapshot.processDetails.count == 2)
        #expect(snapshot.processDetails.first?.pid == 783_214)
        #expect(snapshot.processDetails.first?.user == "root")
        #expect(snapshot.processDetails.first?.memoryBytes == 99_719_168)
        #expect(abs((snapshot.processDetails.first?.cpuPercent ?? -1) - 5.0) < 0.0001)
        #expect(snapshot.processDetails.first?.command == "AliYunDunMonito")
        #expect(snapshot.processDetails.first?.location == "/usr/local/aegis/aegis_client/aegis_12_91/AliYunDunMonitor")
    }

    @Test
    func deltaComputesRatesFromSequentialSnapshots() {
        let previous = ServerResourceMetricsSnapshot(
            cpuFraction: 0.2,
            memoryFraction: 0.4,
            swapFraction: 0.1,
            diskFraction: 0.3,
            memoryUsedBytes: 4_000,
            memoryTotalBytes: 10_000,
            swapUsedBytes: 1_000,
            swapTotalBytes: 10_000,
            diskUsedBytes: 3_000,
            diskTotalBytes: 10_000,
            processCount: 32,
            networkRXBytes: 10_000,
            networkTXBytes: 20_000,
            diskReadBytes: 30_000,
            diskWriteBytes: 40_000,
            loadAverage1: 0.3,
            loadAverage5: 0.2,
            loadAverage15: 0.1,
            uptimeSeconds: 120,
            topProcesses: [],
            filesystems: [],
            networkConnections: [],
            processDetails: [],
            sampledAt: Date(timeIntervalSince1970: 100)
        )
        let current = ServerResourceMetricsSnapshot(
            cpuFraction: 0.4,
            memoryFraction: 0.5,
            swapFraction: 0.2,
            diskFraction: 0.35,
            memoryUsedBytes: 5_000,
            memoryTotalBytes: 10_000,
            swapUsedBytes: 2_000,
            swapTotalBytes: 10_000,
            diskUsedBytes: 3_500,
            diskTotalBytes: 10_000,
            processCount: 36,
            networkRXBytes: 16_000,
            networkTXBytes: 26_000,
            diskReadBytes: 36_000,
            diskWriteBytes: 45_000,
            loadAverage1: 0.5,
            loadAverage5: 0.4,
            loadAverage15: 0.3,
            uptimeSeconds: 126,
            topProcesses: [],
            filesystems: [],
            networkConnections: [],
            processDetails: [],
            sampledAt: Date(timeIntervalSince1970: 103)
        )

        let delta = ServerMetricsDelta.between(previous: previous, current: current)
        #expect(delta.networkRXBytesPerSecond == 2_000)
        #expect(delta.networkTXBytesPerSecond == 2_000)
        #expect(delta.diskReadBytesPerSecond == 2_000)
        #expect(delta.diskWriteBytesPerSecond == 1_666)
    }
}
