import Foundation
import Testing
@testable import RemoraApp

struct L10nTests {
    @Test
    func languageOverrideReturnsSimplifiedChineseString() {
        let value = L10n.tr("Language", fallback: "Language", modeOverride: .simplifiedChinese)
        #expect(value == "语言")
    }

    @Test
    func languageOverrideReturnsEnglishString() {
        let value = L10n.tr("Language", fallback: "Language", modeOverride: .english)
        #expect(value == "Language")
    }
}
