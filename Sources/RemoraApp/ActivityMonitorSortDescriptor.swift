import Foundation

enum ActivityMonitorSortField: String, Equatable, Sendable {
    case name
    case cpu
    case memory
    case network
    case disk
    case pids

    init?(columnID: String) {
        self.init(rawValue: columnID)
    }

    var defaultAscending: Bool {
        switch self {
        case .name:
            return true
        case .cpu, .memory, .network, .disk, .pids:
            return false
        }
    }
}

struct ActivityMonitorSortDescriptor: Equatable, Sendable {
    var field: ActivityMonitorSortField
    var ascending: Bool

    static let `default` = ActivityMonitorSortDescriptor(field: .name, ascending: true)

    func toggled(to nextField: ActivityMonitorSortField) -> ActivityMonitorSortDescriptor {
        if field == nextField {
            return ActivityMonitorSortDescriptor(field: nextField, ascending: !ascending)
        }
        return ActivityMonitorSortDescriptor(field: nextField, ascending: nextField.defaultAscending)
    }

    func sorted(_ stats: [DockerContainerStats]) -> [DockerContainerStats] {
        stats.sorted { lhs, rhs in
            let comparison = compare(lhs, rhs)
            if comparison == .orderedSame {
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            return ascending ? comparison == .orderedAscending : comparison == .orderedDescending
        }
    }

    private func compare(_ lhs: DockerContainerStats, _ rhs: DockerContainerStats) -> ComparisonResult {
        switch field {
        case .name:
            return lhs.name.localizedStandardCompare(rhs.name)
        case .cpu:
            return compare(lhs.cpuPercent, rhs.cpuPercent)
        case .memory:
            return compare(lhs.memoryUsageBytes, rhs.memoryUsageBytes)
        case .network:
            return compare(lhs.networkIOBytes, rhs.networkIOBytes)
        case .disk:
            return compare(lhs.blockIOBytes, rhs.blockIOBytes)
        case .pids:
            return compare(lhs.pidsValue ?? -1, rhs.pidsValue ?? -1)
        }
    }

    private func compare<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        if lhs < rhs { return .orderedAscending }
        if lhs > rhs { return .orderedDescending }
        return .orderedSame
    }
}

enum ActivityMonitorMetricsParser {
    static func parseUsageBytes(_ value: String?) -> Int64 {
        let first = value?
            .components(separatedBy: "/")
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return parseByteValue(first)
    }

    static func parseTotalIOBytes(_ value: String?) -> Int64 {
        guard let value else { return 0 }
        return value
            .components(separatedBy: "/")
            .reduce(Int64(0)) { total, part in
                total + parseByteValue(part.trimmingCharacters(in: .whitespacesAndNewlines))
            }
    }

    static func parsePIDs(_ value: String?) -> Int? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return Int(trimmed)
    }

    private static func parseByteValue(_ value: String?) -> Int64 {
        guard let value else { return 0 }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }

        let pattern = #"^([0-9]+(?:\.[0-9]+)?)\s*([A-Za-z]+)?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
              let numberRange = Range(match.range(at: 1), in: trimmed)
        else {
            return 0
        }

        let number = Double(trimmed[numberRange]) ?? 0
        let unit: String
        if let unitRange = Range(match.range(at: 2), in: trimmed) {
            unit = String(trimmed[unitRange]).lowercased()
        } else {
            unit = "b"
        }

        let multiplier: Double = switch unit {
        case "b", "byte", "bytes":
            1
        case "kb", "k":
            1_000
        case "mb", "m":
            1_000_000
        case "gb", "g":
            1_000_000_000
        case "tb", "t":
            1_000_000_000_000
        case "kib", "ki":
            1_024
        case "mib", "mi":
            1_048_576
        case "gib", "gi":
            1_073_741_824
        case "tib", "ti":
            1_099_511_627_776
        default:
            1
        }
        return Int64((number * multiplier).rounded())
    }
}
