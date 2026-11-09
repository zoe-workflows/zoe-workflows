# 恢复、停止与修订

## 先对账再恢复

通过 status --refresh/reconcile 核对 task_id、Run、phase、进程身份、Spec 版本、工作区和远端。
不使用全局最近 session，不因心跳超时或 PID 文件存在就判断进程生死。

| 已核实情况 | 行动 |
|---|---|
| 旧写者仍活跃 | 观察，不再次 start/resume |
| PROCESS_UNKNOWN | 阻塞新写者，由运行器核对进程域；**拿到"旧执行已停止"的依据后**才 `task recover TASK --confirm-stop` 收口（`--run` 缺省取 `current_run_id`，响应里的 `run_source` 写明来源；`--json` 可直接加），再按下一节决定从哪个阶段 `resume`。`run.status=unknown` 与该 block_code 同时出现是正常组合，不等于实现失败 |
| 尚未实现 | 启动冻结输入 |
| 中断且工作区完整 | workspace 接续；本版本不支持 native |
| session 不可用，工作区完整 | workspace 接续并说明是新会话 |
| 实现完成，验证未完成 | 仅继续 verify |
| VALIDATION_FAILED | 带证据修复，不降低验收标准 |
| QUOTA_EXHAUSTED（额度耗尽） | **停止新派发，不 resume**：合并已完成 → 落 handoff → 交游标；等 `details.quota_reset_at` 后 `project quota clear` 再继续 |
| AGENT_RATE_LIMITED（临时限流） | 退避后 resume；与额度耗尽分开处置，不要用同一条建议 |
| ENVIRONMENT_ERROR | 修环境，不盲目换模型 |
| REMOTE_UNKNOWN / 发布失败 | 查远端 ref/PR，继续 publish，不重跑实现 |
| 仅等待 CI | 查询当前 head，不调用 Worker |
| 等待人工验收 | 汇报证据，等待真实决定 |
| 工作区丢失或损坏 | 检查提交/备份；缺失内容明确阻塞，不保证无损恢复 |
| SCOPE_VIOLATION | **先读 `block_details.scope_source`**：`spec` → `revise-scope.sh`（rebind 无效）；`project` → 改项目范围 + `register` + `rebind`。见下一节 |
| AGENT_FAILED | 兜底码＝"未归因"。先看 `block_details.hint` 与 `agent_evidence.excerpt`，再决定改环境还是改代码。见「`AGENT_FAILED` 的未确认线索」 |

需要换执行器（例如原 Agent 反复失败）时：pause 并确认退出 → `task reassign`
（目标 profile 须满足项目准入策略，工作区/handoff 指纹必须一致）→ resume。
不自动 failover，不在 PROCESS_UNKNOWN 时交接；交接不清零修复预算，旧候选与验证证据失效，
旧 Run 与 assignment 记录保留。

首期修复预算为一次初始实现加最多两次自动实现修复，服从实际更严格配置。
需求歧义、权限与未知进程不进入自动重试；不自动切换供应商或数据域。

## `SCOPE_VIOLATION` 的解法取决于范围来自哪里

`task_scope` 只在 create / revise 时由 `_resolve_task_scope` 重算；`rebind` 只更新
`policy_revision`。所以两件事**不可互换**，换错了不会报错，只会白烧一次付费尝试：

| `block_details.scope_source` | 生效范围来自 | 唯一解法 |
|---|---|---|
| `spec` | spec 的 `allowed_paths`（它已收窄项目授权） | 放宽 spec 的 `allowed_paths` → `task revise`（`scripts/zoe-revise-scope.sh`），**`register` + `rebind` 改不动它** |
| `project` | 项目 `allowed_paths`（spec 未声明该键） | 改项目范围 → `project register` → `task rebind` |
| 任意，`violations[].reason=protected` | — | 不改配置；改实现或换文件（保护路径在交付时胜出） |

`rebind` 的陷阱：它会更新 `policy_revision`，于是"恢复前的闸门"会放行，下一轮必然撞同一个
越界。`spec` 分支下 `resume` 因此会以 `SCOPE_VIOLATION` 直接拒绝（不产生 run、不消耗
attempt），错误里带 `block_details.next_action`——**照它做，不要 cancel 重派**：工作区与
agent 已经写好的内容都还在，`revise` 只改 `allowed_paths` 时会直接进 `verify` 重新判定那棵树，
**不再跑一次 Agent**。

`task revise` 的顺序不能反：spec 的 `allowed_paths` 只能是项目范围的子集。要先扩项目范围并
`rebind`，再 `revise`。`revise-scope.sh preview` 会在 `scope_source != spec`、state 不可修订、
冻结 spec 缺失时直接退出（exit 3，不生成文件）。

## `AGENT_FAILED` 的未确认线索（`block_details.hint`）

`AGENT_FAILED` 仍是"原因未归因"——不要把 `hint` 当成归因，也不要用它替代 `agent_evidence`。
它的用途只有一个：**先修哪一头**。

| `hint` | 人话 | 下一步 |
|---|---|---|
| `model_not_found` | 运行时请求的模型名 CLI 不认识 | 看 `task report` 的 `requested_model`；改 profile 的 `model` → `project register` → `rebind`。不要反复 `resume` |
| `gateway_error` | 上游网关 502/503/504 或连接被重置 | 退避后 `resume`；连续多次才考虑换 profile |
| 无 `hint` | 无共同特征 | 读 `agent_evidence.excerpt` 原文再判断；不要猜 |

额度与限流**不走**这条路径：它们有独立码（`QUOTA_EXHAUSTED` / `AGENT_RATE_LIMITED`），
处置见上一节。

## `PROCESS_UNKNOWN` 之后从哪个阶段继续

`task recover TASK --confirm-stop` 收口后统一是 `BLOCKED` + `block_code=RUN_INTERRUPTED`，
**不能直接 `accept`**：`accept` 的前置是 `state == REVIEW_READY`，且
`subject_sha == validated_sha`、工作区指纹未变。

**收口前先有依据**：`--confirm-stop` 的语义是"我确认旧执行已停止"，不是"我看不到进程"。
可用的依据是 `task status --refresh` 的 `progress.process_state=exited`、`task events` 里该
run 的退出记录、进程树探测为空、写者锁可获得。返回 `PROCESS_UNKNOWN` 且不释放配额时（进程树
`unknown` 或写者锁被占），继续对账，**不要**起第二个写者。

然后按 `phase` 与有效证据决定**本次恢复从哪个阶段开始**（不是"决定是否永不重跑"）：

| 观测 | 判定 | 本次恢复从哪开始 |
|---|---|---|
| `phase=acceptance` 且 `candidate_sha`、`validated_sha` **均非空且相等**，`current_evidence_id` 非空、证据可校验、工作区指纹未变 | 实现与验证都已完成，只差人工验收 | `resume` 直接到 `REVIEW_READY`（不启动 Agent、不耗 attempt）→ 按 delivery-policy 提交 `accept` |
| `phase=publish` / `ci` | 产物已验证，卡在远端或 CI | 先核对远端是否已有提交/PR（`REMOTE_UNKNOWN` 不当作无漂移），再 `resume` 从发布/查 CI 继续 |
| `phase=verify` | 实现完成、验证未完成 | `resume` 从 checks 继续；**检查失败仍可能需要返工**，所以只能说"本次从 verify 开始"，不能承诺之后不再启动 Agent |
| `phase=implement` / `prepare`，或 `candidate_sha` 与 `validated_sha` 任一为空/不等 | 实现未完成或证据已失效 | `resume` 继续实现（消耗一次 attempt） |
| 证据缺失、或阶段与产物互相矛盾（如 `phase=acceptance` 但无证据/指纹不符） | 不能猜 | 先做只读对账（`task report`、`task events`），必要时 `task rebind` 重验或 `task revise` |

两个常见误判：

- **两个空 SHA 不能判等**：`null == null` 不构成"已验证"。
- `resume` 会按**当前**配置重新核对授权确认记录；配置变过会报 `ALLOWLIST_UNCONFIRMED`——
  那是重新确认授权，不是重跑实现，不要因此 `revise` / `reassign`。

## `RUN_TIMEOUT` 之后怎么恢复

超时**不丢代码**，丢的是"上一个 Agent 的理解"。三条事实先对齐：

1. 任务停在**可 resume** 状态，`block_code` 保留 `RUN_TIMEOUT`；该 run 已消耗一次
   attempt（`attempts` 在 spawn **之前**就 +1，`max_attempts` 默认 3）。
2. **工作区还在**：`RUN_TIMEOUT` 不触发隔离（隔离只在闸门失败时发生，例如模型身份或
   费用），未提交改动仍在原 worktree；`resume --strategy workspace` 复用同一个工作区。
3. **提交只发生在 `phase=verify` 且 checks 通过后**：实现阶段不提交，所以"没提交"不等于
   "没干活"。

resume 之前看清三件事：

| 先看什么 | 为什么 | 命令 |
|---|---|---|
| 工作区现状 | 新 run 面对的是"半成品工作区"，必须先核实已有改动，否则会重复劳动或覆盖 | `task status --refresh`（`phase`/`candidate_sha`）、`task handoff show`、`task events` |
| 上次失败记录 | prompt 里带的是上一次的 `last_error`；没有它，新 run 只能靠猜 | `task status --json` 的 `block_details` / `last_error` |
| 预算余量 | 每 resume 一次消耗一次 attempt；连续超时最容易撞 `RETRY_EXHAUSTED` | `task status --json` 的 `attempts` 与任务的 `max_attempts` |

**第二次仍然超时就该改拆分，而不是继续 resume**：`timeout_seconds` 是项目级墙钟上限
（见 [runtime-contract.md](runtime-contract.md)），不存在"给这个任务单独延长"的开关；
把任务切到"能在默认上限内到达可验收点"才是解法。恢复请求本身不要手拼版本号：

```bash
bash <skill-dir>/scripts/zoe-resume.sh preview --project P --task T --reason "RUN_TIMEOUT 后继续"
bash <skill-dir>/scripts/zoe-resume.sh apply --request-file .zoe/P/requests/resume-T-<id>.json
```

恢复同样受准入约束。前两种由脚本在**生成请求之前**拦下（`exit 3`，不产生请求文件）：

- `block_code=PROCESS_UNKNOWN`：不得直接 resume，先对账并 `task recover --confirm-stop`；
- `block_code=INPUT_REQUIRED`：先 `task answer`，否则新 run 会在没有答案的情况下重跑。

第三种**不在预览阶段判**：`POLICY_CHANGED` 由运行时在提交时比对任务冻结摘要得出（脚本
不重复实现策略判定），`apply` 以 `exit 4` 原样报出该 `error.code`。处理方式仍是先
`task rebind`，别拿旧摘要硬推。

## 暂停与取消

pause 后仍为 PAUSING 时不能让人工进场写，也不能启动另一 Worker。
确认所有写者退出后才是 PAUSED；取消后不自动删除工作区、分支或撤销远端成果。
取消过程中远端写操作可能已经完成；未知效果仍需对账。
DONE/CANCELLED 不隐式复活；新工作创建关联任务。

## 额度耗尽（`QUOTA_EXHAUSTED`）

与临时限流分开：限流可以退避，额度只能等重置或换账号。一次额度耗尽会在**项目级**留下
闸门（`project quota show --project P`），之后的 `start`/`resume` 一律被拒且不产生 run——
这是防止"用 resume 试探额度"的机制，不是故障。

触发后的固定顺序：

1. **停止新派发**：已写好的 spec 不派，避免恢复前再撞一次；
2. 合并已完成任务的成果：先核对 `candidate_sha`，不要凭 `REVIEW_READY` 推断已通过；
3. 落收尾快照：`task handoff show TASK --json`（含 `worktree_path` / `run_id` /
   `observation.quiet_seconds` / `quota_gate`），按项目写一份 HANDOFF；
4. 交游标与恢复命令，然后停止轮询；
5. 等 `quota_reset_at`（或换账号）后 `project quota clear --project P --why "..."`，
   再按 `rebind → resume → accept` 继续。

**收尾要在额度还在时增量做**：额度耗尽时模型回合已经不可用，靠"到时候再收尾"等于再依赖
一次同一额度。派发后立即登记台账，每个回合末跑一次 `task digest` / `task handoff show`
（都是本地 CLI，不耗模型额度），耗尽时只是把最后一次结果交出去。

不要为了"尽快结束"用 `resume` 试探额度：要么被闸门拒绝（白跑一次 CLI），要么在闸门尚未
触发时真的启动一个 Agent（白烧一次额度）。

## 成果保留

失败 worktree 原地保留，保存 HEAD、暂存/未暂存改动、未跟踪文件与二进制清单。
只有确认无写者后才能把检查点称为一致；文本 patch 不覆盖全部内容。
handoff 区分核实成果和 Agent 自述，记录未知外部效果；不能把唯一恢复材料删掉。

## 发现 Spec 与现实冲突

执行中发现文档与现实不符（文件已被重构、方案走不通、范围比预想大、依赖行为不一致）：

1. **先停**，不静默绕过。绕过会把偏差留到交付，而且无法对账。
2. 留痕：用 `task summary submit` 记下发现（绑定 `through_event_id`），或在 `task events` 里可查。
3. 判影响，二选一：

| 判定 | 判据 | 行动 |
|---|---|---|
| 绕行 | 目标不变，只换做法或微调范围 | 说清调整 → 用户确认 → `task revise` → `task resume` |
| 根本问题 | 目标本身可能不成立 | 停下，给选项，等方向；不带着旧 Spec 硬推 |

改验收标准一律走 `task revise`；只澄清实现细节走 `task answer`。两者都不做而继续执行，
等于单方面修改合同——合同是用户定的，只有用户可以改。

## 变更与人工修改

先安全暂停，才保存新 Spec；task revise 不覆盖旧冻结输入；完整字段见 cli-contract。
项目策略变化时旧任务被阻塞：人工评估后用 `task rebind` 显式接纳当前策略摘要，
旧验证/验收证据失效并保留历史；不得靠改配置自动迁移旧授权。

### 证据本身不可信（区别于策略变化）

已知场景：`checks` 的命令把 cwd 切回仓库根，验证的是 main 而不是任务 worktree——检查"通过"
但没验过候选。这类任务**不能**用旧 evidence 补 `accept`（`subject_sha == validated_sha`
只说明对象相同，不能说明验过）。

处置顺序：

1. 冻结并登记：任务 id、`candidate_sha`、`validated_sha`、判定（如
   `invalid: check_cwd_pointed_at_main_repo`）。runtime 没有"标记证据无效"的命令，靠人工清单。
2. 修 `checks` → `register` → `doctor` 确认预检为 `ok` → `project attest`。
3. **先做负向验证**：在 worktree 里注入语法错误，确认新 check 会 `FAIL`。没有这一步，
   重验只是换了个看起来对的检查。
4. `task rebind`（`target_policy_hash` 用当前摘要完整值）。产物完整时响应
   `revalidate.pending=true`，任务回 `READY/verify`。
5. `task resume` → 只重跑 checks 并重签证据，**不重跑 Agent**。
6. `task report` 确认新证据来自新 checks（check id、指纹、exit code 都对得上）后，再 `accept`。

走不通时（`revalidate.pending=false` 且 `blockers` 非空；或 `block_code=WORKSPACE_CHANGED`——
worktree 与已签发证据不一致，首次 rebind 也一样；或已发布交付）用 `task close-external`
记账：`claim=verified`（人已核对）/ `asserted`（仅声明），终态 `CANCELLED` +
`block_code=CLOSED_EXTERNAL`、`accepted:false`。**这是对外部交付的对账，不是验收结论**，
不得在报告里写成已验收，也不得用 `task cancel` 代替（后者不记录外部交付事实）。

统计口径：这类任务单列 `external_closed_*` / `evidence_invalid`，**保留在分母里**，
不要为了好看剔出去。
人工接管前确认停写，交回后检测指纹变化并重新验证；旧测试不自动沿用。
若当前部署无 revise 契约，准备修订稿并说明未提交，不能伪造任务已更新。
