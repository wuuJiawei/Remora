import Foundation

enum L10n {
    static func tr(_ key: String, fallback: String) -> String {
        NSLocalizedString(
            key,
            tableName: nil,
            bundle: .module,
            value: fallback,
            comment: ""
        )
    }
}
