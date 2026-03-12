import Foundation

enum L10n {
    private static let resourceBundle: Bundle = {
        #if SWIFT_PACKAGE
        return .module
        #else
        return .main
        #endif
    }()

    static func tr(_ key: String, fallback: String, modeOverride: AppLanguageMode? = nil) -> String {
        let mode: AppLanguageMode = modeOverride ?? AppLanguageMode.resolved(
            from: UserDefaults.standard.string(forKey: AppSettings.languageModeKey) ?? AppLanguageMode.system.rawValue
        )

        if let localizationCode = mode.bundleLocalizationCode,
           let path = resourceBundle.path(forResource: localizationCode, ofType: "lproj"),
           let localizedBundle = Bundle(path: path) {
            return localizedBundle.localizedString(forKey: key, value: fallback, table: nil)
        }

        return resourceBundle.localizedString(forKey: key, value: fallback, table: nil)
    }
}
