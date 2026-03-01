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
}
