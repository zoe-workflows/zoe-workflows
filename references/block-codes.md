# 阻断码分流（block_code → 动作）

BLOCKED 之后的第一件事不是"再 resume 一次"，而是**看码决定该不该 resume**。
resume 一个前置条件没解决的任务，只是把同一段失败重放一遍，还多烧一次预算。

分四档：**auto**（脚本可以代劳）、**human**（必须人给输入/授权）、**rework**
（换一棵树重来，不是续跑）、**stop**（先停整个项目的派发）。

`scripts/zoe-auto-recover.sh <task_id>` 把这张表变成命令；默认只打印建议，
`--apply` 只执行 auto 档里的动作。

## auto：可以续跑

| 码 | 含义 | 动作 |
|---|---|---|
| `AGENT_RATE_LIMITED` | 上游限流 | 等 5 分钟后 `task resume`（同 run 可续，不丢工作区） |
| `RUN_TIMEOUT` | 本次 run 超时 | `task resume`；同一个 run 只允许一次，再超时就改计划（`task revise` 拆小） |
| `CI_PENDING` | 远端检查未出结果 | 不要 resume；`task status` 刷新，等 CI 落地 |
| `RETRY_EXHAUSTED` | 自动重试已用尽 | 停手，按 `last_error` 改计划；重试只会重复同一个失败 |

## human：缺输入或缺授权

| 码 | 含义 | 动作 |
|---|---|---|
| `INPUT_REQUIRED` | worker 在等一个答案 | `task answer`；**先答再 resume**，否则新 run 在没有答案的情况下重跑 |
| `SPEC_CLARIFICATION_REQUIRED` | `open_questions` 未清 | `task revise` 补 spec（不是 resume） |
| `DECISIONS_OPEN` | 设计裁定未拍板 | 由 owner 拍板后 `task revise` 回写 `decisions[].status=resolved`（见 [decision-record.md](decision-record.md)） |
| `SCOPE_VIOLATION` | 改动超出 `allowed_paths` | `bash scripts/zoe-revise-scope.sh`（两段式，需人确认）；不要放宽到整个仓库 |
| `ALLOWLIST_UNCONFIRMED` | 授权未确认 | 按 `task attest` 流程确认；确认范围可以比白名单更窄 |
| `POLICY_CHANGED` | 项目策略变了 | `task revise` 重冻结；不要用旧策略续跑 |
| `POLICY_DENIED` | 策略不允许这个操作 | 改操作或改策略，不重试 |
| `AGENT_PERMISSION_DENIED` / `AGENT_AUTH_REQUIRED` | 执行器权限/登录失效 | 修执行器授权后 `task resume`（工作区保留） |
| `ACCEPTANCE_UNREVIEWED` / `ACCEPTANCE_UNACKNOWLEDGED` | 逐条判定缺失或未确认 | `task review` 补判定；`NOT_VERIFIED` 要逐条 ack |
| `ACCEPTANCE_REVIEW_FAILED` | 判定有 FAIL | 修实现 → 重新 verify → 重新判定 |
| `DEPENDENCY_NOT_MET` | 上游需求未闭环 | 去推上游（`task graph` 看谁堵了谁）；**不要 resume**，下次还会被拒 |
| `PROGRESS_NOT_TICKED` | 需求文档复选框没勾 | 把勾选作为交付物一起提交；`reason` 区分 `doc_missing` / `marker_missing` / `not_ticked` |
| `PROCESS_UNKNOWN` | 进程域无法核对 | `task recover --confirm-stop` 拿到"旧执行已停止"的依据后再决定阶段 |
| `RUN_INTERRUPTED` | 被中断收口 | 先 `task recover`，再按阶段 `resume` |

## rework：换一棵树，不要续跑

| 码 | 含义 | 为什么不能 resume |
|---|---|---|
| `WORKSPACE_CHANGED` | 工作区被任务之外改动 | 候选已经不可信，续跑等于在脏树上继续写 |
| `BASE_DRIFT` | 基线不在目标分支历史里 | worktree 基于一棵被丢弃的树，重冻结基线后重派 |
| `REMOTE_DRIFT` | 远端变了，证据过期 | 已有的"通过过"作废，需要重新验证 |
| `STALE_CHECKS` | 记录的检查结果过期 | 同上，重跑 checks 不是重跑 agent |
| `VALIDATION_FAILED` | 独立检查失败 | 先修实现；直接 resume 会重复同一段失败 |
| `OUTPUT_LIMIT_EXCEEDED` / `PROMPT_TOO_LARGE` | 上下文/输出撑爆 | 拆小任务或收紧 spec，不是重试 |
| `AGENT_FAILED` / `AGENT_RESULT_INVALID` | 执行器失败或输出不合契约 | 读 `last_error` 定位；同一输入重试没有新信息 |
| `ENVIRONMENT_ERROR` / `ENVIRONMENT_DRIFT` / `ADAPTER_VERSION_MISMATCH` | 环境/适配器不匹配 | 修环境（`zoe doctor`），否则下一次还是同一个错 |

## stop：先停项目派发

| 码 | 含义 | 动作 |
|---|---|---|
| `QUOTA_EXHAUSTED` | 账号额度耗尽 | **立即停止新派发**；看 `quota_reset_at`；解除要显式 `project quota clear` |
| `SPEND_LIMIT_EXCEEDED` | 触达花费上限 | 同上；这是项目级事实，不是单任务状态 |
| `SPEND_UNVERIFIABLE` | 花费不可核算 | 停派发，先把计量修好 |

## 不是故障

| 码 | 含义 |
|---|---|
| `CLOSED_EXTERNAL` | 交付在 Zoe 之外发生（`task close-external`）；`accepted:false` 是对账，不是验收结论，不计入 `DONE` |
| `ACCEPTANCE_REJECTED` | 人明确拒收；按拒绝理由改，不要 resume |

## 用法

```bash
# 只看建议（默认）
bash scripts/zoe-auto-recover.sh task-abc123

# 执行 auto 档动作（目前只有 RATE_LIMITED / RUN_TIMEOUT 两类 resume）
bash scripts/zoe-auto-recover.sh task-abc123 --apply
```

脚本的退出码：`0` 有可直接执行的动作 / `1` 需要人工 / `2` 用法或依赖错误。
