import Testing
@testable import RemoraApp

struct ActivityMonitorSortDescriptorTests {
    @Test
    func resourceFieldsDefaultToDescendingWhenSelected() {
        let descriptor = ActivityMonitorSortDescriptor.default.toggled(to: .cpu)
        let stats = [
            makeStat(name: "low", cpu: 1.2),
            makeStat(name: "high", cpu: 42.0),
        ]

        #expect(descriptor.ascending == false)
        #expect(descriptor.sorted(stats).map(\.name) == ["high", "low"])
    }

    @Test
    func repeatedFieldClickTogglesDirection() {
        let descriptor = ActivityMonitorSortDescriptor.default
            .toggled(to: .cpu)
            .toggled(to: .cpu)
        let stats = [
            makeStat(name: "high", cpu: 42.0),
            makeStat(name: "low", cpu: 1.2),
        ]

        #expect(descriptor.ascending)
        #expect(descriptor.sorted(stats).map(\.name) == ["low", "high"])
    }

    @Test
    func numericFieldsSortByParsedValues() {
        let low = makeStat(
            name: "low",
            memoryBytes: 900,
            networkBytes: 1_200,
            diskBytes: 32,
            pidsValue: 2
        )
        let high = makeStat(
            name: "high",
            memoryBytes: 2_048,
            networkBytes: 9_900,
            diskBytes: 128,
            pidsValue: 12
        )
        let stats = [low, high]

        #expect(ActivityMonitorSortDescriptor(field: .memory, ascending: false).sorted(stats).map(\.name) == ["high", "low"])
        #expect(ActivityMonitorSortDescriptor(field: .network, ascending: false).sorted(stats).map(\.name) == ["high", "low"])
        #expect(ActivityMonitorSortDescriptor(field: .disk, ascending: false).sorted(stats).map(\.name) == ["high", "low"])
        #expect(ActivityMonitorSortDescriptor(field: .pids, ascending: false).sorted(stats).map(\.name) == ["high", "low"])
    }

    @Test
    func metricsParserReadsDockerByteUnitsAndTotals() {
        #expect(ActivityMonitorMetricsParser.parseUsageBytes("4.8MiB / 1.9GiB") == 5_033_165)
        #expect(ActivityMonitorMetricsParser.parseTotalIOBytes("1.2kB / 3.4kB") == 4_600)
        #expect(ActivityMonitorMetricsParser.parseTotalIOBytes("0B / 31kB") == 31_000)
        #expect(ActivityMonitorMetricsParser.parsePIDs("6") == 6)
    }

    private func makeStat(
        name: String,
        cpu: Double = 0,
        memoryBytes: Int64 = 0,
        networkBytes: Int64 = 0,
        diskBytes: Int64 = 0,
        pidsValue: Int? = nil
    ) -> DockerContainerStats {
        DockerContainerStats(
            containerID: name,
            name: name,
            cpuPercent: cpu,
            memoryUsage: "\(memoryBytes)B",
            memoryUsageBytes: memoryBytes,
            memoryPercent: nil,
            networkIO: "\(networkBytes)B / 0B",
            networkIOBytes: networkBytes,
            blockIO: "\(diskBytes)B / 0B",
            blockIOBytes: diskBytes,
            pids: pidsValue.map(String.init),
            pidsValue: pidsValue
        )
    }
}
