# TASKS

Status allowed: `todo` | `in_progress` | `done`

## Milestone M1 - Terminal 内核 MVP（已完成）

- [x] `status: done` `id: T01` `[P0]` 建立工程目录结构：`Core/Terminal/App/Tests`；验收：目录与 target 分层可编译。
- [x] `status: done` `id: T02` `[P0]` 定义核心协议：`SSHClientProtocol/TerminalRendererProtocol/SessionManagerProtocol`；验收：协议被 mock 并可单测。
- [x] `status: done` `id: T03` `[P0]` 建立日志与指标基础：输入延迟、帧耗时、吞吐；验收：可输出本地性能日志。
- [x] `status: done` `id: T04` `[P0]` 实现 `Cell/Line/ScreenBuffer` 数据结构；验收：支持 rows×cols 更新与读取。
- [x] `status: done` `id: T05` `[P0]` 实现 `ScrollbackStore` 分段存储（如每段 1k 行）；验收：可 append/分页读取。
- [x] `status: done` `id: T06` `[P0]` 实现 ANSI/VT 基础解析（颜色、光标移动、清屏）；验收：标准测试样例通过。
- [x] `status: done` `id: T07` `[P0]` 实现 ring buffer + IO 解耦；验收：高频输出不阻塞主线程。
- [x] `status: done` `id: T08` `[P0]` 实现 16ms 帧级 flush 调度；验收：刷屏稳定，CPU 占用可控。
- [x] `status: done` `id: T09` `[P0]` 实现 CoreText 渲染器（首版）；验收：文本正确渲染、无明显闪烁。
- [x] `status: done` `id: T10` `[P0]` 实现 glyph 缓存；验收：重复字符渲染耗时显著下降。
- [x] `status: done` `id: T11` `[P0]` 实现 dirty lines/dirty rect 增量重绘；验收：全屏重绘比例降低。
- [x] `status: done` `id: T12` `[P0]` 实现光标与选区 overlay；验收：移动光标不触发全屏重绘。
- [x] `status: done` `id: T13` `[P0]` 输入系统：按键映射、粘贴、IME 基础；验收：中英文输入正常。
- [x] `status: done` `id: T14` `[P0]` 压测工具：`tail -f`/大吞吐回放；验收：形成基线报告。

## Milestone M2 - SSH 会话内核（已完成，待真实主机手工验收）

- [x] `status: done` `id: T15` `[P0]` `SSHClient`：连接、认证、keepalive；验收：可连通目标主机。
- [x] `status: done` `id: T16` `[P0]` `SSHShellSession`：PTY stdin/stdout/stderr/resize；验收：远端 shell 可交互。
- [x] `status: done` `id: T17` `[P0]` `SessionManager`：会话生命周期与重连策略；验收：断线后可按策略恢复。
- [x] `status: done` `id: T18` `[P0]` `HostKeyStore`：known_hosts 首次确认与变更告警；验收：指纹变化可提示。
- [x] `status: done` `id: T19` `[P0]` `CredentialStore`：Keychain 集成（密码/私钥引用）；验收：敏感信息不落明文。

## Milestone M3 - 会话与主机管理 UI（已完成）

- [x] `status: done` `id: T20` `[P1]` SwiftUI 宿主接入 `TerminalView(NSViewRepresentable)`；验收：UI 可嵌入终端控件。
- [x] `status: done` `id: T21` `[P1]` Tabs 管理；验收：多会话切换稳定。
- [x] `status: done` `id: T22` `[P1]` Pane 分屏（至少 2 分屏）；验收：可水平/垂直分屏。
- [x] `status: done` `id: T23` `[P1]` inactive tab 降频策略；验收：后台 tab 不抢前台帧预算。
- [x] `status: done` `id: T24` `[P1]` Quick Connect 输入框；验收：输入别名可快速连接。
- [x] `status: done` `id: T25` `[P1]` Host 数据模型（name/address/user/tags/group/...）；验收：模型可持久化。
- [x] `status: done` `id: T26` `[P1]` Host 列表页：分组/标签/收藏/最近；验收：基础筛选可用。
- [x] `status: done` `id: T27` `[P1]` Host 搜索；验收：支持名称、标签模糊匹配。
- [x] `status: done` `id: T28` `[P1]` 会话模板（同 host 多 profile）；验收：可保存并一键启动 profile。

## Milestone M4 - SFTP 文件管理闭环（进行中，第一版已落地）

- [x] `status: done` `id: T29` `[P1]` `SFTPClient`：list/get/put/rename/mkdir/rm；验收：核心文件操作可用。
- [x] `status: done` `id: T30` `[P1]` 双栏文件管理器（本地/远端）；验收：目录浏览与刷新正常。
- [x] `status: done` `id: T31` `[P1]` 传输队列（进度/速度/状态）；验收：多任务可见且可取消。
- [ ] `status: in_progress` `id: T32` `[P1]` 并发控制（2~4）与交互隔离；验收：传输不明显影响 shell 交互。
- [ ] `status: todo` `id: T33` `[P1]` 拖拽上传/下载；验收：常见文件拖拽成功。
- [ ] `status: todo` `id: T34` `[P1]` 终端联动（在终端打开目录/复制路径）；验收：右键动作可用。

## Milestone M5 - 增强与长期优化（未开始）

- [ ] `status: todo` `id: T35` `[P2]` 断点续传（offset + 校验）；验收：中断后可续传。
- [ ] `status: todo` `id: T36` `[P2]` 常用命令面板（片段+变量）；验收：可配置并一键发送。
- [ ] `status: todo` `id: T37` `[P2]` 连接健康提示（延迟/丢包/host key 警示）；验收：异常可视化。
- [ ] `status: todo` `id: T38` `[P2]` 主题/字体/快捷键设置页；验收：修改后可即时生效。
- [ ] `status: todo` `id: T39` `[P2]` Scrollback 老段压缩或落盘；验收：长会话内存占用稳定。
- [ ] `status: todo` `id: T40` `[P2]` Renderer 抽象预留 Metal 实现位；验收：接口无破坏性可替换。

## Milestone M6 - 测试与发布门禁（进行中）

- [x] `status: done` `id: T41` `[P0]` Core 单元测试（SSH/SFTP/session/buffer/parser）；验收：关键模块覆盖率达标。
- [x] `status: done` `id: T42` `[P0]` 终端回归测试（ANSI 样例集）；验收：基准样例无回归。
- [ ] `status: in_progress` `id: T43` `[P1]` 集成测试（连接、断线、重连、文件传输）；验收：关键用户路径通过。
- [ ] `status: in_progress` `id: T44` `[P1]` 性能门禁（输入延迟、帧耗时、CPU）；验收：达到设定阈值。
- [ ] `status: todo` `id: T45` `[P1]` 发布前安全检查（Keychain/known_hosts/日志脱敏）；验收：无明文凭证泄露。
