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

    @Test
    func archiveStringsAreLocalizedInSimplifiedChinese() {
        #expect(L10n.tr("Compress", fallback: "Compress", modeOverride: .simplifiedChinese) == "压缩")
        #expect(L10n.tr("Compress Files", fallback: "Compress Files", modeOverride: .simplifiedChinese) == "压缩文件")
        #expect(L10n.tr("Extract To", fallback: "Extract To", modeOverride: .simplifiedChinese) == "解压到")
        #expect(L10n.tr("Extract Archive", fallback: "Extract Archive", modeOverride: .simplifiedChinese) == "解压压缩包")
        #expect(L10n.tr("Archive created.", fallback: "Archive created.", modeOverride: .simplifiedChinese) == "压缩包已创建。")
        #expect(L10n.tr("Archive extracted.", fallback: "Archive extracted.", modeOverride: .simplifiedChinese) == "压缩包已解压。")
        #expect(L10n.tr("Preparing files…", fallback: "Preparing files…", modeOverride: .simplifiedChinese) == "正在准备文件…")
        #expect(L10n.tr("Uploading archive…", fallback: "Uploading archive…", modeOverride: .simplifiedChinese) == "正在上传压缩包…")
        #expect(L10n.tr("Extracting archive…", fallback: "Extracting archive…", modeOverride: .simplifiedChinese) == "正在解压压缩包…")
    }

    @Test
    func monitoringTabStringsAreLocalizedInSimplifiedChinese() {
        #expect(L10n.tr("Server Monitoring", fallback: "Server Monitoring", modeOverride: .simplifiedChinese) == "服务器监控")
        #expect(L10n.tr("System Information Monitoring", fallback: "System Information Monitoring", modeOverride: .simplifiedChinese) == "系统信息监控")
        #expect(L10n.tr("Network Monitoring", fallback: "Network Monitoring", modeOverride: .simplifiedChinese) == "网络监控")
        #expect(L10n.tr("Process Monitoring", fallback: "Process Monitoring", modeOverride: .simplifiedChinese) == "进程监控")
        #expect(L10n.tr("Listen IP", fallback: "Listen IP", modeOverride: .simplifiedChinese) == "监听 IP")
        #expect(L10n.tr("IP Count", fallback: "IP Count", modeOverride: .simplifiedChinese) == "IP 数")
        #expect(L10n.tr("Connections", fallback: "Connections", modeOverride: .simplifiedChinese) == "连接数")
        #expect(L10n.tr("Upload", fallback: "Upload", modeOverride: .simplifiedChinese) == "上传")
        #expect(L10n.tr("Location", fallback: "Location", modeOverride: .simplifiedChinese) == "位置")
        #expect(L10n.tr("Search", fallback: "Search", modeOverride: .simplifiedChinese) == "搜索")
        #expect(L10n.tr("Sort", fallback: "Sort", modeOverride: .simplifiedChinese) == "排序")
        #expect(L10n.tr("Descending", fallback: "Descending", modeOverride: .simplifiedChinese) == "降序")
        #expect(L10n.tr("No network monitoring data yet.", fallback: "No network monitoring data yet.", modeOverride: .simplifiedChinese) == "暂无网络监控数据。")
        #expect(L10n.tr("Network activity rows will appear after the next successful sampling cycle.", fallback: "Network activity rows will appear after the next successful sampling cycle.", modeOverride: .simplifiedChinese) == "下一次成功采样后，这里会显示网络活动行。")
        #expect(L10n.tr("No matching network monitoring results.", fallback: "No matching network monitoring results.", modeOverride: .simplifiedChinese) == "没有匹配的网络监控结果。")
        #expect(L10n.tr("No process monitoring data yet.", fallback: "No process monitoring data yet.", modeOverride: .simplifiedChinese) == "暂无进程监控数据。")
        #expect(L10n.tr("Process rows will appear after the next successful sampling cycle.", fallback: "Process rows will appear after the next successful sampling cycle.", modeOverride: .simplifiedChinese) == "下一次成功采样后，这里会显示进程行。")
        #expect(L10n.tr("No matching process monitoring results.", fallback: "No matching process monitoring results.", modeOverride: .simplifiedChinese) == "没有匹配的进程监控结果。")
        #expect(L10n.tr("Try a different keyword or sort option.", fallback: "Try a different keyword or sort option.", modeOverride: .simplifiedChinese) == "试试别的关键词或排序方式。")
        let title = String(format: L10n.tr("%@ - Server Monitoring", fallback: "%@ - Server Monitoring", modeOverride: .simplifiedChinese), "prod-api")
        #expect(title == "prod-api-服务器监控")
    }
}
