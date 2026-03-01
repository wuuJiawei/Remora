import Foundation
import RemoraCore

struct SSHHostMetricsKey: Hashable, Sendable {
    let address: String
    let port: Int
    let username: String

    init(host: RemoraCore.Host) {
        self.address = host.address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.port = host.port
        self.username = host.username.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var title: String {
        "\(username)@\(address):\(port)"
    }
}

struct ServerResourceMetricsSnapshot: Equatable, Sendable {
    let cpuFraction: Double?
    let memoryFraction: Double?
    let diskFraction: Double?
    let memoryUsedBytes: Int64?
    let memoryTotalBytes: Int64?
    let diskUsedBytes: Int64?
    let diskTotalBytes: Int64?
    let loadAverage1: Double?
    let uptimeSeconds: Int64?
    let sampledAt: Date
}

struct ServerHostMetricsState: Equatable, Sendable {
    var snapshot: ServerResourceMetricsSnapshot?
    var isLoading: Bool
    var errorMessage: String?
    var lastAttemptAt: Date?

    static let idle = ServerHostMetricsState(
        snapshot: nil,
        isLoading: false,
        errorMessage: nil,
        lastAttemptAt: nil
    )
}

actor RemoteServerMetricsProbe {
    private static let metricsCommand = """
    LC_ALL=C /bin/sh <<'REMORA_METRICS'
    cpu_permille=-1
    if [ -r /proc/stat ]; then
      read -r _ u n s i io irq sirq st _ < /proc/stat
      t1=$((u+n+s+i+io+irq+sirq+st))
      idle1=$((i+io))
      sleep 0.2
      read -r _ u2 n2 s2 i2 io2 irq2 sirq2 st2 _ < /proc/stat
      t2=$((u2+n2+s2+i2+io2+irq2+sirq2+st2))
      idle2=$((i2+io2))
      dt=$((t2-t1))
      didle=$((idle2-idle1))
      if [ "$dt" -gt 0 ]; then
        cpu_permille=$((1000*(dt-didle)/dt))
      fi
    fi

    mem_total_kb=-1
    mem_used_kb=-1
    if [ -r /proc/meminfo ]; then
      mem_total_kb=$(awk '/MemTotal:/ {print $2; exit}' /proc/meminfo)
      mem_available_kb=$(awk '/MemAvailable:/ {print $2; exit}' /proc/meminfo)
      if [ -n "$mem_total_kb" ] && [ -n "$mem_available_kb" ]; then
        mem_used_kb=$((mem_total_kb-mem_available_kb))
      fi
    fi

    disk_total_kb=-1
    disk_used_kb=-1
    set -- $(df -Pk / 2>/dev/null | awk 'NR==2 {print $2, $3}')
    if [ "$#" -ge 2 ]; then
      disk_total_kb=$1
      disk_used_kb=$2
    fi

    load1=-1
    if [ -r /proc/loadavg ]; then
      load1=$(awk '{print $1; exit}' /proc/loadavg)
    fi

    uptime_s=-1
    if [ -r /proc/uptime ]; then
      uptime_s=$(awk '{print int($1); exit}' /proc/uptime)
    fi

    printf 'cpu_permille=%s\\n' "$cpu_permille"
    printf 'mem_total_kb=%s\\n' "$mem_total_kb"
    printf 'mem_used_kb=%s\\n' "$mem_used_kb"
    printf 'disk_total_kb=%s\\n' "$disk_total_kb"
    printf 'disk_used_kb=%s\\n' "$disk_used_kb"
    printf 'load1=%s\\n' "$load1"
    printf 'uptime_s=%s\\n' "$uptime_s"
    REMORA_METRICS
    """

    private var clients: [SSHHostMetricsKey: SystemSFTPClient] = [:]

    func sample(host: RemoraCore.Host) async throws -> ServerResourceMetricsSnapshot {
        let key = SSHHostMetricsKey(host: host)
        let client = clientForHost(host, key: key)
        let output = try await client.executeRemoteShellCommand(Self.metricsCommand, timeout: 5.5)
        guard let snapshot = Self.parseSnapshot(from: output) else {
            throw SSHError.connectionFailed("metrics output parsing failed")
        }
        return snapshot
    }

    private func clientForHost(_ host: RemoraCore.Host, key: SSHHostMetricsKey) -> SystemSFTPClient {
        if let existing = clients[key] {
            return existing
        }
        let client = SystemSFTPClient(host: host)
        clients[key] = client
        return client
    }

    static func parseSnapshot(
        from output: String,
        sampledAt: Date = Date()
    ) -> ServerResourceMetricsSnapshot? {
        var values: [String: String] = [:]
        let lines = output
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        for line in lines {
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let key = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }
            values[key] = value
        }

        func parseNonNegativeInt(_ key: String) -> Int64? {
            guard let raw = values[key], let value = Int64(raw), value >= 0 else {
                return nil
            }
            return value
        }

        func parseNonNegativeDouble(_ key: String) -> Double? {
            guard let raw = values[key], let value = Double(raw), value >= 0 else {
                return nil
            }
            return value
        }

        let cpuPermille = parseNonNegativeInt("cpu_permille")
        let memoryTotalKB = parseNonNegativeInt("mem_total_kb")
        let memoryUsedKB = parseNonNegativeInt("mem_used_kb")
        let diskTotalKB = parseNonNegativeInt("disk_total_kb")
        let diskUsedKB = parseNonNegativeInt("disk_used_kb")
        let loadAverage1 = parseNonNegativeDouble("load1")
        let uptimeSeconds = parseNonNegativeInt("uptime_s")

        let cpuFraction = cpuPermille.map { clampFraction(Double($0) / 1000) }
        let memoryFraction = fraction(used: memoryUsedKB, total: memoryTotalKB)
        let diskFraction = fraction(used: diskUsedKB, total: diskTotalKB)
        let memoryUsedBytes = memoryUsedKB.map { $0 * 1024 }
        let memoryTotalBytes = memoryTotalKB.map { $0 * 1024 }
        let diskUsedBytes = diskUsedKB.map { $0 * 1024 }
        let diskTotalBytes = diskTotalKB.map { $0 * 1024 }

        if cpuFraction == nil,
           memoryFraction == nil,
           diskFraction == nil,
           loadAverage1 == nil,
           uptimeSeconds == nil
        {
            return nil
        }

        return ServerResourceMetricsSnapshot(
            cpuFraction: cpuFraction,
            memoryFraction: memoryFraction,
            diskFraction: diskFraction,
            memoryUsedBytes: memoryUsedBytes,
            memoryTotalBytes: memoryTotalBytes,
            diskUsedBytes: diskUsedBytes,
            diskTotalBytes: diskTotalBytes,
            loadAverage1: loadAverage1,
            uptimeSeconds: uptimeSeconds,
            sampledAt: sampledAt
        )
    }

    private static func fraction(used: Int64?, total: Int64?) -> Double? {
        guard let used, let total, total > 0 else { return nil }
        return clampFraction(Double(used) / Double(total))
    }

    private static func clampFraction(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}

@MainActor
final class ServerMetricsCenter: ObservableObject {
    @Published private(set) var states: [SSHHostMetricsKey: ServerHostMetricsState] = [:]

    private let probe = RemoteServerMetricsProbe()
    private let activeRefreshInterval: TimeInterval
    private let inactiveRefreshInterval: TimeInterval
    private let retentionInterval: TimeInterval
    private let maxConcurrentFetches: Int

    private var trackedHosts: [SSHHostMetricsKey: RemoraCore.Host] = [:]
    private var activeHostKey: SSHHostMetricsKey?
    private var inFlightKeys: Set<SSHHostMetricsKey> = []
    private var lastFetchAt: [SSHHostMetricsKey: Date] = [:]
    private var lastSeenAt: [SSHHostMetricsKey: Date] = [:]
    private var pollingTask: Task<Void, Never>?

    init(
        activeRefreshInterval: TimeInterval = 4,
        inactiveRefreshInterval: TimeInterval = 10,
        retentionInterval: TimeInterval = 45,
        maxConcurrentFetches: Int = 2
    ) {
        self.activeRefreshInterval = activeRefreshInterval
        self.inactiveRefreshInterval = inactiveRefreshInterval
        self.retentionInterval = retentionInterval
        self.maxConcurrentFetches = max(1, maxConcurrentFetches)
        startPollingLoop()
    }

    deinit {
        pollingTask?.cancel()
    }

    func updateTrackedHosts(_ hosts: [RemoraCore.Host], activeHost: RemoraCore.Host?) {
        let now = Date()
        var unique: [SSHHostMetricsKey: RemoraCore.Host] = [:]
        unique.reserveCapacity(hosts.count)
        for host in hosts {
            let key = SSHHostMetricsKey(host: host)
            unique[key] = host
            lastSeenAt[key] = now
        }
        trackedHosts = unique
        activeHostKey = activeHost.map(SSHHostMetricsKey.init(host:))
        cleanupStaleEntries(now: now)
    }

    func state(for host: RemoraCore.Host?) -> ServerHostMetricsState? {
        guard let host else { return nil }
        return states[SSHHostMetricsKey(host: host)]
    }

    private func startPollingLoop() {
        pollingTask?.cancel()
        pollingTask = Task { [weak self] in
            guard let self else { return }
            await self.pollingLoop()
        }
    }

    private func pollingLoop() async {
        while !Task.isCancelled {
            scheduleDueFetches()
            try? await Task.sleep(for: .milliseconds(350))
        }
    }

    private func scheduleDueFetches() {
        let now = Date()
        let availableSlots = max(0, maxConcurrentFetches - inFlightKeys.count)
        guard availableSlots > 0 else { return }

        let dueHosts = trackedHosts.compactMap { key, host -> (key: SSHHostMetricsKey, host: RemoraCore.Host, age: TimeInterval, isActive: Bool)? in
            guard !inFlightKeys.contains(key) else { return nil }
            let interval = refreshInterval(for: key)
            let lastFetched = lastFetchAt[key] ?? .distantPast
            let age = now.timeIntervalSince(lastFetched)
            guard age >= interval else { return nil }
            return (key: key, host: host, age: age, isActive: key == activeHostKey)
        }
        .sorted { lhs, rhs in
            if lhs.isActive != rhs.isActive {
                return lhs.isActive && !rhs.isActive
            }
            return lhs.age > rhs.age
        }

        for due in dueHosts.prefix(availableSlots) {
            launchFetch(for: due.key, host: due.host, startedAt: now)
        }
    }

    private func refreshInterval(for key: SSHHostMetricsKey) -> TimeInterval {
        key == activeHostKey ? activeRefreshInterval : inactiveRefreshInterval
    }

    private func launchFetch(for key: SSHHostMetricsKey, host: RemoraCore.Host, startedAt: Date) {
        inFlightKeys.insert(key)

        var currentState = states[key] ?? .idle
        currentState.isLoading = true
        currentState.errorMessage = nil
        currentState.lastAttemptAt = startedAt
        states[key] = currentState

        Task(priority: .utility) { [weak self] in
            guard let self else { return }
            do {
                let snapshot = try await self.probe.sample(host: host)
                self.completeFetch(for: key, snapshot: snapshot, errorMessage: nil)
            } catch {
                self.completeFetch(
                    for: key,
                    snapshot: nil,
                    errorMessage: error.localizedDescription
                )
            }
        }
    }

    private func completeFetch(
        for key: SSHHostMetricsKey,
        snapshot: ServerResourceMetricsSnapshot?,
        errorMessage: String?
    ) {
        inFlightKeys.remove(key)
        lastFetchAt[key] = Date()

        var nextState = states[key] ?? .idle
        nextState.isLoading = false
        if let snapshot {
            nextState.snapshot = snapshot
            nextState.errorMessage = nil
        } else if let errorMessage {
            nextState.errorMessage = errorMessage
        }
        states[key] = nextState
    }

    private func cleanupStaleEntries(now: Date) {
        let trackedKeys = Set(trackedHosts.keys)
        let staleKeys = lastSeenAt.compactMap { key, lastSeen -> SSHHostMetricsKey? in
            guard !trackedKeys.contains(key) else { return nil }
            guard !inFlightKeys.contains(key) else { return nil }
            guard now.timeIntervalSince(lastSeen) > retentionInterval else { return nil }
            return key
        }

        guard !staleKeys.isEmpty else { return }
        for key in staleKeys {
            lastSeenAt.removeValue(forKey: key)
            lastFetchAt.removeValue(forKey: key)
            states.removeValue(forKey: key)
        }
    }
}
