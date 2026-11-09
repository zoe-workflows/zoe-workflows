# 任务组交付（v1.3 起，v1.4 补齐设计验收与有界修复）

一个任务组 = 一份**冻结的计划** + 一个**单一推进器**。它把「需求 → 成员 → 串行集成 →
组级检查 → 设计一致性审查 → 一次人工验收」固定成一条链。只支持
`delivery_mode: local_artifact`。

## 什么时候用组，什么时候别用

| 用组 | 别用组（用单任务） |
|---|---|
| 需求要拆成多个成员才能交付，且有明确先后 | 一个 Spec 就能说清 |
| 需要「一次验收」而不是逐个任务验收 | 各任务独立发布、独立验收 |
| 成员之间共享同一份需求语境（同一 design 文档） | 彼此无关的杂项 |
| 需要把「启动次数 / 时长」当预算管 | 一次性小改动 |

组**不**替你判断要不要拆。切片仍然要满足：`allowed_paths` 不重叠、每片能独立说清 AC、
下游依赖已并入基线（见 [decomposition-patterns.md](decomposition-patterns.md)）。组的价值在于
**顺序与集成**，不是"多开几个 Agent 更快"——组内串行执行（v1.3 引入，runtime 1.5.0 复核仍由
`group_serial_execution` 保证），同一时刻只有一个成员在跑。

## 六步流程

```text
1. group plan --project P --request-file plan.json    # 校验 + 路由预演 + 基线快照（不写任何东西）
2. group create --request-file plan.json              # 冻结计划（仍不派发）
3. group start GROUP --request-file start.json        # 起推进器（短命进程）
4. group status GROUP --refresh                       # 有界查询；配合 watch --follow 续游标
5. group review GROUP --request-file review.json      # 设计一致性审查结论（计划要求时必需）
6. group accept GROUP --request-file accept.json      # 一次人工验收
```

第 5 步不是"提交一份好评"：结论由**独立上下文**产出（不是实现该成员的同一个会话），
Runtime 校验它绑定当前 `integration_sha`、覆盖全部必需 AC、且每条证据都能解析到本组记录。
做法与判据见 [design-review-rubric.md](design-review-rubric.md)。

审查出现 `FAIL` 时的闭环（需要有 `budget.max_group_repairs`）：

```text
group repair GROUP --request-file repair.json   # 一条 FAIL finding → 一次有界修复执行
group start GROUP --request-file start.json     # 推进器派发并集成修复单元
group review GROUP --request-file review.json   # 新 integration_sha 必须重新审查
```

没有 `FAIL` finding 的改动**不是**修复，是新增需求：走计划修订（新组 + `follow_up_of`），
`group repair` 会返回 `details.kind=repair_without_finding`。

每一步都可重复执行且幂等（同 `request_id`）。组异常时的动作：

| 现象 | 动作 |
|---|---|
| `SLOT_BUSY` + `details.kind=group_runner` | 已有推进器在跑；用 `status --refresh` 看进度，不要抢 |
| `details.kind=lease_stale` | 旧推进器写被拒；用 `status --refresh` 再 `group start` |
| `group state=BLOCKED` + `INTEGRATION_CONFLICT` | 冲突现场在 `details.conflict_dir`；人工判断后用**新组**继续，不改 `integration_sha` |
| `INTEGRATION_CHECK_FAILED` | 组级检查在集成候选上失败；看 `details.worktree` 里的日志，不跳过检查验收 |
| `INTEGRATION_UNKNOWN` | 分支/记录不一致（含 `intent_ref_moved`）；停下人工核对 |
| `GROUP_BUDGET_EXHAUSTED` | 改计划（`revision+1`）或 `group cancel`；对账/集成/检查/验收仍可用 |
| 需要停下 | `group pause`（drain，等在跑的收尾）或 `--stop`（连成员进程树一起停） |
| 暂停后继续 | `group resume`：重新预检 → 重新对账 → 换新租约；`policy_revision` 变了就是显式接纳新策略 |
| 交付发生在 Zoe 之外 | `group cancel --external`：记 `external_close`，`accepted:false`，**不是验收** |

## 计划字段要点

```json
{
  "schema_version": 2,
  "project_id": "example",
  "title": "订单导出",
  "design_files": ["docs/design/export.md"],
  "base_ref": "main",
  "requirements": [{"id": "REQ-1", "statement": "导出为 CSV"}],
  "members": [
    {
      "task_key": "csv-writer",
      "title": "CSV 写入器",
      "spec_file": "specs/csv-writer.json",
      "depends_on": [],
      "requirement_ids": ["REQ-1"],
      "acceptance_ids": ["AC-1"],
      "expected_paths": ["src/export"],
      "check_ids": ["unit"],
      "task_type": "feature",
      "requested_profile": "cb-approved"
    }
  ],
  "group_checks": ["integration"],
  "budget": {"max_starts": 6, "max_wall_seconds": 7200},
  "authorization_ref": "real-scope-reference"
}
```

- **`task_key`** 是组内稳定标识（不是任务 ID）；`depends_on` 只写 `task_key`。
- **`acceptance_ids`** 必须**完整**映射成员 spec 里的 AC：check 型 AC 的 `check_id` 必须在本成员
  `check_ids` 或 `group_checks` 里；manual 型也必须在 `acceptance_ids` 里显式出现（组的验收
  是唯一判者）。漏映射 = `INPUT_INCOMPLETE`，不留给执行期发现。
- **`requirements`** 每条必须至少被一个成员覆盖，否则 `details.kind=coverage_missing` 并列出
  未覆盖的 ID。这是**结构覆盖**，不等于需求已满足。
- **`expected_paths`** 是规划提示：必须落在项目 `allowed_paths` 的目录边界内
  （`src/export` 不含 `src/exported`）。多个成员声明同一路径只产出提示，**不**自动加依赖边、
  也**不**扩大授权。
- **`budget.max_starts`** 必须显式给正整数，Zoe 不会按成员数推算。它是**计费启动额度**；
  实际 Agent 进程数看每个 run 的 `pid`/`launch_stage`，两个口径不要混着报。
- **`max_wall_seconds`** 是墙钟时长，**包含机器休眠与等待**；它是上限，不是预计工时。
- **`budget.max_group_repairs`** 是组级修复轮数上限，缺省 `0`（不授权修复）。
- **`review`** 决定设计一致性审查是否参与验收，缺省不启用（`group create` 会警告）。
  启用后组不能只凭"检查通过"进入 `REVIEW_READY`。

## 成员任务

推进器为每个成员创建普通任务（`delivery_mode: group_member`）：

- `spec_file` 指向组冻结快照 `groups/<gid>/specs/<task_key>.json`；快照被改动即 `SPEC_CHANGED`。
- 任务记录里有 `consumed_input_sha`：建任务时上游已集成到哪，不是"看起来应该差不多"。
- 成员停在 `REVIEW_READY`。**不要**对成员执行 `task accept`：会返回
  `STATE_CONFLICT`（`details.kind=group_member`），由 `group accept` 统一收口。
- 已集成成员的 `task revise` / `task reassign` / `task rebind` 一律拒绝
  （`details.kind=integrated_member`）：它的产物已经在集成分支里，改它等于改写历史。
  修正走**新组**（`base_ref` 指向上一个 `integration_sha`）。

## 组状态与成员状态

成员状态是**派生**的，不可单独改写：

| 状态 | 含义 |
|---|---|
| `READY` | 依赖都已集成，可派发 |
| `EXECUTING` | 成员任务 RUNNING |
| `VALIDATED` | 任务 `REVIEW_READY` 且 `validated_sha == candidate_sha` |
| `INTEGRATED` | 已合入集成分支（`integrated_sha` 非空且未失效） |
| `WAITING` | 依赖未集成 |
| `BLOCKED` / `CANCELLED` / `PAUSED` / `INVALIDATED` | 需要人或需要重建 |

组状态：`READY → RUNNING → REVIEW_READY → DONE`，异常分支 `BLOCKED` / `PAUSED` /
`CANCELLED`。没有 `DRAFT`：`group plan` 是无状态预览。`group start` 返回
`accepted: true` 但 `completed: false` —— 受理不等于推进。

计划要求审查时，"检查都过了"只到 `RUNNING`，不是 `REVIEW_READY`：

| 审查状态 | 含义 | 组能否 `REVIEW_READY` |
|---|---|---|
| `NOT_REQUIRED` | 计划没声明 `review` | 能（但这一层不参与验收） |
| `NOT_RUN` | 要求了但还没提交 | 不能 |
| `STALE` | 只有更早集成版本的结论 | 不能 |
| `INVALID` | 上次提交被判定无效 | 不能 |
| `FAIL` | 有未解决 finding | 不能；走 `group repair` 或计划修订 |
| `NOT_VERIFIED` | 无 FAIL，但有未验证项 | 能，报告必须逐条列出 |
| `PASS` | 全部必需 AC 通过 | 能 |

修复单元集成后 `integration_sha` 前移，旧的组级检查与审查结论**自动作废**——必须重跑
检查并重新提交审查，不能拿上一版结论收口。

## 谁执行设计一致性审查（本版选定的执行方）

Runtime **不运行审查器**，只校验结论。因此必须存在一个真正的执行方，本版选定：

> **宿主（本会话）在独立上下文中派发一个审查者**——由另一个 Agent 会话或一个显式的
> 审查任务完成，判据与输出契约见 [design-review-rubric.md](design-review-rubric.md)。

这条选择的直接后果，必须如实转述：

- 审查通过、代码与检查都完成后，组会停在 `awaiting_design_review`，`exit_reason` 也是它。
  此时**不得**称为"全流程自动完成"，应写"等待设计审查"。
- 用户关闭会话就等于没有执行方。组会一直停在该状态（不会自行超时、不会由实现 Agent
  自述替代），恢复方式是重新开会话提交 `group review`，或显式改用人工结论。
- 提交前自检五条（缺一条就会被 `EVIDENCE_INVALID` 拒绝，且不会降级成"部分通过"）：
  1. `subject_sha` 等于当前 `integration_sha`，`design_digest` 等于冻结摘要；
  2. 计划要求的每个 AC **出现且只出现一次**；
  3. 每条 `evidence_refs` 可解析（`check:<id>` 必须在当前版本真的 PASS）；
  4. `FAIL` 走 `group repair`，改完旧结论作废、必须重新审查；
  5. 没有执行方时保持阻塞，不拿实现 Agent 的自述当结论。

## 预算与推进的边界

- 预算只门禁**新派发**。耗尽后对账、集成、组级检查、人工验收**照常可用**。
- 推进器不是守护服务，没有定时器：`group start` 返回 `completed: false` 是常态。
  **退出是契约，不是黑盒**——返回值里有 `exit_reason`（`group status` 的
  `lease.exit_reason` 同源）：

  | `exit_reason` | 含义 | 下一步 |
  |---|---|---|
  | `completed` | 已 `DONE` | 收工 |
  | `cancelled` | 已取消 | 不恢复 |
  | `paused` | 已暂停（draining 清空） | 显式 `group resume` |
  | `review_ready` | 检查与审查通过，等人工 | `group accept` |
  | `awaiting_design_review` | 等审查结论 | 提交 `group review` |
  | `review_failed` | 审查有未解决 finding | `group repair`（受 `max_group_repairs`） |
  | `budget_exhausted` | 启动额度用完 | 对账/集成/验收仍可用 |
  | `slots` | 全局槽位被占 | 稍后重新 `group start` |
  | `blocked` | 有阻塞项 | 看 `blockers` 后处置 |
  | `no_progress` | 本轮无可推进 | 重新 `group start` 续跑 |
  | `crashed` | 推进器因未预期错误退出 | 先看日志与 `group status`，不要直接重启 |
  | `lease_stale` | 租约被接管 | 不要再写，重新 `group start` |
  | `safety_cap` | 命中安全上限（兜底） | 续跑，并检查是否有 tick 卡死 |

  判读规则：`stop.resumable` 与 `stop.needs_human` **互斥**。`resumable` 为真表示"推进停止、
  重启推进器就能接着做"，用 `stop.resume_hint` 续跑；`needs_human` 为真
  （`review_ready`/`awaiting_design_review`/`review_failed`/`blocked`/`crashed`）表示重启 runner
  没有意义，hint 给的是 `group review`/`group accept`/`group repair`/`group status --refresh`，
  仍要先拍板或先补审查结论。`crashed` 属于后者：崩溃原因在日志里，直接重启只会在同一个
  tick 上再崩一次。
- 没有自动重试：成员失败就是失败，重试要显式（`group resume` / 新组）。

## 检查分类

每条检查结果带 `error_class`：

| error_class | 含义 | 修复责任 |
|---|---|---|
| `test` | 业务缺陷 | 改代码 |
| `environment` | 环境装不出来（含 126/127 退出码） | 修环境，**不要**重写代码 |
| `timeout` | 超时 | 按 `FAIL` 处理，不视为通过 |
| `policy` | 策略拒绝 | 需要人决定 |

`NOT_RUN` 与"另一个 SHA 的通过记录"都不算通过，不能把组推进到 `REVIEW_READY`。

## 认证态

`agent list` 与组报告里的 `auth_mode` 取 `cli_login` / `api_key` / `unknown`：

- 未声明就是 `unknown`，汇报必须写「认证态未知」，**不得**写「已认证」。
- `login_state=present` 只能由一次成功的 `agent probe` 给出；本机存在配置目录不算证据。
- `api_key` 必须同时声明 `credential_refs`，缺失即 `AUTH_REQUIRED`（注册期与 start 前各判一次）。
  Zoe 只检查环境变量是否存在，不读取、不记录、不回显值。

## 交付边界（必须写进汇报）

- `local-process` **没有沙箱**：Agent 以本机账户运行，`allowed_paths` 提供问责而非预防。
- **审查的状态必须如实转述**：`NOT_REQUIRED` 不等于通过，`NOT_VERIFIED` 不计入成功，
  `STALE` 不能当作"上次通过了"。只有 check 型 AC 的实际执行与**绑定了本次集成版本**的审查
  结论才构成语义证据。
- 审查者是同一个模型也不构成"统计独立"：不得宣称独立性，只能写"独立会话/独立上下文"。
- 不支持 `pull_request` 组：创建时即 `CAPABILITY_UNSUPPORTED`（`kind=group_pr_unsupported`）。
- 修复受 `max_group_repairs` 硬上限约束，不存在"再修一次就好"的无限循环。
