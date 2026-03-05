# AI in Session - Tasks

Status allowed: `todo` | `in_progress` | `done`

## Milestone M0 - Planning and Baseline

- [x] `status: done` `id: AI-000` 创建分支 `codex/ai-session-assistant-design-plan`；验收：分支可见且独立于 `main`。
- [x] `status: done` `id: AI-001` 输出 `design` 文档；验收：覆盖 3 种交互模式 + Plan/Draft/Guard/Run/Reflect。
- [x] `status: done` `id: AI-002` 输出 `tasks` 文档；验收：包含里程碑、依赖、验收标准。

## Milestone M1 - Session AI Skeleton (MVP Week 1)

- [x] `status: done` `id: AI-100` `[P0]` 新增 `SessionAIAssistantCoordinator`（会话级状态机）；验收：可绑定到单个 session 并维持消息历史。
- [ ] `status: todo` `id: AI-101` `[P0]` 新增 Sidecar 面板 UI（可收起/展开）；验收：可发送消息并显示 AI 回复占位。
- [x] `status: done` `id: AI-102` `[P0]` 定义 `LLMProvider` 协议与基础数据结构；验收：可通过 mock provider 走通一次问答。
- [ ] `status: todo` `id: AI-103` `[P0]` 实现首个 provider adapter（建议 OpenAI）；验收：文本与流式响应可用。
- [ ] `status: todo` `id: AI-104` `[P0]` 落地 `AIContextPackBuilder` v1（system info + recent commands + output tail）；验收：构造结果可序列化并带大小限制。

## Milestone M2 - Plan/Draft/Guard Loop (MVP Week 1~2)

- [ ] `status: todo` `id: AI-200` `[P0]` 实现 Plan 输出结构（步骤+验证）；验收：每次请求至少返回 1 个 plan step。
- [ ] `status: todo` `id: AI-201` `[P0]` 实现 Draft 输出结构（1~3 候选命令）；验收：包含适用系统、sudo 需求、风险等级。
- [ ] `status: todo` `id: AI-202` `[P0]` 实现 `CommandRiskEngine`（首批 30~50 规则）；验收：危险命令命中率用样例集验证。
- [ ] `status: todo` `id: AI-203` `[P0]` 接入执行前确认弹层（高风险强制二次确认）；验收：未确认不能执行。
- [ ] `status: todo` `id: AI-204` `[P0]` 实现 `run_command` 工具桥接（timeout/exit code/stdout/stderr）；验收：执行结果可完整回传。
- [ ] `status: todo` `id: AI-205` `[P0]` 实现 Reflect 结果卡片；验收：AI 能解释执行结果并给下一步建议。

## Milestone M3 - Inline Prompt and Smart Assist

- [ ] `status: todo` `id: AI-300` `[P1]` 支持 inline `@ai ...` 入口；验收：终端输入触发 AI draft，不自动执行。
- [ ] `status: todo` `id: AI-301` `[P1]` 输出异常检测器（基于 exit code + regex）；验收：命中错误时可推送 Smart Assist 建议。
- [ ] `status: todo` `id: AI-302` `[P1]` Smart Assist 交互（忽略/采纳/继续追问）；验收：不打断输入焦点。

## Milestone M4 - Safety, Audit, and Policy

- [ ] `status: todo` `id: AI-400` `[P0]` 实现敏感信息脱敏器 `redact`；验收：常见 token/key 规则通过单测。
- [ ] `status: todo` `id: AI-401` `[P0]` 实现会话审计日志（建议/确认/执行摘要）；验收：可按 session 查看历史。
- [ ] `status: todo` `id: AI-402` `[P0]` 增加策略档位：`ReadOnlyDefault`/`ConfirmedWrite`/`ProdStrict`；验收：策略切换即时生效。
- [ ] `status: todo` `id: AI-403` `[P1]` Host 环境标签（prod/staging/dev）接入策略；验收：prod 默认进入 strict。

## Milestone M5 - Multi Provider and Settings

- [ ] `status: todo` `id: AI-500` `[P1]` provider/model 选择设置项；验收：session 可持久化 provider 偏好。
- [ ] `status: todo` `id: AI-501` `[P1]` 增加第 2 个 provider（Anthropic 或 Qwen）；验收：切换后可同等走通 Plan->Reflect。
- [ ] `status: todo` `id: AI-502` `[P1]` 统一限流、重试、费用统计接口；验收：Provider 层暴露一致指标。

## Milestone M6 - Testing and Release Gate

- [ ] `status: todo` `id: AI-600` `[P0]` 单测覆盖：ContextPack/RiskEngine/Orchestrator；验收：核心逻辑覆盖率达到团队阈值。
- [ ] `status: todo` `id: AI-601` `[P1]` UI 自动化：sidecar、inline、smart assist 主路径；验收：CI 可稳定运行。
- [ ] `status: todo` `id: AI-602` `[P0]` 安全回归：高风险命令阻断与确认流程；验收：危险样例全部通过。
- [ ] `status: todo` `id: AI-603` `[P1]` 发布检查清单更新（文档+开关+回滚）；验收：具备灰度发布条件。

## Dependency Notes

- `AI-102` 是 `AI-103/AI-500/AI-501` 的前置。
- `AI-104` 是 `AI-200/AI-201/AI-205` 的前置。
- `AI-202` 是 `AI-203/AI-204` 的前置。
- `AI-400` 是所有 provider 出站调用上线前置。

## MVP Exit Criteria

MVP 视为完成需满足：

- Sidecar 绑定 session 且可稳定多轮。
- 支持 Plan + Draft + Guard + Run + Reflect 闭环。
- 写操作必须确认，高风险命令可阻断。
- 至少 1 个 provider 可用，失败有明确降级提示。
- 有最小可审计日志，支持问题排查。
