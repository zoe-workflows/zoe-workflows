# Zoe CLI 契约

调用面唯一事实源：命令形态、请求字段、响应与错误码。宿主**不解析**命令清单——运行时的
兼容性判断只有 `runtime-requirements.json` 一处（版本/API/协议修订号），命令级别的漂移由
CI 校验。

## 目录

按需跳到对应节，不必顺序读（命令形态在「命令」，请求字段在「创建请求」「变更请求」）：

- 命令 · 能力与准入 · 只读准备（`task prepare`）· 变更影响面（`project diff`）
- 额度耗尽闸门（`project quota`）· 创建请求 · 变更请求 · 执行组合路由
- 任务组交付 · 认证态与检查分类 · 事件、日志与观测 · 结果与错误

## 命令

**所有命令默认输出 JSON**（缩进两空格）。`--json` 只是兼容选项，在除 `doctor` 外的命令上
没有额外效果（`doctor` 不带 `--json` 时输出人读摘要）；`--jsonl` 只对 `watch` 的非 follow
模式有实际作用（一行一个事件而不是一个数组）。示例里不再写 `--json`。

```text
# 只读：注册表能力与项目能力
capabilities
capabilities --check-requirements FILE   # 运行器自检：解析本包的 runtime-requirements.json
demo

# 项目与任务
project register --config project.json [--dry-run]   # --dry-run：只校验，不写状态库与项目配置
project attest --project P [--profiles a,b] [--dry-run] [--expect-policy-hash H] [--expect-profiles a,b]
                                                          # 授权确认记录（绑定配置摘要）；--expect-* 在写入锁内比对
project diff --config project.json [--project P]          # 影响面预览：只读，不写
project quota show --project P                            # v1.6：额度耗尽闸门（只读）
project quota clear --project P --why "..." [--actor A]   # v1.6：显式解除；理由写入记录
project context PROJECT_ID [--task TASK_ID]
task prepare --project P --spec spec.json [--out report.json]      # 只读预检
task prepare --repo PATH --spec spec.json                          # 未注册：匹配或给出草案
task prepare --repo PATH --emit DIR                               # 生成草稿（spec 可省略）
doctor [--project PROJECT_ID] [--agent-profile PROFILE] [--require-ready] [--json]
agent list --project P
agent probe --project P --profile X
task list [--project P] [--fields task_id,state,phase]   # v1.6：字段投影，拼错即 INPUT_INCOMPLETE
task digest --project P [--targets "T1 T2"] [--tail-bytes N] [--lines N] [--no-content]
                                                    # v1.6：一批任务的事实聚合（状态 + 最近内容）
task status TASK [--refresh]
task create --request-file create.json
task start TASK --request-file start.json
task pause TASK --request-file pause.json
task cancel TASK --request-file cancel.json
task resume TASK --request-file resume.json
task revise TASK --request-file revise.json
task reassign TASK --request-file reassign.json
task rebind TASK --request-file rebind.json
task close-external TASK --request-file close-external.json
task answer TASK --request-file answer.json
task accept TASK --request-file accept.json
task review TASK [--request-file review.json]          # v1.7：逐条 AC 判定；无 --request-file 时只读
task coverage --project P --markers-file FILE          # v1.7：需求覆盖账本（只读）
task graph --project P [--format markdown]             # v1.7：依赖图与阻塞点（只读）
task report TASK --format markdown [--write]
task events TASK [--after CURSOR] [--limit N] [--follow] [--timeout 60]
task logs TASK [--run RUN] [--log NAME] [--tail-bytes N]
task logs TASK [--run RUN] [--log NAME] [--after CURSOR] [--tail-bytes N]
task logs TASK [--cursor RUN:GEN:OFF] --follow [--tail-bytes N] [--projection auto|raw|events] [--timeout 60]
task recover TASK [--run RUN] [--confirm-stop] [--json]   # --run 缺省取 current_run_id
task summary submit TASK --request-file summary.json
task summary list TASK
task handoff show TASK

# 任务组：冻结计划 / 单一推进器 / 串行集成 / 组级验收
group plan --project P --request-file plan.json    # 校验 + 路由预演 + 基线快照，不写任何东西
group plan GROUP                                   # 已有组的准入快照（只读）
group create --request-file plan.json                     # 冻结计划，不派发
group start GROUP --request-file start.json               # 起推进器（后台进程，非守护服务）
group dispatch GROUP --item TASK_KEY --request-file dispatch.json
group status GROUP [--refresh]
group report GROUP [--write] [--json]
group pause GROUP --request-file pause.json [--stop]
group resume GROUP --request-file resume.json
group cancel GROUP --request-file cancel.json [--stop]
group cancel GROUP --request-file close-external.json --external
group accept GROUP --request-file accept.json
group review GROUP --request-file review.json            # 提交设计一致性审查结论（v1.4）
group review GROUP                                # 只读：当前审查状态与还差哪些 AC
group repair GROUP --request-file repair.json            # 有界修复：一条 FAIL finding 一次执行（v1.4）

# 旧版有序组（记录顺序 + 单步准入检查；不做 DAG 调度/自动并发），仍可用
# group create --request-file group.json   （载荷带 ordered_items）
# group dispatch GROUP --item ITEM_ID --request-file dispatch.json

# 执行组合路由（v1.2）：预览决策 / 只读统计
route plan --project P [--request-file route.json] [--profile X] [--no-probe]
route stats --project P [--window DAYS] [--write]

# 有界事件查询（epoch 游标）：过滤按 project/group/task 取交集，游标按已扫描范围推进
watch [--project P] [--group G] [--task T] [--after CURSOR] [--timeout 60] [--follow] [--jsonl]

# 资格验证与本机 CLI 取证
qualification run --project P --profile P --fixture DIR --repo REPO --out OUT.json \
  [--timeout 1800] [--stop-after 3] [--replace]
evidence record --qualification QUALIFICATION_FILE

# 编排记录（决策级 CAS，项目级一行）
orchestration claim --project P --as HOST [--force] [--json]
orchestration show --project P
orchestration resume --project P
orchestration update --request-file orchestration.json
orchestration release --project P --as HOST

# 对账：按持久化的进程树事实收口项目内已知 Run（不查远端，可能改变 Run 状态）
reconcile --project P

# 状态库迁移与恢复（停机执行；没有 state backup，迁移会先写 home/backups/ 下的副本）
state restore --from DIR --confirm
state migrate --to 4 [--dry-run]

# 运行器内部入口：由 `task start` / `group start` 派生，宿主不得直接调用。
internal RUN_ID ATTEMPT_ID
internal-group GROUP LEASE_ID
```

`--home PATH` 是全局参数，必须写在命令前。任务派发与变更（create/start/pause/cancel/
resume/revise/reassign/rebind/answer/accept/summary submit、`group`、`orchestration update`）
一律用 `--request-file`，不接受命令行拼装 Spec（避免 shell 转义与 argv 泄漏）；维护类命令
（`state restore`/`state migrate`、`orchestration claim`/`release`、`evidence record`）用显式
参数加 `--confirm` 或 `--force`。

## 能力与准入

`capabilities --json` 按 `(adapter_id, backend)` 返回 `IMPLEMENTED` / `UNVERIFIED` /
`VERIFIED`；`agent list` 返回项目内 profile 的能力态、`expected_version` 与证据来源
（`real_e2e` / `local_admin` / `legacy_admin_declaration`）。

- **准入由项目配置决定**：默认 `require_real_e2e: false` —— 未验证执行器**可以**派发，但
  `start` 响应、run 记录、事件与 `task report` 必须带 `unverified: true` /
  `trust_level: unverified`，首个派发事件为 `unverified_dispatch`；设 `true` 时缺真实 e2e
  记录则 `start` 返回 `ADAPTER_UNVERIFIED` / `ADAPTER_VERSION_MISMATCH`，不“近似兼容”地退回。
- `doctor` 把两件事分开：`ready`（环境可执行）与 `trusted`（该 backend 有真实 e2e 记录）。
- 一个 backend 的证据不能用于另一个（`ADAPTER_BACKEND_MISMATCH`）。
- `agent probe` 只做有界 `--version` 探测，不产生模型调用，也不升级能力态；探测对象与
  `start` 启动的是**同一个**二进制（`argv[0]` 固定为解析出的绝对路径）。
- 执行后端只有 `local-process`；`backend: docker` 的配置被显式拒绝
  （`CAPABILITY_UNSUPPORTED`，退出码 4，`error.details.migration` 给改法），不改写成本机执行。
  `capabilities.not_supported` 含 `container_execution`。
- **并发**：`max_active_tasks` 限制同时活跃的 Run；单任务唯一写者不变量不变，超限返回
  `SLOT_BUSY`（message 列出占用任务）。三个口径不要混成一句口号：

| 口径 | 取值 |
|---|---|
| `max_active_tasks` 取值范围 | `1..8`（默认 1，上限常量 `MAX_ACTIVE_TASKS`） |
| 活跃计数作用域 | `global`（同一 `ZOE_HOME` 下所有项目一起计数） |
| 限额来源 | `project_config`（取派发项目自身的 `max_active_tasks`） |

  `capabilities.concurrency` 给出同样三个事实；`orchestration resume` 与 `group plan` 的
  `slots`（`limit` / `active_global` / `free` / `active_tasks`）只是**快照**，不是准入许可：
  真正的判定在 `start` 临界区内完成，两次相同快照仍可能一次成功一次 `SLOT_BUSY`。
  `quota_gate`（v1.6）非 `null` 表示项目级额度闸门正生效：此时 `start`/`resume` 一律以
  `QUOTA_EXHAUSTED` 拒绝，快照里 `slots` 还有空位也不代表能派发。同一条快照里
  `dispatchable_now[].action` 会给出 `project quota clear`（而不是 `task resume`）。
- **观测能力面**（v1.5）：`capabilities.observation` 声明本版真正支持的观测行为与语义版本
  （`event_filter` / `logs_follow` / `logs_cursor` / `progress` / `checks_preflight` 等）。
  它是**能力面**而不是命令清单：参数存在不等于行为实现（`watch --project` 曾经被接收却不生效），
  所以宿主判断"能不能依赖某个行为"要看这里，不要靠 `--help` 里有这个 flag。
- **重复请求**：同 `request_id`（且 action、载荷一致）不派发第二次。已完成的操作返回原记录
  （逐字节一致）；仍停留在派发意图的返回
  `{"status": "accepted", "completed": false, "dispatch_pending": true, "run_id": null, "task_snapshot": {...}}`，
  顶层**不**提供 `row_version`。同 `request_id` 换 action 或载荷一律 `REQUEST_CONFLICT`。
- **写者被占用**：不同 `request_id` 返回 `TASK_BUSY`，`error.details` 含 `task_id` / `state` /
  `phase` / `run_id` / `dispatch_state` / `hint`（只读快照，据此决定是否 `status --refresh`，
  不要盲目重试）。
- `task report --format markdown` 输出交付视图（验收项结论、check 明细、阻断、交付边界）；
  `--write` 另存 `delivery-<spec_revision>.md` 并只返回 `{"report_path", ...}`。

## 逐条 AC 判定（`task review` / `task coverage`，v1.7）

v1.6 及以前，"验收"是两个粒度不同的东西：check 有逐条 exit code，而 `accept` 只有一个整体
`decision`。manual AC 因此只能渲染成 `未记录逐项人工结论`——一句诚实的空白，也是一次货真价实的
漏验。v1.7 补上第二层：**每条 AC 一条结论，绑定一个候选版本，判者不能是实现者**。

### spec v3（`schema_version: 3`）

v2 仍然合法（行为不变）。四个新字段只在 v3 被读取；**把它们写进 v2 会直接 `INPUT_INCOMPLETE`**，
不会静默忽略。

```json
{
  "schema_version": 3,
  "acceptance_criteria": [
    {"id": "AC-1", "statement": "...", "verification": {"type": "check", "check_id": "unit"}},
    {"id": "AC-2", "statement": "...", "verification": {
      "type": "manual",
      "judge": "independent",
      "supporting_checks": ["ac-r10-golden"],
      "instructions": "谁判、依据哪条证据判"
    }}
  ],
  "acceptance_review": {"required": true, "mode": "either", "independent": true},
  "decisions": [
    {"id": "D-2", "question": "...", "options": ["A", "B"], "recommendation": "A",
     "status": "open", "resolved_by": null, "resolution": null}
  ],
  "progress_refs": [
    {"acceptance_id": "AC-2", "doc": "docs/plan.md", "marker": "R-14"}
  ]
}
```

| 字段 | 规则 |
|---|---|
| `verification.judge` | v3 的 manual 项必填：`independent` / `owner` / `human`。没有判者的 manual 项必然退化成空白 |
| `verification.supporting_checks` | 只能引用**项目已批准的 check**（不给 spec 内联 shell 命令的机会）；它只提供机器证据，**不构成通过** |
| `acceptance_review` | `required=true` 时 accept 必须有绑定 `validated_sha` 的 `task review`；`independent=true` 时还会比对判者身份 |
| `decisions` | `status=open` 不阻断 create，**阻断 accept**（`DECISIONS_OPEN`）；`resolved` 必须有 `resolved_by` 与 `resolution` |
| `progress_refs` | `doc` 必须在 `allowed_paths` 内（否则 prepare 报 `PROGRESS_REF_OUT_OF_SCOPE`，阻断）；verify 阶段检查该 marker 所在行已是 `- [x]`，否则 `PROGRESS_NOT_TICKED` |
| `depends_on` | 上游 marker 列表。`start` 要求上游 `DONE` + `accepted` + 逐条判定满足，否则 `DEPENDENCY_NOT_MET`（5）。不能包含本任务自己认领的 marker（自依赖在契约层拒绝） |

`prepare` 对验收形状另给 `advice[]`（不进 `diagnostics`、不影响 `prepared`）：
`AC_SINGLE_ITEM`（只有一条 AC）、`AC_SINGLE_SIGNAL`（全部 AC 指向同一个 check）、
`REVIEW_NOT_INDEPENDENT`（要求判定但不要求独立上下文）、`DECISIONS_OPEN`。

### `task review`

```json
// review.json
{
  "schema_version": 1,
  "request_id": "review-r14-1",
  "actor": "alice",
  "subject_sha": "<task.validated_sha>",
  "reviewer": {"kind": "agent", "profile_id": "reviewer", "independent_context": true},
  "items": [
    {"acceptance_id": "AC-1", "status": "PASS", "evidence_refs": ["check:unit"]},
    {"acceptance_id": "AC-2", "status": "PASS", "evidence_refs": ["check:ac-r10-golden", "doc:docs/plan.md"]},
    {"acceptance_id": "AC-3", "status": "NOT_VERIFIED", "finding": "无独立环境复现"}
  ]
}
```

| 规则 | 说明 |
|---|---|
| 绑定 | `subject_sha` 必须等于 `validated_sha`；换候选，旧结论文件名即失效（按 SHA 落盘） |
| 全覆盖 | spec 里每个 AC 出现且只出现一次；漏项 = 无效输出，整份拒绝 |
| 三态 | `PASS` / `FAIL` / `NOT_VERIFIED`，没有"跳过"；后两者必须写 `finding` |
| 证据 | `check:<id>`（本候选 PASS）、`evidence:<id>`（必须是当前 `current_evidence_id`）、`doc:<path>`（候选树里存在）、`decision:<id>`（spec 声明的裁定） |
| 独立性 | `independent=true` 时：`reviewer.independent_context` 必须为 `true`，且 `profile_id` / `run_id` / `actor` 任一等于产出该候选的执行者即 `EVIDENCE_INVALID`（`SELF_REVIEW`） |
| 非法输出 | 落档 `status=invalid` 后返回 `EVIDENCE_INVALID`；它**不会**变成一次通过 |

无 `--request-file` 时是只读查询，返回 `state` / `verdict` / `counts` / `unresolved` /
`not_verified` / `required_acceptance_ids` / `path`。

### accept 门禁（v1.7 新增三步）

| 顺序 | 条件 | 失败码 |
|---|---|---|
| 1 | `decisions` 里没有 `status=open` | `DECISIONS_OPEN`（5） |
| 2 | 声明 `acceptance_review.required` 时，存在绑定当前 `validated_sha` 的结论，且无 `FAIL` | `ACCEPTANCE_UNREVIEWED`（3）/ `ACCEPTANCE_REVIEW_FAILED`（5） |
| 3 | 有 `NOT_VERIFIED` 项时，请求里 `acknowledged_not_verified` 必须与它**逐条完全一致** | `ACCEPTANCE_UNACKNOWLEDGED`（3） |

`NOT_VERIFIED` 不阻断，但必须被显式确认：默认放行等于把"没判"和"判过了"合并成同一个结果。
验收通过的 `acceptance.json` 里会带 `review`（verdict / subject_sha / counts / reviewer / path）。

### `task coverage`（需求覆盖账本）

```
zoe task coverage --project P --markers-file .zoe/requirements.txt [--format markdown]
```

输入每行一个 marker（`R-01`、`D-3`…，`#` 开头为注释）。默认输出 JSON；
`--format markdown` 输出可贴进汇报的账本（含未闭环逐条清单）。输出五桶：

| 桶 | 判据 |
|---|---|
| `covered` | `state=DONE` **且** `acceptance.decision=accepted` **且**（若声明）逐条判定满足 |
| `pending` | 有任务认领但未满足上面三条（**`REVIEW_READY` 一律算 pending**） |
| `missing` | 没有任何任务声明该 marker |
| `duplicate` | ≥2 个任务声明同一 marker（拆分口径不一致） |
| `unmapped` | 任务有结构化 spec 但没有 `progress_refs`（无法进账本） |

`cleared` 是**唯一**可以被读成「清单清零」的字段：`not missing and not pending`。不要用
"任务都合并了""测试都绿了"替代它。

### `task graph`（依赖图）

```
zoe task graph --project P [--format markdown]
```

节点是任务，边是 `depends_on` 的 marker → 认领它的任务。判定与 `start` 门禁**同源**
（`_coverage.dependency_state`），所以图里"不阻塞"等于"派得出去"，不会出现
"图说没问题、start 被拒"。

输出四段：`nodes`（state / acceptance / markers / depends_on）、`edges`
（`satisfied` 逐条给出）、`blocked`（`reason` 为 `no_task_claims_marker` 或
`upstream_not_closed`）、`cycles`（任务级环，自依赖已在契约层拒绝）。

`ready` 等于"没有阻塞点"。它只说明依赖满足，**不说明可以验收**——那是 `task report`
与 `task review` 的事。

## 只读准备（`task prepare`，v1.6）

一次看完「能不能建任务」的全部可静态判断项；不建任务、不碰状态库。

| 操作 | 读 | 写 | 幂等 |
|---|---|---|---|
| 默认（预检） | 项目配置、spec、仓库 | 无 | 是 |
| `--out FILE` | 同上 | 该报告；已存在且无 `--force` 时报 `STATE_CONFLICT` | 稳定字段相同 |
| `--emit DIR` | 同上（可不给 `--spec`） | `spec.json` + `create.json`；已存在**保留** | 是（`request_id` 沿用原值） |

`--out` 与 `--emit` 互斥。关键字段：`prepared`（**本次快照下**的结论）、`snapshot`
（`policy_hash` / `base_sha` / `checks_preflight` 计数 / `static_checks_done` /
`static_checks_skipped`）、`diagnostics[]`（`code` / `field` / `reason` /
`suggested_change` / `requires_approval` / `source`）、`profile`（将使用的 profile 与
model；预检不调用模型、不切换模型）。

`prepared: true` **不保证**随后启动一定成功：create/start 用同一套校验复核，配置、仓库或
环境发生变化时返回明确诊断。没有上次报告输入时**不输出** `changes`（无法定义"变化"）。

两个与"验证到底验了什么"相关的诊断码（v1.5.3）：

| code | 位置 | 阻断 `prepared` | 含义 |
|---|---|---|---|
| `CHECK_ESCAPES_WORKSPACE` | `diagnostics[]` | 是 | 某个 check 把工作目录钉到了别处（`cd /abs`、`git -C /abs`、`--cwd=/abs`）。checks 的 cwd 已经是任务 worktree，再钉一次只会**验证另一棵树**，而 exit code 仍被记到这个候选名下 |
| `SCOPE_DIRECTORY_LEVEL` | `allowed_paths.warnings[]` | 否（告警） | spec 声明的范围里有目录级条目：Worker 可以在该目录下任意改文件。串行任务合法，并行批次里等于没有边界 |

`CHECK_ESCAPES_WORKSPACE` 的改法是把绝对 `cd` 去掉、只用仓库相对参数（`./run-tests.sh`、
`go test ./...`）；`cd "$VAR"` 这类不含绝对路径的写法不会命中。

草稿里的 `<FILL:...>` 是刻意留下的：create 会拒绝任何仍含占位符的字符串字段（`title`、
AC `statement`、`instructions`、`allowed_paths` 条目），避免未填完的草稿进入执行。

## 变更影响面（`project diff`，v1.6）

改配置前先问「会炸到谁」。只读，输出：

| 字段 | 含义 |
|---|---|
| `changed_fields` | 字段级差异（`checks[unit].argv`、`agent_profiles[cb].model`）；按 id 配对，重排不算变化 |
| `policy_hash` / `policy_revision` | `new_policy_hash` **完整值即 `rebind.target_policy_hash`**；`policy_revision` 是前 16 位，只用于记录与比对 |
| `affected_tasks[]` | 同项目且 `READY/PAUSED/BLOCKED/RUNNING` 的任务；`rebind_required` 由记录里的 `policy_revision` 判定 |
| `spec_valid_under_new_policy` | 调用的就是 `rebind` 自己的 `validate_spec_text`：为 `false` 时**直接 rebind 一定被拒**，必须先 `task revise`；`null` 表示找不到冻结快照 |
| `suggested_commands[]` | 逐条替身命令，**不批量执行**；`RUNNING` 的任务不产出命令，`note` 提示先 pause |

不提供 `--all`：`rebind` 的语义是人工显式接纳新策略、旧证据失效，一次误操作不可逆。

## 配置来源（`doctor.config_source`，v1.6）

运行器**只读** `<home>/projects/<id>.json`（`project register` 的落盘副本），磁盘上的
`project.json` 从此不再被读。于是"改了配置文件、没重新注册"完全静默：`doctor` 照常
`ready`、派发照常用旧值。这个字段把那条静默链路变成可读的：

| 字段 | 含义 |
|---|---|
| `recorded` | 是否有来源记录（`register` 时写下；老项目可能没有） |
| `source` | 注册时读的**绝对路径** |
| `registered_at` | 注册时刻 |
| `source_exists` | 该文件现在还在不在 |
| `changed` | `true` 文件已变（需重新 register）/ `false` 一致 / `null` **无法判定** |
| `changed_fields` | 变了的顶层键（`allowed_paths`、`agent_profiles`…），最多 20 个 |
| `reason` | `same` / `changed` / `not_recorded` / `source_missing` / `source_unreadable` / `record_unreadable` |
| `hint` | 仅 `changed=true` 时给一句人话 + 该跑的命令 |

三条纪律：

- **`changed=null` 不是"没变化"**：没有记录、文件被移走、读不懂，都答不了这个问题；
- 它**不参与 `ready`**：注册副本才是权威，提示只负责让"改完没重新注册"可见；
- 记录落在 `projects/<id>.source.json` 这个**旁挂文件**，不进项目配置——写进配置会改变
  `policy_digest`，让在途任务全部 `POLICY_CHANGED`（与 `quota.json` 同一理由）。

由此还得出 model 的一句话结论：profile 声明了 `model` ⇒ 运行时**必传** `--model`，
CLI 自己的 `settings.json` 默认模型不参与；没声明 ⇒ 运行时**不传**，模型由 CLI 决定。
两种情况下"改 `settings.json` 期待生效"都各自错在不同位置，用 `doctor.config_source` +
`task report` 的 `requested_model` 判，不要靠 `resume` 试。

## 额度耗尽闸门（`project quota`，v1.6）

额度耗尽与临时限流是两件事，处置相反：

| 信号 | 判据 | 处置 |
|---|---|---|
| 临时限流 | `429` / `rate limit` / `overloaded`，且没有额度词、也没有重置时刻 | 退避后 `resume` |
| 额度耗尽 | 额度词（`quota` / `usage limit` / `使用量` / `额度` / `配额`），或"将在 … 重置" | **停止派发**，等重置或换账号 |

一次 `QUOTA_EXHAUSTED` 触发的是**项目级**闸门，不是单任务阻塞：并发任务撞的是同一个
账号额度池，只标当前任务会让其余任务继续消耗。闸门存在
`<home>/projects/<id>.quota.json`，**不进项目配置**——写进配置会改变 `policy_digest`，
让在途任务全部 `POLICY_CHANGED`，一次额度事故不该顺带触发一次策略迁移。

`project quota show --project P` 只读：`blocking` 回答"现在能不能派发"，`gate` 给证据
（`task_id` / `run_id` / `reset_at` / 原文一行）。`clear` 是**人的决定**，不是时钟推断：
`reset_at` 过了也不会自动放行——那个时刻可能来自另一个时区、另一个账号，或者根本没给
（只有 `retry after`）。`clear` 保留事故记录，只追加 `cleared_at` / `cleared_by` /
`cleared_reason`；没有事故时 `clear` 不写任何文件（不凭空造一条"曾经耗尽"）。

恢复顺序固定，不要跳步：**停新派发 → 合并已完成 → 落 handoff → 交游标 → 等 reset →
`project quota clear` → `rebind`/`resume`**。在 reset 之前 `resume` 只会把一次真实尝试
花在同一个空池上；闸门会直接拒绝（exit 4，不产生 run）。

`AGENT_FAILED` 与它无关但常被混淆：兜底码只说明"原因未归因"。先读 run 的
`result_schema`（`exit-code-only` 表示降级）与 `agent_evidence.excerpt`，再决定改什么。

## 创建请求

```json
{
  "schema_version": 2,
  "request_id": "unique-create-request",
  "project_id": "example",
  "title": "功能标题",
  "spec_file": "/private/spec.json",
  "agent_profile": "cb-approved",
  "delivery_mode": "local_artifact",
  "authorization_ref": "real-scope-reference",
  "source": {"host": "workbuddy", "conversation_ref": "msg42"}
}
```

`spec_file` 可为结构化 `spec.json`（`schema_version: 2`：唯一 AC ID、
`verification.type=check|manual` 且 `check_id` 必须存在于批准 checks、阻塞性 open_questions
必须先解决、`allowed_paths` 只能收紧）或旧 Markdown（需含 `AC-`）。骨架见 `spec-template.md`。

结构化 spec 可声明 `verification_scope`：

```json
{"verification_scope": {"checks": ["lint", "slice_a"]}}
```

- 键缺省 = 跑全部 checks；声明后未列入的 check 记为 `NOT_RUN`，不执行、不算通过。
- `checks` 必须非空、元素为已登记 check id、且覆盖所有 AC 引用的 `check_id`，否则
  `INPUT_INCOMPLETE`（create/revise 时即拒绝，不留到验证阶段）。
- 冻结时 `spec-<rev>.json` 写入 `verification_semantics`（1=全量，2=范围）；
  0.5.0 及更早冻结的版本没有该字段，一律按全量执行，不解释其文本里的范围。

`delivery_mode` 另可为 `pull_request`，以及 v1.3 的 `group_member`（组成员：不发布、不自验收，
停在 `REVIEW_READY` 等组统一集成，`task accept` 会拒绝）。组成员请求必带 `group_id` + `item_id`，
`spec_file` 指向组冻结快照 `groups/<gid>/specs/<task_key>.json`，其文本摘要必须等于计划里记录的
`spec_sha256`（不一致返回 `SPEC_CHANGED`），任务记录另存 `consumed_input_sha`
（建任务时上游已集成到哪）。项目的 `authorized_actions` 控制 create/execute/publish/accept。
带 `group_id` 时必须在同一事务绑定未被占用的 item；一个成员只能绑定一个任务。
v3 组的 `group_id` **只接受** `delivery_mode=group_member`（否则 `INPUT_INCOMPLETE`）：否则成员会
绕过冻结 spec 校验，而 `task accept` 的自验收拦截按 `delivery_mode` 判断，拦不住它。legacy
ordered 组沿用 item 绑定语义，不受此约束。

### `route` 块（可选，要求项目 `routing.mode=auto`）

`route` 是可选块，**要求项目 `routing.mode` 为 `auto`**；`explicit` 项目里出现 `route` 会以
`INPUT_INCOMPLETE` 拒绝（不静默忽略）。所以它不能进最小示例
（[create-request.example.json](create-request.example.json) 是 `explicit` 项目），模板见
[create-request.routed.example.json](create-request.routed.example.json)。

| 字段 | 作用 |
|---|---|
| `route.task_type` | 匹配 `routing.rules[].task_type` 的 `prefer` 列表；取值 `bugfix`/`feature`/`refactor`/`test`/`docs`/`chore`/`review`/`unknown`/`*` |
| `route.requirements` | L1 硬条件：`context_budget` / `needs_tool_use` / `structured_result` / `input_modalities` / `data_residency` / `min_capability` / `permission_profile_in` / `non_interactive` / `structured_input` / `session_resume` / `pin_model` |

`task_type` 的取值顺序：`route.task_type` > spec 文档的 `task_type` > `unknown`。未命中任何
`rules` 项时走 `routing.fallback`（`ask` 给选项，`default_profile` 用默认），没有"按白名单
顺序自动挑一个"。

`route plan` **不读 spec 文件**：`task_type` 只写在 spec 里时，预演按 `unknown` 匹配而 create
按 spec 匹配。要预演准，就把 `task_type` 写进请求。两处共用同一个 `decide()`，但**有效输入、
配置与环境快照相同时才给出相同结果**；预演通过也不等于 create 会成功（还不校验 spec 合法性
与授权确认记录）。

## 变更请求

```json
{
  "schema_version": 2,
  "request_id": "unique-operation-request",
  "expected_version": 8,
  "reason": "继续未完成阶段",
  "authorization_ref": "real-scope-reference"
}
```

`request_id` 用字母、数字、下划线和连字符；`expected_version` 来自最新 `row_version`。
相同 ID 同内容返回原结果，不同内容冲突；请求超时先查任务，不换 ID 盲目重做。

下表只是**动作专属字段**。所有 `schema_version: 2` 的变更请求（resume / revise / reassign /
rebind / accept / close-external / answer / summary submit）都还必须带
`schema_version` / `request_id` / `expected_version` / `authorization_ref` / `reason` 五要素，
缺任一即 `INPUT_INCOMPLETE: Request requires <key>`。`authorization_ref` 必须与项目配置里的值
**逐字相等**，否则 `AUTH_REQUIRED: Authorization reference mismatch`；这两条对 `accept` 同样成立，
"验收不需要授权"是误读。

| 动作 | 附加字段与约束 |
|---|---|
| resume | `strategy: auto/workspace`；`native` 当前拒绝 |
| revise | `spec_file`；先停写后提交，旧验收与验证失效 |
| reassign | `target_profile`；仅 READY/PAUSED/BLOCKED、无活跃或未知写者、阶段为 prepare/implement/verify；目标准入与 `start` 同策略；工作区/handoff 指纹不一致返回 `HANDOFF_STALE`；预算不清零，旧证据归档失效 |
| rebind | `target_policy_hash`（须等于当前项目策略摘要）；显式接纳新策略，旧证据失效、历史保留。`local_artifact` 且产物身份未变、无活跃写者时，响应 `revalidate.pending=true`，任务回到 `READY/verify`：`resume` 只重跑 checks 并重签证据，**不重跑 Agent**；否则 `revalidate.blockers` 说明不可重验的原因（已发布交付 / 写者未收口 / 产物已漂移），状态保持不变 |
| accept | `decision: accepted/rejected`、`actor`、`subject_sha`（须为 `validated_sha`）、非空 `evidence`；`actor` 必须来自真实用户决定，程序不替宿主验证人类身份；拒绝验收回到实现修复，已合并代码不自动撤销 |
| close-external | `external_ref`、`actor`、`claim: verified/asserted`，可选 `merged_sha`；**仅**在没有活跃 run、`block_code != PROCESS_UNKNOWN` 时可用。进入 `CANCELLED` + `block_code=CLOSED_EXTERNAL`，响应固定 `accepted: false`：这是"交付在 Zoe 之外发生"的对账，**不是验收结论**，不计入 `DONE`。`claim=verified` 表示人已核对，`asserted` 表示仅用户声明 |
| answer | `question_id`、`answer`、`answered_by`（`user`/`spec`，`spec` 须给 `answer_ref`）；只解除 `BLOCKED/INPUT_REQUIRED`，保留重试预算，**不自行续跑** |

`task answer` 澄清后用 `task resume` 继续；改验收标准必须 `task revise`（Spec 版本 +1）。
问题未回答就 `resume` 会被拒绝（`STATE_CONFLICT`），避免 Agent 在无答案时重跑。

`answer` 要写到 Worker 不用再问：结论 + 适用范围 + 不在范围内的部分。答案若改变了 AC 或
`allowed_paths`，走 `task revise`，不要塞进 `answer`。

项目被 `orchestration claim` 占用后，`start`/`resume`/`revise`/`reassign`/`task answer`
都要求 `owner.host`（或 `by`）等于当前 owner，否则 `NOT_OWNER` 且状态不变。未 claim 的项目
对任何宿主开放。

## 执行组合路由（v1.2）

「组合」= 适配器 + backend + CLI 版本 + provider/model/variant/reasoning_effort + 权限/工具 + 端点。
`combination_id` 形如 `cmb-<16 hex>`，可复现且不含绝对路径/凭据；`route_id` 只是关联标识，
**不**承担防篡改职责，完整性靠 `route-<rev>.json` 的 `content_sha256`。

- `route plan` 是**预览**：不建任务、不写决策文件、不发事件；它和 `task create` 调同一个决策
  函数，但**不读 spec 文件**——准确表述是"同一决策函数，在有效输入、配置与环境快照相同时才
  给出相同结果"。`task_type` 只写在 spec 里时，预演按 `unknown` 匹配而 create 按 spec 匹配，
  这就是"预览通过、实际选了别人"的最常见来源。默认会解析并探测本机 CLI 版本，`--no-probe`
  可关闭（此时版本记为未探测，不猜测）。
- 决策三层分账：L1 硬能力（声明 + 机械校验）、L2 集成事实（本机能否跑）、L3 任务表现
  （**只记录，不参与选择**）。`layers` 只有 `l1_excluded`/`l2_excluded`，没有 `l3_excluded`。
- 显式指定只把候选收窄为 1 个，不跳过 L1/L2；失败时报该候选的具体排除码，**不回落**到别的 profile。
- `route stats` 只读聚合（`combination_id × task_type × spec_scale`），固定 `as_of`；默认不写文件，
  `--write` 才落盘。它永远是 `used_for_selection=false`。

## 任务组交付（v1.3 起，v1.4 补齐设计验收与有界修复）

任务组 = 一份**冻结的计划** + 一个**单一推进器**。它把"需求 → 成员 → 串行集成 → 组级检查 →
设计一致性审查 → 一次人工验收"这条链固定下来，只支持 `delivery_mode: local_artifact`。

- **计划与运行分离**：`runtime`（任务绑定、集成 SHA、租约、预算计数、检查结果）任何变化都**不**
  改变 `plan_digest`。计划身份只由 base、design 清单、需求、成员 spec 摘要、组级检查与预算上限
  决定。改计划 = `revision+1` 加新计划文件，旧计划保留。
- **状态是派生的**：成员状态（`INTEGRATED / INVALIDATED / BLOCKED / CANCELLED / PAUSED /
  VALIDATED / EXECUTING / READY / WAITING`）由任务状态 + 绑定 + SHA 推导，没有可被单独改写的
  "成员状态"字段。组状态（`READY / RUNNING / BLOCKED / PAUSED / REVIEW_READY / DONE /
  CANCELLED`）同理，`DRAFT` 不存在：`group plan` 是无状态预览。
- **不是守护服务**：`group start` 起一个短命进程并把租约（`lease_id` + `pid` + `start_token`）
  写进记录后立即返回。进程退出即停止推进；再次 `group start` 会换新租约，旧推进器的写入因
  `lease_stale` 被拒。
- **串行**：准入取 `min(组内空闲, 全局空闲)`，一个组同一时刻只有一个成员在执行。`group dispatch`
  与推进器走**同一个**准入函数，不能绕过排队、预算与策略。
- **预算只门禁派发**：`max_starts` 是**计费启动额度**，与实际 Agent 进程数不是一个口径
  （进程数看每个 run 的 `pid`/`launch_stage`）。未产生 Agent 进程的启动会释放并记入
  `release_basis`。`max_wall_seconds` 是墙钟时长，**包含机器休眠与等待**。预算耗尽后对账、集成、
  组级检查、人工验收**继续可用**。
- **组级检查绑定 SHA**：检查结果按 `subject_sha` 记录。`NOT_RUN` 与"另一个 SHA 的通过记录"
  都不算通过，因此不能把组推进到 `REVIEW_READY`。`group accept` 会重算集成工作区指纹，
  指纹不符即拒绝。
- **验收只有一次**：成员任务停在 `REVIEW_READY`，由 `group accept` 统一收口；对成员执行
  `task accept` 返回 `STATE_CONFLICT`（`details.kind=group_member`）。已集成成员的
  `task revise/reassign/rebind` 一律拒绝（`details.kind=integrated_member`），修正走**新组**。
- **设计一致性审查（v1.4）**：由宿主在**独立上下文**产出结论，`group review` 只提交、不生产。
  校验三条硬规则——`subject_sha` 必须等于当前 `integration_sha`、`design_digest` 必须等于冻结
  设计摘要、计划里每个必需 AC 必须出现且只出现一次；`evidence_refs` 必须解析到本组真实记录
  （`check:<id>` / `group:<sha>` / `task:<id>`）。不合法即 `EVIDENCE_INVALID`
  （`details.kind=review_invalid`），**留档为 `invalid` 且不算通过**。
  计划用 `review.required` 决定它是否参与验收：缺省（不写这段）等于 v1.3 行为（只有结构覆盖 +
  组级检查），`group create` 会在 `warnings` 里明确说明。
- **有界修复（v1.4）**：`group repair` 必须有当前版本审查里的 `FAIL` finding 才会执行，一次
  只对应一条 finding，受 `budget.max_group_repairs` 约束（缺省 0 = 不授权）。没有 finding 的
  改动是**新增需求**，走计划修订（`details.kind=repair_without_finding`）。修复完成后集成版本
  前移，旧的组级检查与审查结论自动作废，必须重跑并重新提交审查。

```json
// plan.json（group plan / group create）
{
  "schema_version": 2,
  "request_id": "unique-plan-request",
  "project_id": "example",
  "title": "订单导出",
  "design_files": ["docs/design/export.md"],
  "base_ref": "main",
  "delivery_mode": "local_artifact",
  "requirements": [{"id": "REQ-1", "statement": "导出为 CSV"}],
  "members": [
    {
      "task_key": "csv-writer",
      "title": "CSV 写入器",
      "spec_file": "specs/csv-writer.json",
      "depends_on": [],
      "requirement_ids": ["REQ-1"],
      "acceptance_ids": ["AC-1", "AC-2"],
      "expected_paths": ["src/export"],
      "check_ids": ["unit"],
      "task_type": "feature",
      "requested_profile": "cb-approved"
    }
  ],
  "group_checks": ["integration"],
  "budget": {"max_starts": 6, "max_wall_seconds": 7200, "max_group_repairs": 2},
  "review": {"required": true, "mode": "agent"},
  "authorization_ref": "real-scope-reference"
}
```

```json
// review.json（group review）—— 审查者产出，宿主原样提交
{
  "request_id": "review-1",
  "actor": "workbuddy",
  "authorization_ref": "real-scope-reference",
  "review": {
    "schema_version": 1,
    "subject_sha": "<当前 integration_sha>",
    "design_digest": "<冻结设计摘要>",
    "reviewer": {"kind": "agent", "independent_context": true},
    "items": [
      {
        "acceptance_id": "AC-1",
        "status": "PASS",
        "finding": null,
        "locations": ["src/export/csv.py"],
        "evidence_refs": ["check:integration"]
      },
      {
        "acceptance_id": "AC-2",
        "status": "FAIL",
        "finding": "普通用户仍可调用导出接口",
        "locations": ["src/export/handler.py"],
        "evidence_refs": ["task:<task_id>"],
        "suggested_action": "补权限判断并重跑权限测试"
      }
    ]
  }
}
```

```json
// repair.json（group repair）
{
  "request_id": "repair-1",
  "acceptance_id": "AC-2",
  "spec_file": "specs/fix-export-permission.json",
  "title": "修复导出接口权限",
  "affected_members": ["csv-writer"],
  "expected_paths": ["src/export"],
  "authorization_ref": "real-scope-reference"
}
```

计划校验是**全有或全无**：`task_key` 唯一、`depends_on` 无未知/无自环/无环、每条需求至少被一个
成员覆盖、每个成员 spec 的 AC 非空且被 `acceptance_ids` 完整映射（check 型 AC 的 `check_id`
必须在本成员 `check_ids` 或 `group_checks` 中）、成员 spec 的 `allowed_paths` 只能收紧项目策略、
`expected_paths` 必须落在项目 `allowed_paths` 目录边界内（`src/export` 不含 `src/exported`）、
`budget.max_starts` 必须是显式正整数。`expected_paths` 重叠只是提示，**不**自动加依赖边，也
**不**扩大授权。

| 组请求 | 附加字段 |
|---|---|
| start | `expected_version` 不需要；推进器写租约。响应固定 `accepted`，`completed:false` |
| pause | `expected_version`；默认 drain（停止新派发，等在跑的收尾），`--stop` 同时停成员进程树。暂停**不**等于"没有子进程在跑"，响应给 `active_run_ids` |
| resume | 重新预检 → 重新对账 → 换新租约。`policy_revision` 变化后 resume 即显式接纳新策略 |
| cancel | `expected_version`、`reason`、`actor`；仍有活跃 run 时返回 `accepted` + `draining:true`，收口后才 `CANCELLED`。取消**不是**验收 |
| cancel --external | 载荷用 `external_ref`、`actor`、`claim: verified/asserted`，可选 `merged_sha`；进入 `CANCELLED`，记 `external_close`，响应固定 `accepted:false` |
| accept | `decision: accepted/rejected`、`actor`、`evidence_refs`（非空）、`expected_version`；`accepted` 需组处 `REVIEW_READY`、集成分支引用 == 记录的 `integration_sha`、集成工作区 HEAD 与指纹一致、当前 SHA 上组级检查全 PASS，且（计划要求审查时）当前 SHA 有一份无 `FAIL` 的审查结论。`rejected` 只记录，组保持 `REVIEW_READY` |
| review | `actor`、`review`（或顶层等价字段）；无 `--request-file` 时是只读查询，返回 `state`/`reason`/`unresolved`/`required_acceptance_ids` |
| repair | `acceptance_id`（必须已有一条 `FAIL`）、`spec_file`、可选 `affected_members`/`expected_paths`/`profile`；受 `budget.max_group_repairs` 与 `authorize(execute)` 约束 |

`group report` 固定七段：需求覆盖（结构覆盖，非语义验证）——其中含设计一致性审查的逐条偏差、
成员与执行组合（profile / combination / CLI / `auth_mode`）、SHA 链、组级检查明细、阻塞历史与
最小必要决策、预算与时间（含组级修复轮数）、交付边界声明。设计一致性审查的状态如实渲染：
`NOT_REQUIRED`（计划没声明）、`NOT_RUN`（还没有版本/还没做）、`STALE`（只有旧版本的结论）、
`INVALID`（上次提交无效）、`PASS` / `NOT_VERIFIED` / `FAIL`。**`NOT_VERIFIED` 不计入通过。**

## 认证态与检查分类（v1.3）

- `agent list` 与组报告里的 `auth_mode` 取 `cli_login` / `api_key` / `unknown`；未声明即
  `unknown`，报告必须写"认证态未知"，不得写成"已认证"。`login_state` 只有一次成功的
  `agent probe` 才能给 `present`，本机存在配置目录**不**算证据。
- `api_key` 必须同时声明 `credential_refs`；缺少即 `AUTH_REQUIRED`（注册期与 start 前各判一次）。
  Zoe 只检查环境变量是否存在，不读取、不记录、不回显值。
- 每条检查结果带 `error_class`：`test`（业务缺陷，计入实现预算）/ `environment`（环境装不出来，
  不该重写代码）/ `timeout`（按 `FAIL` 处理，不视为通过）/ `policy`（需要人决定）。

### 检查命令的写法与预检（v1.5）

检查以 argv 直接执行，不经过 shell。**默认写直接 argv**：

```json
{"id": "build", "argv": ["go", "build", "./..."]}
```

| 规则 | 原因 |
|---|---|
| 不要写死绝对路径（`/Users/.../go`） | 换机器即失效，而且要到 verify 阶段才炸 |
| 不要把 `bash -lc ...` 当默认写法 | 登录 shell 不保证与宿主一致；Windows 默认没有 bash |
| 需要 shell 语义时才用 shell 形式（`["bash","-c","..."]`） | 此时只校验 shell 本身，**内部命令不可静态解析**，需自行承担 |
| 依赖安装/构建产物的工具（`node_modules/.bin/*`、`bin/*`） | 注册时可能还不存在，预检标为 `deferred`，不算配置错 |

`doctor` 的 `checks_preflight` 逐条给出解析结果：

```json
{"check_id": "build", "argv0": "go", "resolved_path": "/usr/local/bin/go",
 "status": "ok", "hint": null}
```

`status` ∈ `ok` / `shell`（内部命令 `unverified`）/ `deferred`（等安装）/ `unresolved`
（裸名不在 PATH，**环境不就绪，计入 `ready`**）/ `invalid`。宿主应在 `task start` 前读它，
不要等到检查失败才发现工具缺失。执行时 Runtime 会**复校**，`unresolved`
直接产出一条 `error_class=environment` 的 FAIL，不会真的去起进程。

`deferred` **只表示推迟确认**：不算配置错，也不代表本次一定会跑通；不要据此推断"Agent 会
自己装依赖"——那条链没有任何保证。

**检查的 cwd 是任务 worktree，不是项目仓库**（`doctor` 的预检用项目 `repo`，执行用
worktree；PATH 也可能不同）。所以**不要**在 `argv` 里先把 cwd 切换到项目仓库再执行：那会让
检查跑在原仓库上，最坏结果是"原仓库绿、候选坏、Zoe 拿到绿色结果"。`bash -c` 也**不是**
PATH 或 Windows 的解法——它既不改变 PATH 来源，也不保证 `bash` 存在。

最好用一条负向用例兜住这件事：在夹具里让**原仓库测试通过、候选 worktree 测试失败**，最终
验证必须是 `FAIL`。

## 事件、日志与观测

三条线各自回答不同问题，**不要混用**：

| 线 | 命令 | 回答 | 不回答 |
|---|---|---|---|
| 状态线 | `task events` / `watch` | 状态与阶段如何迁移、为何阻塞 | Agent 正在做什么 |
| 动作线 | `task logs --follow` | Agent 逐条输出了什么 | 任务是否成功 |
| 观测线 | `task status` 的 `progress` | 有没有新输出、最后一次观测何时 | 是否卡死、是否有效推进 |

### 事件

`task events` 以单调自增 ID 分页，返回 `next_cursor` / `has_more`；宿主按 `event_id` 去重，
不承诺 exactly-once。

**过滤语义**（`watch --project/--group/--task`）：

- 三个过滤条件取**交集**；`--task` 与 `--project`/`--group` 冲突时直接报错
  （`PROJECT_MISMATCH` / `INPUT_INCOMPLETE`），**不返回空页**——空页只能表示"没有匹配事件"。
- 归属来自事件本身（写入时带 `project_id`）；旧事件按任务行、组行回查。都无法归属的事件
  计入 `unattributed`，**不会被猜进任何项目**。
- 游标按**已扫描**范围推进：即使本页没有匹配事件，`next_cursor` 也会前进。所以
  「返回空 + 游标前进」是正常结果，重放同一游标才是用法错误。
- 匹配事件多于单页上限时返回 `has_more=true`，用 `next_cursor` 续取，不丢事件。

`watch --follow --jsonl` 是**有界流式查询**：一行一个 JSON，`--timeout` 到期即退出
（不常驻）。首行与末行是 `kind="meta"` 的游标行，其余是事件行；无匹配事件时只有这两行
meta（不退化成心跳刷屏）。所以「监控」= 宿主反复重入这个有界命令，而不是等 CLI 提供订阅
服务。监控是宿主责任：CLI 只保证单次查询与游标正确，不保证有人一直在看。

**游标来源**：两种模式都给游标，但行不同。

| 模式 | 游标来源 |
|---|---|
| 有界查询（`watch P --jsonl --after C`，无 `--follow`） | 末尾 meta 行的 `next_cursor` |
| `--follow` | 首行 `follow_start` 的 `cursor`（起点）、末行 `follow_end` 的 `next_cursor`（可直接用于下一轮 `--after`） |

`cursor_status=cursor_expired` 时 `follow_end` 仍带 `next_cursor`（epoch 变化：状态库迁移/
恢复），供从头接续，不是错误信号。事件行本身不带游标语义——不要把事件 `id` 拼成游标。
两种取法**只在一轮边界切换**；同轮混用是两套语义对不上，不是"必然丢事件"。
另外 `next_cursor` 表示"已扫描"位置而非"已匹配"位置（见上），所以只承诺单调前进。

### 日志

`task logs`（无 `--follow`）是**快照**：返回末尾一条有界窗口内的**完整记录**，响应带
`snapshot: true` 与续读用 `cursor` / `next_cursor`。它**不是** `tail -f`，重复调用看到的是同一段。

**选项矩阵**（先看这张表，再看例子）：

| 调用 | 行为 |
|---|---|
| `task logs T` | 快照：最近 65536 字节窗口内的完整记录（默认值不变） |
| `task logs T --tail-bytes N` | 快照：最近 N 字节窗口（`1..1048576`） |
| `task logs T --after C` | 快照增量：`[C, C+tail_bytes)` 的完整记录；`has_more` 表示还有下一页 |
| `task logs T --follow` | 从**当前 EOF** 开始跟随（默认语义，不变） |
| `task logs T --follow --tail-bytes N` | 回看最近 N 字节内的完整记录后继续跟随 |
| `task logs T --follow --cursor C` | 从 cursor 继续；**cursor 优先，`--tail-bytes` 被忽略** |

`C` 是**日志游标** `run:generation:offset`（与 `--follow` 输出的 `cursor` / `next_cursor` 同构，
可直接回填），**不是** `task events --after` 的整数事件 id —— 两者同名不同物。

**快照的响应字段**：

| 字段 | 含义 |
|---|---|
| `log` / `run_id` / `text` | 日志名、run、窗口原文（含尾部半行，供排障；已脱敏） |
| `bytes` | 文件总大小（仍是全量真值，不因窗口变小） |
| `truncated` | **字节窗口**截断：左侧还有更早的记录 |
| `cursor` / `next_cursor` | 本次窗口**最后一条完整记录之后**的绝对位置（两者同值，`cursor` 为兼容保留） |
| `tail_start_offset` | 本次窗口的真实字节起点（不随 `events` 裁剪变化） |
| `events` | 投影后的事件，最多 200 条，**保留最近** |
| `events_truncated` | **事件数量**截断：窗口内完整记录超过上限 |
| `has_more` | 仅 `--after` 时给：本次拿到了完整记录且后面还有内容。为 `false` 就停，不要原地重试 |
| `rotated` / `reset_cursor` | 日志被截断/替换时的重置指引（游标 offset 超出文件大小 ⇒ `events` 为空、`reset_cursor` 从 0 开始，**不是错误**） |
| `projection` | 实际使用的投影模式 |
| `empty_reason` | `text`/`events` 同时为空时的原因，见下表；有内容时为 `null` |

**`empty_reason` 的四个取值**（v1.5.3 起；旧版本没有该字段，按 `rotated` /
`tail_start_offset` / `bytes` 自己判）：

| 取值 | 判据 | 含义 | 动作 |
|---|---|---|---|
| `rotated` | `rotated: true` | 游标 offset 超过文件大小（日志被截断/替换） | 用 `reset_cursor` 重新定位 |
| `no_newline_in_window` | `tail_start_offset == bytes` | 尾部窗口整段落在同一记录里（单条 > 窗口） | 加大 `--tail-bytes`（上限 1048576）或 `--after run:generation:0` |
| `no_complete_line` | `text` 非空、`events` 为空 | 窗口里只有半行/空行 | 真的没有新的完整记录 |
| `no_new_records` | 带 `--after` | 游标之后没有新记录（已追平） | 心跳，继续轮询 |

`bytes` 是文件总大小、`text` 是窗口原文：**"`bytes` 很大却 `text` 为空"不等于读取失败**，
先看 `empty_reason` / `rotated`。不要把这类窗口报成"日志读取有 bug"。

每条事件在**单条内容**被截断时带 `clipped: true`。三种截断（字节窗口 / 事件数量 / 单条内容）
互不冒充：不要把 `events_truncated` 读成"日志丢了"（丢的是窗口内更早的事件，`tail_start_offset` 不变）。

**`--after` 的校验与错误码**：

| 情形 | 返回 |
|---|---|
| cursor 形状非法（段数/非整数） | `INPUT_INCOMPLETE`（`details.field="after"`） |
| cursor 的 run ≠ 本次读取的 run | `PROJECT_MISMATCH`（`details={"cursor_run":…,"run_id":…}`） |
| `offset > 文件大小`（截断/替换） | 不报错：`rotated: true` + `reset_cursor` + 空 `events` |
| `--tail-bytes` 越界 | `INPUT_INCOMPLETE`（`1..1048576`） |
| `--after` 与 `--follow` 同用 | `INPUT_INCOMPLETE`（`details.field="after"`；"以为在看历史、其实在看实时"比报错更贵） |

窗口上限是 `tail_bytes`，但**若窗口内没有一条完整记录**，读取会延伸到下一条记录结束
（硬上限 256 KiB）：否则小窗口在大记录上永远不推进，`has_more` 会一直是 `true`。
`--after` 的偏移若不在行边界上，**向后对齐**（跳过不足一行的头部），不回溯。

**游标与日志名绑定**：cursor 只编码 `run/generation/offset`，无法自证来自哪个日志文件。
换 `--log`（如 `agent` → `check-build`）必须丢弃旧游标——这条只能靠调用方遵守。

`task logs --follow` 是增量流，语义已冻结：

- 游标 `run:generation:offset`：含 run id，所以换 run 不会被静默跟随；含 generation，所以文件
  被替换/截断后能重来。用 `--cursor` 续读，**不重不漏**。
- 只在**完整记录**出现时输出；末尾半行留在缓冲里，静默期间不产出、不补造，也不等于失败。
- 空行不产出事件（快照与 follow 同一规则）。
- 轮转（文件被替换或被截断）会输出 `{"kind":"rotated",...}` 并从新文件 0 偏移继续。
- 输出形状：**每一行都是 JSON 对象**，首行是 `{"kind":"meta","run_id":…,"cursor":…}`。
  `task logs` **没有 `--jsonl` 参数**（实测传了会 `unrecognized arguments`）。普通文本包成
  `{"kind":"raw","text":...}`，不混入裸文本；`raw` 只是形状，**仍然脱敏**。
- `--projection`：`auto`（逐条识别结构化记录，未知形状降级为 `raw`）、`raw`（纯文本）、
  `events`（只输出结构化动作）。首行是文本、后续是结构化记录是正常情况，逐条判断。
- `--max-bytes` 触达时输出 `{"kind":"limit","reason":"max_bytes","cursor":...}`，按游标续读。
- 脱敏是**尽力而为**：完整行脱敏降低但不能消除跨块泄漏。报告只引用摘要，不转贴原始日志。

**一致性不变量**（可作为自检）：同一 run、同一字节区间 `[a,b)`（端点都在完整记录边界）、
同一 projection 下，`snapshot(a,b).events` 与 `follow(a→b)` 的事件逐条相等。例外只有一种：
单条记录超过 64 KiB 时 follow 会切成"截断片段 + 后续片段"，快照按物理行处理 —— 不要声称
"任何情况下都一致"。

**这条线能证明什么**：`kind=text` / `kind=tool` 只说明 Agent 报告了什么、调用了什么工具，
不说明工具成功、结果正确，更不说明验收通过。日志静默也不证明卡死。

### 观测

`task status` 的 `progress` 段是观测事实，不是结论：

```json
{"run_id": "...", "log_generation": 1, "bytes": 184320,
 "started_at": 1793499400.0, "observed_at": 1793500042.0,
 "last_output_at": null, "quiet_seconds": 642.0, "process_state": "alive",
 "observed_age_seconds": 3.1, "observations_stale": false}
```

- `observed_at` 是**监控进程最后一次完成观测**的时刻；`quiet_seconds` 是距最近一次输出
  （从未输出则从启动起算）。
- `process_state` ∈ `alive` / `exited` / `unknown`，与 `quiet_seconds` 并列看。
  **无输出不能证明卡死，有输出也不能证明有效推进。**
- `observations_stale: true` 表示监控进程自己失联了：此时不能读成"健康"或"卡死"，
  应重新 `task status --refresh` 或查 `reconcile`。
- 阈值（`ZOE_PROGRESS_MIN_INTERVAL` / `ZOE_PROGRESS_MIN_BYTES` /
  `ZOE_OBSERVATION_STALE_SECONDS`）属于**宿主观测设置**，不进项目配置——项目配置的任何改动
  都会改变 `policy_revision`，只改一个提示阈值不该让在途任务撞 `POLICY_CHANGED`。

## 结果与错误

`error` 固定含 `code` 与 `message`，可选 `details`（对象，按 code 定义）。只读 `code` 的宿主
不受影响；需要区分细节时读 `details`，不要解析 message。操作响应含
`status`/`task_id`/`row_version`，启动另含 `accepted`/`completed`/`run_id`。
**`status=succeeded` 只表示本次操作成功，不能代替任务 `state=DONE`。**
`block_details` 与触发阻断的 `error.details` 同源（如 `drift_kind`），下次成功启动清空。

配置类错误会一次性列出**所有能独立判断**的问题（v1.6）：顶层 `code` / `message` 仍是
第一个问题（与逐条校验时一致），完整清单在 `details.errors[]`，每条含 `code` / `field` /
`reason` / `suggested_change` / `requires_approval`；依赖无效字段而无法判断的检查列在
`details.skipped[]`。不承诺"报完所有错误"——结构性问题（如仓库不存在）仍会立即终止，
因为后续检查在那种情况下没有意义。

`requires_approval: true` 只出现在会**扩大授权**的建议上（扩 `allowed_paths`、放宽
`protected_paths`、提高 `permission_profile`）。宿主只能转述，不得自行批准或改写为成功。

退出码：`0` 请求成功（不等于任务完成）；`2` 请求格式/规格错误；`3` 状态或幂等冲突；
`4` 环境或能力未就绪；`5` 授权或策略拒绝；`6` 外部效果不明；`1` 其他运行错误。

两个口径分开看：**`project` 命令族**（`register` / `attest` / `diff` / `context`）沿用旧映射，
结构化错误一律 `4`，但 `error.code` 与 `details` 与非旧命令一致——分支要按 `code`，不要按退出码
（`project attest` 的 `ATTEST_PRECONDITION_FAILED` 就是这种情况）。`task create/start` 同理。

| code | 含义 | 恢复动作 |
|---|---|---|
| `STATE_CONFLICT` | 状态不允许该动作 | 刷新任务重新判断 |
| `REQUEST_CONFLICT` | 同请求 ID 内容不一致（`details.existing` 给出占用它的 `task_id` / `action` / `status`） | 换新 ID 或复用原载荷；**不要盲目重试**——同 ID 不同 `task`/`action`/载荷永远冲突，先查清为什么撞 |
| `SLOT_BUSY`（3） / `TASK_BUSY`（4） | 并发上限 / 写者占用 | 看 `details` 里的占用任务，不暗中排队 |
| `ADAPTER_UNVERIFIED` / `ADAPTER_VERSION_MISMATCH` / `ADAPTER_BACKEND_MISMATCH` | 该执行器或 backend/版本未验证 | 不得改用其他未验证执行器绕过 |
| `CAPABILITY_UNSUPPORTED` | 本版不支持该能力/后端 | 按 `details.migration` 改配置或新建 task |
| `REMOTE_DRIFT`（退出码 4） | 发布前远端漂移 | 见下方 `drift_kind`；不重跑验证、不强推 |
| `BASE_DRIFT`（退出码 4） | **首次派发前**发现任务的冻结基线已不在目标分支历史里（rebase / force-push / 分支被改写） | 确认目标分支现状后重冻结（`task revise` 或换基线重派）；**不要强推覆盖**，已产出的候选要重新验证。只能确认不可达时才报：`git` 读不到时判 `None` 并放行，真正的失败仍由 verify 阶段给出 |
| `REMOTE_UNKNOWN`（退出码 6） | 无法确认远端状态 | **不等于**无漂移；恢复后重试 |
| `PROCESS_UNKNOWN` | 旧写者状态不可观测 | `task recover TASK [--run RUN] [--confirm-stop]` 人工收口（`--run` 缺省取 `current_run_id`），禁止起第二个写者 |
| `HANDOFF_STALE` | 工作区在交接后漂移 | 先核对再换执行器 |
| `POLICY_CHANGED` | 项目策略已变化 | 先 `zoe project diff --config <new> --json` 看影响面（是否只改了调度字段、哪些在途任务受影响），逐任务 `task rebind --request-file`（`target_policy_hash` = `new_policy_hash`），需要时 `task resume` 重签证据，再 `task accept`；**不得**跳步直接建新任务，也不得把"只调了并发"当成无需处置 |
| `ALLOWLIST_UNCONFIRMED` | 声明了 `routing` 段的项目没有有效授权确认记录 | 读 `details.reason`（`missing` / `policy_changed_since_attestation` / `candidate_not_confirmed` / `record_invalid`），按 `project attest` 流程重新确认；**不得**绕过、不得自行修改白名单，也不得当"重试即可" |
| `ATTEST_PRECONDITION_FAILED` | `project attest --expect-policy-hash` / `--expect-profiles` 与锁内读到的当前配置不一致（预览与写入之间配置被改） | **没有写入**。重新跑 `--dry-run`、把新 `execution[]` 重新展示给用户并重新取得同意；不得声称"已确认" |
| `MIGRATION_REQUIRED` | 状态库为 v1/v2/v3 | 停止执行后 `state migrate --to 4` |
| `SPEC_CHANGED` / `WORKSPACE_CHANGED` | 输入或代码变化 | 重新验证 |
| `VALIDATION_FAILED` / `AGENT_FAILED` | 验证或 Agent 失败 | 保留成果，修复后 `resume`。`AGENT_FAILED` 是兜底码：先看 `result_schema` 与 `agent_evidence`，不要把它当"代码写错了"直接重跑 |
| `AGENT_AUTH_REQUIRED` / `AGENT_PERMISSION_DENIED` | 凭据/权限 | 修环境后 resume，不自动扩权 |
| `AGENT_RATE_LIMITED` | **临时**限流（可退避） | 退避后 resume；不要与 `QUOTA_EXHAUSTED` 混用处置 |
| `QUOTA_EXHAUSTED`（4，v1.6） | 账号/计划额度耗尽：项目级闸门已生效，`start`/`resume` 一律被拒 | **不要 resume**。读 `details.quota_reset_at`，等重置或换账号，再 `project quota clear --project P --why "..."`；解除不验证额度真的恢复，下一次派发仍无预算会再次触发 |
| `OUTPUT_LIMIT_EXCEEDED` / `PROMPT_TOO_LARGE` | 预算越界 | 裁剪输入或输出，不把截断当成功 |
| `ENVIRONMENT_ERROR` / `COMMAND_FAILED` | 环境或命令问题 | 结合 `phase`；publish 阶段先查远端，不重跑编码 |
| `RETRY_EXHAUSTED` | 达到实现预算 | 停止自动续跑，人工决定 |
| `NOT_OWNER` | 项目已被其他宿主 claim | `orchestration claim --force` 并记决策，不并行写 |
| `DECISION_CONFLICT` | 编排记录版本过期 | 重读 `orchestration show` 后重试 |
| `POLICY_DENIED` | 越权写预算计数等 | 预算只由控制器维护 |
| `PROJECT_MISMATCH` / `TASK_RUN_MISMATCH` | 归属不符 | 核对身份链，不"修正"成看起来正确的项目 |
| `INPUT_REQUIRED` | 等 Agent 提问的回答 | `task answer`，重试预算不变 |
| `INPUT_INCOMPLETE` | 请求或 spec 字段缺失/非法 | 补齐后重发，不靠重试 |
| `MODEL_UNAVAILABLE`（4） | 指定模型在本机不可用 | 换组合或换机器，不改写记录 |
| `MODEL_MISMATCH`（5） | 固定模型但观测不匹配/未观测 | run 作废、工作区已归档为 patch；`reassign` 或 `cancel` |
| `ENDPOINT_UNVERIFIED`（5） | 要求数据落地私有/本地但端点无法确认 | 声明可绑定的端点，或降级 `data_residency` |
| `SPEND_LIMIT_EXCEEDED`（5） | 越过单任务/单日费用上限 | 提高上限或换组合；不许当警告继续 |
| `SPEND_UNVERIFIABLE`（5） | 配了上限但成本不可观测 | 声明 `unit_price` 或用会报成本的工具 |
| `ROUTE_NO_ELIGIBLE`（4） | 无候选满足硬条件 | 看 `details.gaps` 逐条修，不绕过闸门 |
| `ROUTE_AMBIGUOUS`（3） | 多候选且无可用偏好 | 明确 `agent_profile` 或补 `routing.rules` |
| `ROUTE_RECORD_INVALID`（3） | 决策记录缺失/被改 | 重建任务；不要"修复"记录后继续跑 |
| `INTEGRATION_CONFLICT`（5） | 集成合并冲突 | 冲突现场保留在 `details.conflict_dir`；不要改 `integration_sha`，另开后续组 |
| `INTEGRATION_CHECK_FAILED`（5） | 集成候选上组级检查失败 | 日志与 `worktree` 保留；不得跳过检查直接验收 |
| `INTEGRATION_UNKNOWN`（5） | 集成引用/记录不一致（如分支指向意外提交、工作区丢失） | 停下人工核对，不猜"大概合过了" |
| `GROUP_BUDGET_EXHAUSTED`（5） | 组启动额度或墙钟预算耗尽 | 改计划（`revision+1`）或取消；对账/集成/检查/验收仍可用 |
| `ACCEPTANCE_UNREVIEWED`（3） | spec 要求逐条 AC 判定，但没有绑定当前 `validated_sha` 的 `task review` | 补一份结论；**不要**把 `acceptance_review` 去掉来绕过（那是改需求，需要人批） |
| `ACCEPTANCE_REVIEW_FAILED`（5） | 逐条判定存在 `FAIL` | 修实现后重新 verify 再判；不得改判定"变绿" |
| `ACCEPTANCE_UNACKNOWLEDGED`（3） | 存在 `NOT_VERIFIED` 但验收请求没有逐条确认 | 重发 accept，带 `acknowledged_not_verified` 且与结论完全一致 |
| `DECISIONS_OPEN`（5） | spec 的 `decisions[]` 仍有 `status=open` | 由 owner 拍板后 `task revise` 回写 `resolved`；不得在验收时临时口头决定 |
| `PROGRESS_NOT_TICKED`（5） | `progress_refs` 声明的文档复选框未在候选树里勾选 | 把勾选作为交付物一起提交；`reason` 区分 `doc_missing` / `marker_missing` / `not_ticked` |
| `DEPENDENCY_NOT_MET`（5） | `depends_on` 的上游没有闭环（或没有任何任务认领该 marker） | 去推上游（`task graph` 看谁堵了谁）；**不要 resume**，同一个门禁会再拒一次。`details.blocking[].reason` 区分 `no_task_claims_marker` / `upstream_not_closed` |

`REMOTE_DRIFT` 的 `drift_kind`：`base_advanced`（目标分支已前进）、`base_rewritten`
（历史被重写）、`candidate_diverged`（任务分支在远端已变化，`details.reason=tasks_ref_missing`
表示分支曾发布过但被删除）。`details` 另含 `task_id`/`base_sha`/`observed_base_sha`/
`candidate_sha`/`observed_task_sha`/`evidence_ref`。阻断时 `validated_sha` 保留原值——它是
"某次验证通过过"的历史事实，但 `block_code=REMOTE_DRIFT` 表示该证据已过期，**不得因为字段
非空就认为验证仍有效**；恢复路径是新建 task 重新冻结基线。

不直接写 SQLite、不修改 operations、不伪造 Run；改配置不会自动迁移旧任务的冻结授权。

### 并行基线事实（`concurrent_base`，v1.6）

进入 `REVIEW_READY` 时，任务记录（以及 `task status` / `task digest`）里会带一份事实：

| 字段 | 含义 |
|---|---|
| `kind` | `none`（基线之后目标分支没动）/ `base_advanced`（动了但无重叠）/ `overlap`（有重叠）/ `reverts`（候选删掉了别人刚改过的文件）/ `unknown` |
| `behind_by` | 目标分支在任务 `base_sha` 之后前进了几个提交 |
| `overlapping_paths` | 前进的改动与候选落在**同一批文件**上（最多 50 条） |
| `reverts_merged_work` | 候选删除、且基线之后被别人改过的文件——**合并会丢掉那些改动** |
| `reason` | `base_unchanged` / `no_candidate` / `base_unresolved` / `count_failed` / `diff_failed` / `git_error` |
| `message` | 一句话结论 |

它**只标注，不阻断**，与 `BASE_DRIFT`（退出码 4，回答"基线还在不在历史里"）是两件事：

- `base_advanced` 是并行批次的常态，3-way 合并通常能自动处理；把它判成失败只会逼出
  `merge --abort` + 重派；
- `overlap` 的含义是"**合并后必须重新验证**，不能沿用合并前的证据"——不是"会冲突"；
- `reverts` 才需要人工介入：合并会丢掉别人刚合入的改动；
- `unknown` 不能当 `none` 用：读不到 ≠ 没前进。

判据与 `git diff --stat HEAD..<cand>` 的区别在这里：后者拿**当前 HEAD** 比，会把"候选还没
跟上"显示成"候选在删代码"，于是正常的落后被误读成灾难性回退。

### 零候选（`empty_candidate`，v1.5.3）

任务记录与 `task status` / `task report` 里有 `empty_candidate`：本次验证的候选与 `base_sha`
相同，意味着**没有任何可交付改动**（worker 零提交）。

- 它只标注，**不阻断**：零改动是合法结果（只补证据、只做验证的任务确实不产生提交），
  是否允许由验收判断；
- `candidate_sha is None` 是"还没验证"，与"验证了但没有改动"是两件事，不要混；
- 为真时 controller 会写一条 `empty_candidate` 事件，`task report` 顶部也会显式标出
  `EMPTY：与 base_sha 相同`；
- `revise` / `rebind` / 重新指派会把它复位为 `false`（旧验证作废）。

不直接写 SQLite、不修改 operations、不伪造 Run；改配置不会自动迁移旧任务的冻结授权。
