import Foundation

enum ServerMonitoringSortDirection: String, CaseIterable {
    case ascending
    case descending

    var comparatorOrder: SortOrder {
        switch self {
        case .ascending:
            return .forward
        case .descending:
            return .reverse
        }
    }
}

enum ServerMonitoringNetworkSortOption: String, CaseIterable {
    case connections
    case remoteAddressCount
    case port
    case processName
    case sentBytes
    case receivedBytes
    case pid
}

enum ServerMonitoringProcessSortOption: String, CaseIterable {
    case cpu
    case memory
    case pid
    case command
    case user
}

enum ServerMonitoringSortOrder {
    static let defaultNetworkOption: ServerMonitoringNetworkSortOption = .connections
    static let defaultNetworkDirection: ServerMonitoringSortDirection = .descending
    static let defaultProcessOption: ServerMonitoringProcessSortOption = .cpu
    static let defaultProcessDirection: ServerMonitoringSortDirection = .descending

    static func comparators(
        for option: ServerMonitoringNetworkSortOption,
        direction: ServerMonitoringSortDirection
    ) -> [KeyPathComparator<ServerNetworkConnectionMetric>] {
        let primary: KeyPathComparator<ServerNetworkConnectionMetric> = switch option {
        case .connections:
            KeyPathComparator(\.connectionCountSortValue, order: direction.comparatorOrder)
        case .remoteAddressCount:
            KeyPathComparator(\.remoteAddressCountSortValue, order: direction.comparatorOrder)
        case .port:
            KeyPathComparator(\.portSortValue, order: direction.comparatorOrder)
        case .processName:
            KeyPathComparator(\.processName, comparator: .localizedStandard, order: direction.comparatorOrder)
        case .sentBytes:
            KeyPathComparator(\.sentBytesSortValue, order: direction.comparatorOrder)
        case .receivedBytes:
            KeyPathComparator(\.receivedBytesSortValue, order: direction.comparatorOrder)
        case .pid:
            KeyPathComparator(\.pidSortValue, order: direction.comparatorOrder)
        }

        return [
            primary,
            KeyPathComparator(\.connectionCountSortValue, order: .reverse),
            KeyPathComparator(\.remoteAddressCountSortValue, order: .reverse),
            KeyPathComparator(\.portSortValue, order: .forward),
            KeyPathComparator(\.processName, comparator: .localizedStandard, order: .forward)
        ]
    }

    static func comparators(
        for option: ServerMonitoringProcessSortOption,
        direction: ServerMonitoringSortDirection
    ) -> [KeyPathComparator<ServerProcessDetailsMetric>] {
        let primary: KeyPathComparator<ServerProcessDetailsMetric> = switch option {
        case .cpu:
            KeyPathComparator(\.cpuPercentSortValue, order: direction.comparatorOrder)
        case .memory:
            KeyPathComparator(\.memoryBytesSortValue, order: direction.comparatorOrder)
        case .pid:
            KeyPathComparator(\.pidSortValue, order: direction.comparatorOrder)
        case .command:
            KeyPathComparator(\.command, comparator: .localizedStandard, order: direction.comparatorOrder)
        case .user:
            KeyPathComparator(\.user, comparator: .localizedStandard, order: direction.comparatorOrder)
        }

        return [
            primary,
            KeyPathComparator(\.cpuPercentSortValue, order: .reverse),
            KeyPathComparator(\.memoryBytesSortValue, order: .reverse),
            KeyPathComparator(\.pidSortValue, order: .forward),
            KeyPathComparator(\.command, comparator: .localizedStandard, order: .forward)
        ]
    }
}
