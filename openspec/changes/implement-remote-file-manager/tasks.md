# Tasks: implement-remote-file-manager

Status allowed: `todo` | `in_progress` | `done`

## Milestone A - 数据与协议准备
- [x] `status: done` `id: A01` 扩展 `SFTPClientProtocol`：上传/下载进度、stat、setAttributes、move、copy。
- [x] `status: done` `id: A02` 更新 `MockSFTPClient` 支持新接口，确保测试可运行。
- [x] `status: done` `id: A03` 新增远端属性与传输进度模型（`RemoteFileAttributes`、`TransferProgressSnapshot`）。

## Milestone B - 单栏 File Manager UI
- [x] `status: done` `id: B01` 用单栏远端目录表替换现有双栏 UI（保留路径栏/Back/Refresh）。
- [x] `status: done` `id: B02` 新增路径输入跳转与目录 breadcrumb。
- [x] `status: done` `id: B03` 支持列表多选与批量操作入口（下载/删除/移动）。

## Milestone C - 拖拽与传输中心
- [x] `status: done` `id: C01` 新增 `TransferCenter`（actor）并接入并发调度（默认 3）。
- [x] `status: done` `id: C02` 实现拖拽上传：拖到当前目录或目录行均可上传。
- [x] `status: done` `id: C03` 实现多文件下载到本地目录，显示任务级和总进度。
- [ ] `status: todo` `id: C04` 补齐失败重试与同名冲突策略（覆盖/跳过/重命名）。

## Milestone D - 右键菜单与编辑能力
- [ ] `status: todo` `id: D01` 实现右键动作分发：刷新、删除、重命名、复制、粘贴、下载、移动至。
- [ ] `status: todo` `id: D02` 实现右键动作：编辑、复制路径、复制名称、属性、上传至当前目录（目录菜单）。
- [ ] `status: todo` `id: D03` 实现 `RemoteTextEditor`（打开/编辑/保存/编码提示/大小限制）。
- [ ] `status: todo` `id: D04` 实现 `FilePropertiesSheet`（chmod/chown/modified time 编辑）。

## Milestone E - Terminal 联动
- [ ] `status: todo` `id: E01` 在 `TerminalRuntime` 暴露 `workingDirectory` 与 `changeDirectory(to:)`。
- [ ] `status: todo` `id: E02` 实现 `TerminalDirectorySyncBridge`，打通 file->terminal 和 terminal->file。
- [ ] `status: todo` `id: E03` 增加防循环同步逻辑与降级 `pwd` 探测机制。

## Milestone F - 测试与验收
- [ ] `status: todo` `id: F01` 新增/更新单元测试：ViewModel、TransferCenter、Editor、目录联动。
- [ ] `status: todo` `id: F02` 扩展 `RemoraUIAutomationTests` 覆盖文件管理关键路径。
- [ ] `status: todo` `id: F03` 执行 `swift test` 并修复回归。
- [ ] `status: todo` `id: F04` 执行 `REMORA_RUN_UI_TESTS=1 swift test --filter RemoraUIAutomationTests` 并记录结果。
