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

    @Test
    func permissionsEditorStringsAreLocalizedInSimplifiedChinese() {
        #expect(L10n.tr("Edit Permissions", fallback: "Edit Permissions", modeOverride: .simplifiedChinese) == "编辑权限")
        #expect(L10n.tr("Apply changes recursively", fallback: "Apply changes recursively", modeOverride: .simplifiedChinese) == "同时修改子文件属性")
        #expect(L10n.tr("Owner", fallback: "Owner", modeOverride: .simplifiedChinese) == "所有者")
        #expect(L10n.tr("Public", fallback: "Public", modeOverride: .simplifiedChinese) == "公共")
        #expect(L10n.tr("Read", fallback: "Read", modeOverride: .simplifiedChinese) == "读取")
        #expect(L10n.tr("Write", fallback: "Write", modeOverride: .simplifiedChinese) == "写入")
        #expect(L10n.tr("Execute", fallback: "Execute", modeOverride: .simplifiedChinese) == "可执行")
        #expect(L10n.tr("User", fallback: "User", modeOverride: .simplifiedChinese) == "用户")
        #expect(L10n.tr("Permissions should be a valid octal value, e.g. 0755", fallback: "Permissions should be a valid octal value, e.g. 0755", modeOverride: .simplifiedChinese) == "权限应为有效的八进制值，例如 0755")
    }
}
