import Foundation

enum L10n {
    private static let resourceBundle: Bundle = {
        #if SWIFT_PACKAGE
        return .module
        #else
        return .main
        #endif
    }()

    static func tr(
        _ key: String,
        fallback: String,
        table: String? = nil,
        modeOverride: AppLanguageMode? = nil
    ) -> String {
        let mode: AppLanguageMode = modeOverride ?? AppLanguageMode.resolved(
            from: AppPreferences.shared.value(for: \.languageModeRawValue)
        )

        if let localizationCode = mode.bundleLocalizationCode,
           let localizedBundle = localizationBundle(for: localizationCode) {
            return localizedBundle.localizedString(forKey: key, value: fallback, table: table)
        }

        return resourceBundle.localizedString(forKey: key, value: fallback, table: table)
    }

    private static func localizationBundle(for code: String) -> Bundle? {
        if let path = resourceBundle.path(forResource: code, ofType: "lproj"),
           let bundle = Bundle(path: path) {
            return bundle
        }

        // Xcode versions differ in how they preserve localization directory
        // casing, so fall back to a case-insensitive lookup of the .lproj.
        guard let resourceURL = resourceBundle.resourceURL,
              let entries = try? FileManager.default.contentsOfDirectory(
                  at: resourceURL,
                  includingPropertiesForKeys: nil
              )
        else {
            return nil
        }
        guard let match = entries.first(where: { entry in
            entry.pathExtension.caseInsensitiveCompare("lproj") == .orderedSame
                && entry.deletingPathExtension().lastPathComponent
                    .caseInsensitiveCompare(code) == .orderedSame
        }) else {
            return nil
        }
        return Bundle(path: match.path)
    }
}
