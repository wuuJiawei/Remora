import Foundation

enum ServerMonitoringSortOrder {
    static let defaultNetwork: [KeyPathComparator<ServerNetworkConnectionMetric>] = [
        KeyPathComparator(\.connectionCountSortValue, order: .reverse),
        KeyPathComparator(\.remoteAddressCountSortValue, order: .reverse),
        KeyPathComparator(\.portSortValue, order: .forward),
        KeyPathComparator(\.processName, comparator: .localizedStandard)
    ]

    static let defaultProcess: [KeyPathComparator<ServerProcessDetailsMetric>] = [
        KeyPathComparator(\.cpuPercentSortValue, order: .reverse),
        KeyPathComparator(\.memoryBytesSortValue, order: .reverse),
        KeyPathComparator(\.pidSortValue, order: .forward),
        KeyPathComparator(\.command, comparator: .localizedStandard)
    ]
}
