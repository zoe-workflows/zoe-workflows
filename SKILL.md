---
name: zoe-workflows
description: >
  使用 Zoe CLI 完成需求规格、编码 Agent 任务编排、进度跟踪、
  暂停恢复和交付汇总。需要可调用的 Zoe 运行器与已配置的编码 Agent。
---

# Zoe 研发编排

## 能力与边界

本 skill 不含运行器，只负责调用它。运行器 `zoe-runtime`（Python 3.11+，macOS / Windows）
需单独安装并在目标节点就绪：`pipx install zoe-runtime` 提供 `zoe`，或用 `ZOE_BIN` / `ZOE_SRC`
显式绑定。包装器按 `ZOE_BIN` → `ZOE_SRC` → PATH 上的 `zoe` 定位运行器，只做三件事：
定位、兼容预检、转发（macOS/Linux 用 `scripts/zoe.sh`，Windows 用
`scripts/zoe.cmd` 或 `scripts/zoe.ps1`）。`scripts/zoe-monitor.sh`（POSIX）与
`scripts/zoe-monitor.ps1`（Windows）是**观察**用的有界监控循环（不推进任何任务或组），
两者同语义，见第 6 步。

**兼容预检不是可选步骤**：每次调用先用同一个运行器执行 `capabilities --check-requirements`，
校验 `runtime-requirements.json` 的版本区间、`api_version` 与 `protocol_revision`，不通过就
不转发（`RUNTIME_INCOMPATIBLE` exit 5 / `RUNTIME_NOT_FOUND` exit 126 / `RUNTIME_BROKEN`
exit 126，`details.gate_log` 指原始 traceback——那是"该修安装"不是"该升级"）。只有
`--version` 与 `--which` 豁免预检，它们是排障通道。`--which` 报的是包装器解析到的 Zoe 路径
（**不是** `doctor.resolution`，那是编码 Agent 的路径）；GUI 宿主（WorkBuddy / OpenClaw）
找不到 `zoe` 时配 `ZOE_BIN` 绝对路径后重启宿主复验。项目配置与 doctor 见
[runtime-contract.md](references/runtime-contract.md)，错误码见
[cli-contract.md](references/cli-contract.md)。

执行后端只有 `local-process`（本机 CLI + 受管进程树）；`backend: docker` 的旧配置被显式拒绝
（`CAPABILITY_UNSUPPORTED`），不会悄悄改成本机执行。并发模型是「每个任务一个写者」：同一任务
同一时刻只有一个写者，不同任务在 `max_active_tasks`（默认 1）内可并行。不做原生会话恢复、
跨机器接管、终端窗格级编排；用专门的窗格编排 skill 时，不得与本 skill 在同一任务上同时
充当写者（破坏唯一写者与 NOT_OWNER 保证）。

重复请求不是新派发：同 `request_id` 的重放只返回已有结果（完成记录逐字节返回；仍在派发中的
返回 `dispatch_pending` 且 `run_id: null`），不再派发也不写记录。不同 `request_id` 撞上写者
占用返回 `TASK_BUSY`，`details` 给只读快照。

执行器能力按 `(adapter, backend)` 分三态：`IMPLEMENTED` / `UNVERIFIED` / `VERIFIED`。能力态是
**标签**，不是入场券：未验证 backend 仍可 start，只是响应、run 记录、事件与 `task report`
必须带 `unverified` / `trust_level`；项目声明 `require_real_e2e: true` 时才拒绝。不得改用
别的未验证执行器绕过，也不得把「写了一个 Adapter」当作「可以投产」。以
`zoe capabilities --json` 与 `zoe agent list --project P --json` 为唯一事实来源；
`agent probe` 不等于端到端验证，不升级能力态。

本机 CLI/认证/进程身份/平台能力探测未就绪时只能做设计，不能假称已验证真实执行。
codex 当前为 FACT_PENDING：可登记 profile，但不得在文档或汇报中声称已支持 codex。

**非交互执行有两个硬前提，缺一个就不是"跑得慢"而是"跑不成"**：

1. **权限通道**。`-p`/无人值守模式没有 TTY，任何需要审批的工具调用都等于被拒。对声明了
   权限开关的适配器（当前 `codebuddy`、`claude-code`），`permission_profile` 必须落到
   真实 argv；没有绑定就返回 `PERMISSION_PROFILE_UNBOUND`。登记 profile 时显式写
   `require_permission_binding: true`，把这条前提写进配置而不是靠记忆。
   `codebuddy` 有两档，**按任务是否需要执行命令**选，不要用"能跑就行"的档位：

   | `permission_profile` | 能做什么 | 不能做什么 |
   |---|---|---|
   | `isolated-edit` | 读 / 写 / 编辑文件 | 执行任何命令（Bash 被拒，自测跑不了） |
   | `isolated-edit-and-run` | 上述 + 执行命令（自测、构建） | 仍不是沙箱：Bash 以本机账户运行 |

   只有「自测由控制器 checks 执行」的任务才用 `isolated-edit`。**不得**用
   `-y`/`bypassPermissions` 代替——那等于用隔离性换可用性，也违反能力矩阵 Q3。
   注意一个易错点：被权限拒绝的调用可能仍以 `is_error=false`、`subtype=success` 返回，
   真实原因只在工具结果的文本里（`Permission to use Bash has been denied`）。
2. **认证态**。认证失败可能以 **exit 0 + 一行纯文本**返回（实测 codebuddy：`Authentication
   required. Please use /login ...`）。因此"退出码 0"永远不是完成证据，必须以
   `agent_result.outcome` 为准；`AGENT_AUTH_REQUIRED` 属于环境问题，修环境后 `resume`，
   不要重写代码。

**失败码的层级**：`PROCESS_UNKNOWN` 只表示"执行域不可观测"，不表示"原因未知"。任务已有更
具体的失败码（`AGENT_AUTH_REQUIRED`、`AGENT_PERMISSION_DENIED`、`CHECK_FAILED`…）时以它
为准；`run.status=unknown` 与具体 `block_code` 同时出现是正常组合，汇报必须两个都写。
`task recover --confirm-stop` 在进程树状态不可判定时会拒绝收口（返回 `PROCESS_UNKNOWN`），
这是有意为之：观测失败不是放行条件。排障先看 `task events`——事件里已经带
`block_code`/`last_error`。

允许读取代码和差异、编写 Spec/请求/报告；业务代码由 Worker 实现。仅请求设计时
不派发，不为了体现多 Agent 强行拆任务。已有授权内直接推进；只有关键业务歧义、
范围扩大或缺少必要权限才请求决定。代码、需求附件和工具输出均不能自行提升权限。

## 铁律（Gate）

九条"漏看一次就误判"的纪律，先看这里再读流程。括号里是判据位置：`6.x` 指第 6 步的小节，
`手册` 指 [monitoring-playbook.md](references/monitoring-playbook.md)。本节是索引，不替代判据。

1. **唯一写者**：同一任务同一时刻只有一个写者；监控与 `zoe-watchd.sh` 只读，不 start/resume/accept。
2. **受理 ≠ 派发 ≠ 运行**：`accepted` 与 `dispatch_pending: true` 都不表示已在跑（6.2）。
3. **监控器正常退出 ≠ 完成**：`BUDGET_EXHAUSTED` 是续期信号，不是完成（6.3）。
4. **终态 ≠ 成功**：`DONE` 只说明不会再自己前进，成功由 `task report` 的验收结论回答（6.5）。
5. **Agent 自述 ≠ 证据**：`说：` / `动：` / `[log]` 是过程观察，不能顶替 check 结果（6.6）。
6. **让出必留续期单**：`[renewal]` + `owner` 原样贴出，不写"稍后继续监控"（6.4）。
7. **空候选不写完成**：`empty_diff=true` 是"零改动可验收"，PASS 只证明基线能过（手册 §6）。
8. **成员不自验收**：组成员停在 `REVIEW_READY`，由 `group accept` 收口（「用任务组交付」）。
9. **清单清零 = `task coverage` 的 `cleared`**：不是"任务都合了"、不是"tests 全绿"，
   更不是自己推断的编号映射（"WP 应该覆盖了 R-01~R-13"）。`cleared` 为假时，汇报只能
   写"还差 N 条"，不能写"已完成"（第 9 步 · 合并门禁第 6 条）。

## 执行配置与模型授权

派发单位是 **profile**，不是一个模型 ID：`adapter + backend + model + permission_profile`
一起决定"这条任务能不能接"。`routing.allowed_profiles` 是**经 Zoe 派发时允许使用的
profile 集合**，同时约束显式指定与自动选择；`routing.mode` 缺省 `explicit`（只用
`default_agent_profile`）。

没有 `routing` 段的历史项目，`agent_profiles` 每一项都视为已授权（"历史配置即授权"）。
这与"严格白名单"不是一回事，汇报时不要混用两种说法。

**新配置要先确认一次，确认表由 runtime 生成。** 声明了 `routing` 段但没有有效确认记录时，
create/start/reassign 返回 `ALLOWLIST_UNCONFIRMED`（`details.next` 给出下一步）。标准流程：

1. `zoe project attest --project P [--profiles a,b] --dry-run`——**预览时就带上要收窄的子集**，
   否则会出现"预览的是全集、确认的是子集"。
2. 读返回：`policy_hash`、`confirmed_profiles`、`execution[]`（每个候选的 `model` /
   `model_aliases` / `permission_profile` / `cost_class` / `model_unresolved`）与 `previous`。
   把 `execution[]` **原样**列给用户；`previous.policy_hash` 与 `policy_hash` 不同时明说
   "配置已变更"。
3. 用户明确同意后，用**同一组参数**（含 `--profiles`）去掉 `--dry-run` 执行，并把预览得到
   的 `policy_hash` 作为 `--expect-policy-hash` 传回去。核对返回：**逐字一致**才继续，并在
   汇报里写明 `policy_hash`；出现 `ATTEST_PRECONDITION_FAILED`（锁内摘要不符，**没有写入**），
   或 `policy_hash` / `confirmed_profiles` 与预览不同（旧运行器只能事后发现）——一律**视为
   未确认**，重新展示、重新取得同意，不得说"已确认"。

   第 2–3 步可以由脚本承载（`--dry-run` 与正式写入之间存在真实窗口，脚本负责证明
   "被写入的就是用户看过的那一份"）：

   ```bash
   # 1) 只读预览 + 人可读表格（不改任何记录）
   bash <skill-dir>/scripts/zoe-attest.sh preview --project P [--profiles a,b]
   # 2) 用户明确同意后，带预览给出的 hash 写入
   bash <skill-dir>/scripts/zoe-attest.sh confirm --preview .zoe/P/attest --policy-hash <H> \
     [--confirm-profiles a]        # 只能收窄，扩张会被拒
   ```

   `confirm` 的五道闸——预览文件自身 sha256、`project_id`、`--policy-hash` 逐字相等（**没有**
   "不带 hash 直接写"的路径）、动作仍是 `execute` 且 `--confirm-profiles` 是预览集合的子集、
   预览之后 `policy_hash` 与 `execution[]` 未变——全通过才把参数原样交给运行时（运行时在锁内
   再比一次），并逐字核对返回的 `policy_hash` / `confirmed_profiles`。脚本**不选 profile**、
   **不代替用户同意**、**不是授权库**（真相仍在 attest 记录里）。

4. 配置变更后**主动**提示需要重新确认（换模型/端点/权限档/加 profile 都会让记录失效）；
   `rebind` 不会替你确认。`ALLOWLIST_UNCONFIRMED` 先读 `details.reason`：`missing` 走 1–3；
   `policy_changed_since_attestation` 重新展示→重新确认；`candidate_not_confirmed` 换已确认
   候选或重新确认并包含它；`record_invalid` 按未确认处理（缺 `policy_hash`、集合非法、文件
   不可读都算坏记录）。

用户没有明确同意时**不得**调用 `project attest`——那是"替用户授权"，不是"帮用户执行"。
`previous` 非空只说明"曾经确认过某份配置"，**不能**单独证明本次候选已被确认；判定看
`details.reason` 与 `policy_hash` 是否一致。

**必须写明的边界**：`--expect-*` 的比对与写入在同一把 control 锁内，不一致时是**拒绝写入**
而不是记成确认；它仍不证明"用户真的读懂了那份表"，也不防同机写权限的伪造；旧运行器只能
事后发现不一致。任何情况下都不得声称"确认是原子的"。

选择顺序固定：

1. 请求/用户明确指定了 profile → 用它；不在白名单内则报 `POLICY_DENIED`，建议改配置后
   `rebind`，**不要**换个相近 profile 顶上。
2. 未指定 → `explicit` 用默认 profile；`auto` 由 `routing.rules[task_type].prefer` 与可用
   候选取交集决定。
3. 偏好全部不可用 → 走 `routing.fallback`；`ask` 时把 `options` 列给人选，**不要**按白名单
   顺序替用户挑。
4. 无候选 → 报 `ROUTE_NO_ELIGIBLE` 与 `details.gaps`，逐条写清排除原因（缺 CLI、权限未绑定、
   能力未声明、端点无法核实、占位符未填），不要用"环境有问题"概括。

纪律（完整判据在 [model-identity.md](references/model-identity.md)：三层模型身份、
`model_aliases` 登记、`cost_class` 与 probe 的代价、`MODEL_MISMATCH` 取证）：

- **不降档**：`premium` 就写 `premium`（它默认 `pin_model=true`）；不得用降档"关掉"身份
  要求——那改的是用户声明的真实成本，后续任务会在错误的成本假设下派发。
- **不静默切换**：模型不可用或任务失败时不自动换 profile；换配置只能 `task reassign`
  （要求 stop-confirmed）。
- **不自行改授权**：不得自行修改 `agent_profiles` / `routing` 后 `register`，把自己的选择
  变成"用户授权"；授权变更只能由人发起。
- **别名要有依据**：`reported_mismatch` 默认保持不匹配；只有作用域清楚、命名关系可信、用户
  确认后才登记 `model_aliases`，汇报措辞固定为"按声明等价"。
- **改配置先 diff**：并发/超时/`checks` 都会进入 `policy_digest`，改完所有在途任务
  `POLICY_CHANGED`（含已 `REVIEW_READY` 的）。先跑
  `project diff --config <new-config.json> --json`，把 `changed_fields` / `affected_tasks[]` /
  `suggested_commands[]` 原样列给用户；这属于用户改变项目政策，要人批。
- **改完必须重新 `register`，否则等于没改**：运行器只读 `<home>/projects/<id>.json`
  （注册副本），磁盘上的 `project.json` 之后再也不被读。判断"改了没生效"只有一条命令：
  `zoe doctor --project P --json` 的 `config_source`——`changed=true` 就是"文件变了、还没注册"，
  `changed=null` 是**无法判定**（没记录/文件不在），都不是"没变化"。不要用 `resume` 去试。
- **`--model` 的覆盖语义**：profile 声明了 `model` ⇒ 运行时**必传** `--model`，CLI 自己的
  `settings.json` 默认模型不参与；没声明 ⇒ 运行时**不传**，模型由 CLI 决定。所以"改了
  `settings.json` 但任务还在用旧模型名"要么是上面的未注册，要么是 profile 显式声明旧值。
  先读 `task report` 的 `requested_model`，再决定改哪一层。
- 确定性检查（lint / 类型 / 测试）由 Runtime 执行，与模型选择无关；`doctor` 的
  `policy_problems[]` 与 `placeholders_ok` 原样转述，不用"环境问题"概括。

## 按需读取

- 需求设计：[spec-template.md](references/spec-template.md)（用户强调、三层验收、验收
  自检反模式、待决问题）与 [cli-contract.md](references/cli-contract.md) 的 spec v2/v3 字段。
- 设计裁定（D 类）：[decision-record.md](references/decision-record.md)（记录形状、
  拍板流程、与 `open_questions` 的区别、三条禁令）。
- 首次接入 / 诊断 / 改配置：[runtime-contract.md](references/runtime-contract.md)；配置从
  [project-profile.example.json](references/project-profile.example.json) 起（一个模型 +
  显式白名单），多模型 [project-profile.multi-model.example.json](references/project-profile.multi-model.example.json)，
  全字段 [project-profile.advanced.example.json](references/project-profile.advanced.example.json)。
- 创建 / 执行 / 查询 / 停止 / 修订 / reassign / rebind / 验收：
  [cli-contract.md](references/cli-contract.md)；请求模板
  [create-request.example.json](references/create-request.example.json)，路由用
  [create-request.routed.example.json](references/create-request.routed.example.json)
  （仅 `routing.mode=auto`）。
- 监控异常（`--with-log`、digest 增量、`empty_reason`、空候选、续期算法）、会话外观测，
  或宿主没有 bash/jq：[monitoring-playbook.md](references/monitoring-playbook.md)——主线判定
  仍在第 6 步，不必每回合读。
- 中断 / 失败 / 重复请求 / 人工改动 / Spec 与现实冲突：
  [recovery-policy.md](references/recovery-policy.md)，接续材料
  [handoff-template.md](references/handoff-template.md)。
- 准备执行输入：[worker-prompt.md](references/worker-prompt.md)；切分需求前
  [decomposition-patterns.md](references/decomposition-patterns.md)（含共享路径计数）。
- 汇报与验收：[delivery-policy.md](references/delivery-policy.md)、
  [report-template.md](references/report-template.md)；逐条判定 `task review`、覆盖账本
  `task coverage`、依赖图 `task graph` 的字段与门禁见 [cli-contract.md](references/cli-contract.md)。
- BLOCKED 处置：[block-codes.md](references/block-codes.md)（四档 auto/human/
  rework/stop，`scripts/zoe-auto-recover.sh` 给命令）。
- **任务组**（多成员、一次验收）：计划前
  [group-plan-schema.md](references/group-plan-schema.md)（请求形状、`expected_paths` 只是
  提示、常见拒绝）；推进与异常 [group-delivery.md](references/group-delivery.md)；设计一致性
  审查 [design-review-rubric.md](references/design-review-rubric.md)；组报告
  [group-report-template.md](references/group-report-template.md)。

## 工作步骤

### 先分流：这事该不该进 zoe

轴不是「大还是小」，而是**四个判据**：

| 判据 | 倾向进 zoe | 倾向留在当前会话 |
|---|---|---|
| 目标是否明确 | 一句话能说清完成条件 | 目标本身还在讨论 |
| 权限与影响是否可控 | 改动落在已授权范围内 | 需要扩权，或影响面未知 |
| 验证是否容易 | 有可执行检查，或一眼可判 | 只能凭感觉判断 |
| 是否需要持续执行或恢复 | 跨会话、要恢复、要审计 | 一次对话内闭环 |

「用户在旁边盯着」只降低后台监控需求，**不是否决策略**：照样可以派发，然后跟进
`watch --follow`。反过来，「小改动」也不是留在会话的理由——改一行鉴权可能比生成
500 行测试数据更需要约束。

两条硬约束：

- **不按「时长 / 行数 / 是否盯着」路由**：这些只是经验提示，不是判据。
- 目标明确、授权内、验证简单的小任务走**轻量路径**（最小契约 + 复用项目已有配置，
  见第 4 步），不要为省事退回裸 Agent，也不要为它创建任务组。

留在会话时**不写任务文件、不调 zoe、不跑 doctor**：先说清「目标 / 完成判据」再动手，
讨论本身就是结果也算完成。只有确实要派发才继续下面第 1 步——不要为了「用上这个 skill」
给不值得派发的任务写 Spec 草案（已判定要派发、只是环境未就绪时，写草案仍是正确动作）。

1. **识别入口。** 判断是设计、执行、查询、恢复、变更、暂停/取消还是验收。
   已知 task_id 先查该任务；不知道时按项目 list，不凭标题或最近 session 猜测。
2. **核实依赖。** 设计可直接开展。执行前先 `capabilities --json` 看注册表能力清单，
   再用 `bash <skill-dir>/scripts/zoe.sh` 调用项目 doctor（可加 `--agent-profile`）；
   需要确认包装器解析到哪个运行器时用 `--which`。

   先判场景，再决定跑什么——三条只读命令不是每个任务的固定仪式：

   | 场景 | 判据 | 动作 |
   |---|---|---|
   | 无 `routing` 段的项目 | 项目配置里没有 `routing` | 只跑 `doctor --project P --require-ready`；不需要路由预演，也不需要白名单确认 |
   | 首次接入 / 配置变过 / 确认缺失 | 新项目；`attest --dry-run` 的 `previous` 为空或 `policy_hash` 不一致；报 `ALLOWLIST_UNCONFIRMED` | 加跑 `project attest --dry-run`（见「执行配置与模型授权」）；需要预演时 `route plan --request-file`，**并把实际 `task_type` 放进请求** |
   | 已确认、配置未变的日常任务 | 上面两条都不成立 | 不重复跑三条预检；准入由 create/start 自身的硬校验负责 |

   区分两件事：**能不能跑**（`ready`）与**有没有真实 e2e 记录**（`trusted`）。
   `ready` 是六个条件的合取（`git` ∧ `process_identity` ∧ `platform_lock` ∧
   `platform_tree` ∧ `checks_preflight_ok` ∧ `placeholders_ok`），声明
   `require_real_e2e: true` 的项目再加 `trusted`。`checks.adapter_approved` 只是**可信度
   标签**（"该 backend 有真实 e2e 记录"），**默认不参与** `ready`，也不是派发的前提条件。
   `trusted=false` 仍可派发，但汇报必须写 `unverified` / `trust_level`，不得写成"已验证"。

   `ready=false` 要读子项再分诊，不同故障面的动作不同：

   | 子项为假 | 故障面 | 动作 |
   |---|---|---|
   | `git` | 宿主机缺工具 | 装工具 |
   | `checks_preflight_ok` | 项目 checks 配错（`unresolved` / `invalid`） | 改 `checks[*].argv`（见下） |
   | `placeholders_ok` | 配置没填完 | 填 `REPLACE_WITH_*` / `<FILL:*>` / `/absolute/path/to/*` |
   | `platform_lock` / `platform_tree` / `process_identity` | 平台层不可用 | 停止派发，先修平台层 |
   | `trusted`（仅严格项目） | 无真实 e2e 记录 | 补 `compatibility_evidence`，或改用**已获准且已验证**的候选 |

   `checks_preflight` 只有 `unresolved` / `invalid` 计入 `ready`；`ok` / `shell` / `deferred`
   都不阻断，`deferred` **只表示推迟确认**（不算配置错，也不代表本次一定跑通）。检查跑在
   **任务 worktree**、`argv[0]` 走 supervisor 的 PATH；`doctor` 预检用的是项目 `repo` 与自身
   PATH——两处 cwd 与 PATH 都可能不同，别把预检当成执行环境的证明（见
   [runtime-contract.md](references/runtime-contract.md)）。

   严格项目缺 e2e 记录时，**不要**把"去掉 `require_real_e2e`"当排障动作：那是用户改变项目
   政策，需要明确决定并重新 `register` + `attest`。
   `doctor` 通过只说明它覆盖的环境条件满足，**不**说明 Spec 合法，也不说明任务一定能启动。
   `create` 报 `ENVIRONMENT_ERROR: doctor reports not ready` 时，读候选级 `code` /
   `details.gaps`（或重跑 `route plan` 看每个候选），不要在同一个环境下重试 `create`。
   运行环境未就绪时完成可独立进行的 Spec/任务草案，明确「未派发」，
   不改用裸 Agent 绕过。无法查询时显示最后已知状态及时间。

   候选上的 `ENVIRONMENT_ERROR` **要三步诊断，不要凭猜测直接换 profile**：

   1. **先看是什么**：`route plan --json`（或 `create` 的 `details`）里 `candidates[]` 的
      `detail` —— `probe budget exhausted`（探测预算用完，**不是环境坏了**）、
      `doctor reports not ready`（六项合取有一条为假）、`agent CLI not resolved on this host`
      （二进制找不到，**不是"没装适配器"**）。三个来源的处置完全不同。
   2. **再分静态/动态**：`route plan --json --no-probe`。它成功只说明"不探测时静态规则通过"，
      **不能**证明 CLI 可执行、依赖完整、模型可用，也不能单独证明是预算问题。
   3. **再单独验该候选**：`zoe doctor --project P --agent-profile <候选> --json`，读 `checks` /
      `resolution` / `resolution_notes` / `policy_problems`，并自己计时（doctor 目前不输出
      探测耗时）。只有多次观察都指向"探测慢"，才谈得上优化探测。

   显式指定时候选只有一个：那时的 `ENVIRONMENT_ERROR` 只说明**这一个**候选不可用，不能读成
   "整份白名单不可用"。换执行配置只能由用户决定；要固定默认档就改**项目配置**
   （`routing.mode` / `default_agent_profile`），改完必须重新 `attest`，在途任务 `rebind`。
3. **形成 Spec。** 调研相关代码和仓库规则；只问会改变权限、数据、兼容或主要方案的问题。
   提问分三段，一段一句：背景（已有什么，**能读到的自己读，不拿来问**）、要求（产出物 +
   格式 + 给谁看）、边界（哪些不做、缺数据写什么）。缺哪段就问哪段，不要用猜测把空位填满。
   定义 AC 编号、非目标、实际验证方法、允许修改范围、交付模式和已获授权。
   验收标准按三层写，不要合并成一句「命令或人工步骤」：自动检查（`type=check`）、
   自审项（`type=manual`）、集成场景（`type=manual`）；后两层的判者不能是产生该改动的
   同一个上下文，写法见 [spec-template.md](references/spec-template.md)。

   **交付类任务用 spec v3，把"验收由谁判"写进契约**（`schema_version: 3`，细节见
   [spec-template.md](references/spec-template.md)）：manual AC 必填 `verification.judge`；
   机器能判的那一半挂 `verification.supporting_checks`（只能引用项目已批准的 check——
   spec 内联 shell 命令不执行、也不进证据）；声明 `acceptance_review: {"required": true,
   "independent": true}`；用 `progress_refs` 把 AC 绑到需求文档的复选框（`doc` 必须在
   `allowed_paths` 内）。设计裁定写 `decisions`，`open` 阻断 accept
   （[decision-record.md](references/decision-record.md)）。

   **一条 AC 至少要能证伪**：在 `base_sha` 上它必然失败；否则它只是"复述现状"。

   **上游依赖写进 `depends_on`**（marker 列表）：`start` 要求上游 `DONE` +
   `accepted` + 判定满足，否则 `DEPENDENCY_NOT_MET`（5）。复核类任务必须声明。
   用户明确强调、以及还没答的待决问题各占一节：待决问题阻塞的必须先答，不阻塞的带着走，
   执行期变成阻塞再走 `task answer` / `task revise`。
   结构化 spec 的 `verification.check_id` 必须来自项目批准的 checks；
   `allowed_paths` 只能收紧。

   **Spec 必须是结构化 JSON，边界必须到文件级。** 纯 Markdown spec 虽然能 create，但它会被
   解析成 `contract_version=1, document=null`：`allowed_paths` 读不到 ⇒ 任务范围回落到项目级
   （整个仓库可写），`SCOPE_VIOLATION` 永远不会触发，Markdown 里写的「允许路径」一个字都
   不生效。交付类任务一律用 [spec.example.json](references/spec.example.json) 的结构；只有
   纯调研/纯说明任务才允许 Markdown-only。
   并行批次（同一波次 ≥2 个任务）里 `allowed_paths` 必须是**文件级**：只写包名等于没写边界。
   `prepare` 会对目录级条目给出 `SCOPE_DIRECTORY_LEVEL` 告警——串行任务可以忽略（整包改动
   是合法需求），并行批次里它等同阻断。
   需要只验一部分 checks 时，在 spec 里声明 `verification_scope.checks`（例如
   `["lint","slice_a"]`）；未列入的 check 记为 `NOT_RUN`，**不是通过也不是失败**，
   汇报和合并门禁都必须说明「项目级验证未执行」。
   业务规则可脱敏下发，原始敏感资料不下发。

   **写完不要直接 create**：先做一次只读准备，一次看完所有问题。

   ```
   zoe task prepare --project <id> --spec <file>     # 已注册项目
   zoe task prepare --repo <path> --spec <file>      # 未注册：匹配已注册项目，或给出注册草案
   ```

   - `prepared: true` 只表示**本次快照下**通过；create/start 会复核，条件变了会报明确诊断。
   - 读 `diagnostics[]`（`code` / `field` / `reason` / `suggested_change` / `requires_approval`）。
     `requires_approval: true` 一定是扩权，必须人来批；你不许改写成"已完成"。
   - **同一项目只注册一次**：已注册就不必再 `project register`，直接 `--project`。
   - 没有现成 spec 时用 `--emit <dir>` 生成草稿（只有一份最小模板）再填 `<FILL:...>`；
     占位符没删干净时 create 会拒绝——这是设计意图，不是 bug。
   - `--emit` 生成的 `create.json` 里 `request_id` 是 UUID；不要复制别人的 `request_id`
     （会撞 `REQUEST_CONFLICT`）。**复用规则按"上次请求落成没有"分，不是按任务分**：
     - 结果未知（传输失败、没看到响应）：同 `request_id` + 同载荷重放，幂等返回原结果；
     - 已经落成一条失败记录（`SLOT_BUSY`、`STATE_CONFLICT`、`ENVIRONMENT_ERROR`、
       `POLICY_*`、`AUTH_*`）：该 id 已被绑死在那条失败上，重放只会拿回上次的失败，
       **必须换新 id**；
     - `TASK_BUSY`（写者锁被占）：请求行没落地，**原 id 原载荷重放**才对；
     - `REQUEST_CONFLICT`：**不重试**。它表示这个 id 已被另一个 `task`/`action`/载荷占用，
       重试永远不会成功——先查清为什么会重（多半是请求文件配错了任务）。错误体的
       `details.existing` 会指出占用者。

   **派发闸门（create 之前，逐条核过才算过）**：

   1. `task prepare --project P --spec spec.json` 返回 `prepared: true`，且
      `diagnostics[]` 里 `requires_approval: true` 的项都有明确的人类批准记录；
      `CHECK_ESCAPES_WORKSPACE` 必须为空——它表示某个 check 把自己的工作目录钉到了
      worktree 之外（`cd /abs`、`git -C /abs`、`--cwd=/abs`），于是"验证"跑在另一棵树上，
      而 exit code 被记到这个候选名下。这种通过比失败更难发现；
   2. `profile.conflicts` 为空（未知 profile、`MODEL_PIN_CONFLICT` 都在这里出现）；
   3. 本批次要并行的每一片，与在途任务的重叠已分类并处置（见第 4 步的重叠预检）；
   4. 项目声明了 `routing` 时，`route plan` 的候选集合与预期一致（见第 2 步的三步诊断）；
   5. 并行批次：`allowed_paths.warnings[]` 里没有 `SCOPE_DIRECTORY_LEVEL`（有就先把范围
      收到文件级再 create）。

   缺任一条就**不要 create**：`create` 会重算并拒绝，但只给"第一个错误"；`prepare`
   给的是一次看全。两者信息量不同，不能互相替代。

   注意 `prepared: true` 只表示"没有阻断性问题"，**不保证 `start` 成功**：后面的准入
   （策略摘要、attest、owner、槽位）是另一组条件。

4. **拆分（仅在收益明确时）。** 先分清要的是**一次交付**还是**吞吐**，两者收口方式不同：

   | 模式 | 适用 | 派发 | 收口 |
   |---|---|---|---|
   | **任务组交付** | 需要一次完整交付 + 一次组级验收（含设计一致性审查） | `group create` → `group start`，成员由组冻结快照创建 | `group accept`（**组内串行**，见 `runtime-requirements.json` 的 `group_serial_execution`；不要期待并行吞吐，推进器退出后需 `group resume`/`start` 续跑，`watch` 不推进） |
   | **独立任务并行** | 需要吞吐、各片独立可交付、集成由人安排 | 独立 `task create` + `start`，数量 ≤ `max_active_tasks` | 各自 `task accept`；集成/合并另行安排 |

   **不要把两者拼起来**：`group accept` 只认组内成员，成员绑定发生在 `task create` 时
   （必须带 `group_id` + `item_id`），事后没有任何命令能把独立任务"加入"组。独立任务
   也不会自动变成可组验收的成员。

   **先分清是"改代码"还是"下结论"。** 做错时表现为**结论争议**而非代码失败的需求
   不可派发：设计裁定写 `decisions`（[decision-record.md](references/decision-record.md)），
   不 create；复核类 `allowed_paths` 只含报告文件、`acceptance_review.independent` 必须
   为真；被复核的裁定文件（`docs/DEC.md` 一类）放进 `protected_paths`，worker 一动即
   `SCOPE_VIOLATION`。

   并行前过**四条硬前提**（任一不满足 → **分波次或按依赖串行**，而不是合成一个大 Spec）：

   1. 没有「A 的产物是 B 的输入」的代码依赖；
   2. 每片有独立 AC 与可执行 check（或明确的 `verification_scope.checks`）；
   3. **运行期副作用不冲突**：共享数据库/实例、固定端口、外部服务、共享生成目录、全局缓存
      ——独立 worktree 只隔离工作区文件，隔离不了这些；
      **共享集成点（入口注册/路由表/schema 索引）不是"副作用"而是结构性冲突**：它属于
      多片必经的同一处改动，按 [decomposition-patterns.md](references/decomposition-patterns.md)
      的「模式二之一：共享集成点」处理（前置 scaffold / 末尾接线），不要靠"记得小心点"，
      也不要靠把入口文件从 `allowed_paths` 里删掉——Worker 仍会改它，然后以
      `SCOPE_VIOLATION` 收场；
   4. 有明确的集成本体（谁合、按什么顺序）与独立判者。

   `allowed_paths`/`expected_paths` 重叠是**集成风险提示**，不是拒绝理由：可用
   `group plan` 只读预演看警告，再决定排两个波次或指定合并顺序。切片形状见
   [decomposition-patterns.md](references/decomposition-patterns.md)。
   同一任务永远只有一个写者。

   **并行重叠预检：这是风险分级，不是互斥保证。**

   `prepare` 不做这件事（它不构造 Store，看不到在途任务）：

   ```
   zoe task list --project P --fields task_id,state,phase --json    # v1.6：只取需要的字段
   zoe task status T --json --refresh        # 读 task_scope / state / phase
   ```

   任务记录里带冻结的 `config` 副本，任务多时整包输出既慢又容易把配置当状态读；`--fields`
   只做投影，字段名拼错会直接报 `INPUT_INCOMPLETE`（不会静默返回 null）。

   判据按 `_paths.covers` 语义（目录前缀包含 / 路径相同）；`task_scope` 为空表示沿用
   项目范围，此时按**项目范围**比较（保守取大）。

   | 分类 | 判定 | 处置 |
   |---|---|---|
   | `OVERLAP_WARNING` | 共享源码路径，但各自 worktree 可安全开发 | 可并行；把"合并顺序 + 谁负责解冲突"写进本批计划 |
   | `INTEGRATION_REQUIRED` | 共享入口/注册表/schema 索引 | 走「模式二之一」的 A/B，不靠"记得小心点" |
   | `EXCLUSIVE_RESOURCE` | 共享外部可变资源（固定端口、测试库、生成目录、远端环境） | 必须串行（同一时刻只跑一个） |

  **共享路径要计数，不要只看"有没有重叠"**：同一文件被 3 个以上候选触及就按共享集成点
  处理（前置 scaffold 或末尾接线），而不是只排合并顺序。计数命令、按触及数分档的处置，
  以及"静态快照不提供互斥"与 `shared_resources` 不排队这两条限制，见
  [decomposition-patterns.md](references/decomposition-patterns.md) 的「共享路径计数」。

5. **派发。** 读取 CLI 契约；先 list 查重复，再 create 冻结 Spec（记录 `agent_profile`
   与来源），再 start。需要路由时给 `route.task_type` 与 `route.requirements`（字段见
   [create-request.routed.example.json](references/create-request.routed.example.json)），
   由 runtime 决策；`route` 要求项目 `routing.mode=auto`，`explicit` 项目里出现它会以
   `INPUT_INCOMPLETE` 拒绝（不静默忽略），所以不要把它加进最小示例。`task_type` 的取值顺序
   是「请求 → Spec 文档 → `unknown`」，不传不代表一定是 `unknown`。
   只有用户已明确指定执行配置时才传 `agent_profile`。角色（实现 / 评审 / 调研）不降低准入门槛，
   也不构成自动授权的理由（准入与白名单见「执行配置与模型授权」）。代码依赖须进入该任务基线；上游「已结束」或「可评审」不足以启动
   下游。用 JSON 文件传参，保留请求 ID 和真实返回 ID，不直接写状态库或管理 Worker 进程。
   需要拆分时按第 4 步选模式：**任务组**（见下文「用任务组交付」）负责顺序、串行集成与
   一次验收；要并行就用**独立任务**，各自收口，不进组。**旧有序组**只做记录，不调度，
   下一项要显式 `group dispatch`。没有一条路是"自动并发"：同一任务永远只有一个写者。

   **多任务派发用脚本，不写 for 循环。** `task start <TASK>` 的主体（task）来自 argv、
   幂等键（request_id）来自请求文件，两者可以静默错配：同一份文件配到第二个任务上就会
   返回 `REQUEST_CONFLICT`，而它过去既不说是谁占用了那个 id，也不说该怎么办。

   ```bash
   bash <skill-dir>/scripts/zoe-batch-start.sh --project P --plan .zoe/P-batch.json
   # plan.json: {"items":[{"task_id":"task-…","label":"T9a"},{"task_id":"task-…","label":"T9b"}]}
   # 产物：.zoe/P/batch/results.jsonl（每个任务一行 NDJSON）+ manifest.jsonl（文件↔任务的绑定）
   ```

   它做三件人手工做不稳的事：请求文件由脚本生成并绑到具体任务、按失败码分流（见第 3 步
   的复用规则）、结果逐条落盘（不依赖 stdout 累积，不会只剩最后一条）。它**只派发**：
   受理之后仍要按第 6 步核对状态。`--wait-slots N` 用于槽位满时等一会儿再换新 id 重试。

   **`start` 成功后立即进入监控**（第 6 步），不要把"要不要我继续盯"留给用户。
6. **观察与监控。** 用 `watch --follow` 消费增量事件，用 status --refresh/reconcile 与
   task events 补证据。accepted 仅表示受理：不等于已派发，也不等于已在运行
   （`dispatch_pending: true` 就是"还没确认"）。RUNNING 还需结合 Run 状态
   （adapter/backend/结果 schema）；退出码 0 不等于业务完成。不编造进度百分比，
   不把 Agent 自述当验证。

   **派发成功后默认进入监控循环，"要不要我继续盯"不是该问用户的问题。** 循环本身是有界的。
   脚本化是**首选实现，不是唯一实现**：要求是**可续读（游标）+ 可判断（状态快照）**，
   而不是"必须跑某个脚本"——`bash -c` 也不是 Windows 或 PATH 问题的解法。

   本节只写每个回合都要用的判定；**异常分支与低频语义**在
   [monitoring-playbook.md](references/monitoring-playbook.md)（`--with-log` §1、续期算法 §2、
   `[tick]` 与 digest §3–§4、`--stop-file` §5、空候选 §6、游标边界 §7、事件过滤 §8、
   日志判读与 `empty_reason` §9、`zoe-watchd.sh` §10、无脚本时的等价协议 §11）。

   #### 6.1 启动：游标按项目/目标集合隔离

   ```bash
   # 每个项目/目标集合用自己的状态目录：游标与事件文件不要与别的项目共用
   # （脚本不会自动建目录，先 mkdir -p .zoe）
   mkdir -p .zoe
   ZOE_BIN=$(command -v zoe) \
     bash <skill-dir>/scripts/zoe-monitor.sh \
       --project P --targets "T1 T2 T3" --interval 10 \
       --cursor-file .zoe/P-cursor.txt --events .zoe/P-events.jsonl
   ```

   ```powershell
   # Windows 同语义实现（事件解析用 ConvertFrom-Json，不依赖 jq）
   pwsh <skill-dir>/scripts/zoe-monitor.ps1 -Project P -Targets "T1 T2 T3" -Interval 10 `
     -CursorFile .zoe/P-cursor.txt -Events .zoe/P-events.jsonl
   ```

   预算别拍上限：能拿到宿主剩余秒数就传 `--deadline-in N`（脚本按
   `min(剩余-guard, max-seconds)` 反推并打印 `[budget]`），拿不到再用 `--max-seconds 600`
   并在汇报里注明"这是假设值，不是测得值"。`effective < 45s` 时脚本**直接不启动**。

   #### 6.2 观测到 X → 动作 Y

   | 观测到 | 动作 | 为什么不能想当然 |
   |---|---|---|
   | `accepted`、`dispatch_pending: true` | 继续 watch，不判失败 | 受理 ≠ 派发，也不等于在跑 |
   | `RUNNING` 但无事件 | 插一次 `task status T --refresh` 读 `progress` | 空返回是心跳，不是卡死 |
   | `process_state=alive` | 继续监控 | 进程在；字节/阶段不动不等于卡死 |
   | `observations_stale=true` | 重新对账 | **监控进程自己失联**，不是任务失败 |
   | `BLOCKED` / `PAUSED` / `INPUT_REQUIRED` | 只标记该目标，继续盯其余目标 | 除非全部目标都停在需人介入 |
   | `REVIEW_READY` | `task report` + 交人工验收 | 独立任务的 `REVIEW_READY` 不是终态 |
   | `REVIEW_READY` + `empty_diff=true` | 汇报写"零改动可验收"，**不写完成** | PASS 只证明基线本来就能过 |
   | `QUOTA_EXHAUSTED` | 立即停止新派发，出 `handoff`，等 `quota_reset_at` | 恢复顺序**不含 resume** |
   | 全部目标 DONE / CANCELLED | 进入 6.5 核对 | `CANCELLED` 单独写，不并入"完成" |
   | 预算耗尽 | 贴 `[renewal]` 原样续跑 | 预算到期不是完成 |

   **空返回是心跳，不是异常。** `--follow` 这一轮没有任何事件时只有首/末两行 `kind=meta`
   的游标行、退出码 0，含义只是"期间存在的事件里没有匹配项"（有界查询则是一行
   `cursor_status=heartbeat` 的 meta）。不得把它读成"卡住了/没进展/该问用户了"而提前收尾
   ——这正是过去汇报完就终止的那条路径。`quiet_seconds` 变大只说明没输出，**不等于卡死**。

   **退出条件逐目标判定，不要"任一完成就收尾"**：① 全部目标到达终态（DONE / CANCELLED）；
   ② 某个目标进入 BLOCKED / PAUSED / `INPUT_REQUIRED` 时**只标记该目标**并继续监控其余
   目标，除非全部目标都停在需人介入；③ 出现真正需要用户拍板的点（业务歧义、范围扩大、
   缺权限、验收）；④ 监控预算耗尽。第三、四类退出必须交回游标与续接命令，让人能接着盯，
   而不是留下一个开放式提问。

   监控循环里不重复 start/resume（写者占用、`TASK_BUSY`），不把"轮询很烦"当提前收口的
   理由。只有在 `watch` 不可用时才退化为 `status --refresh` 的有界间隔轮询，退出条件不变
   （等价协议见手册 §11）。

   #### 6.3 退出码与 `[stop]` 分流

   **退出后必须做一次状态核对**，因为脚本的正常退出有两种含义，不能都当完成：

   | 退出码 / 末行 | 含义 | 动作 |
   |---|---|---|
   | `0` + `[done] all targets final` | 全部目标到达终态（DONE/CANCELLED） | 逐目标汇报；`CANCELLED` 单独写，不并入"完成" |
   | `0` + `[stop] max rounds reached` / `[stop] max seconds reached` | **预算到期，不代表完成**（`reason=BUDGET_EXHAUSTED`） | 读同一批输出里的 `[renewal]`：原样执行下一段（或按 `owner` 交给 `host-cron`/`human`）；`task status --refresh` 逐个核对后写待办队列，**不写"已完成"** |
   | `2` | 用法/依赖错误（缺 `jq`、缺 `--project`、`zoe` 不可用） | 回退到 `watch --follow` + `status --refresh` 协议继续监控；**不得**把运行中的 Agent 报成故障 |
   | `10` | 剩余目标都需要人工介入 | 按 `[needs-human]` 行分流：`INPUT_REQUIRED` → `task answer`；`BLOCKED` 看 `block_code`；`REVIEW_READY` → `task report` + 提交人工验收；**`empty_diff=true` 单独处置（手册 §6）** |
   | `11` | `zoe watch` 连续失败达上限 | 修可达性后带 `next_cursor` 续跑；"读不到"不等于"还在跑"，也不等于"失败" |

   `[stop] reason` 的取值语义、`--stop-file` 的 JSON 字段、脚本内部要点见手册 §5。
   三条前提不变：**监控器正常退出 ≠ 任务完成**；**任务进入终态 ≠ 任务成功**（终态只回答
   "不会再自己前进"，成功由验收结论回答）；游标按项目/目标集合隔离，处理完事件再推进游标，
   重启时**先读游标**、为空才初始化（脚本是这么做的，宿主侧协议同）。

   #### 6.4 续期单：让出必须带 `[renewal]` + `owner`

   回合必须让出时（宿主单回合时长上限、用户打断、监控预算耗尽）不要以提问结尾，改为结构化
   交接：当前 `next_cursor`、相关任务的 state/phase/run_id、最后事件时间、续接命令，**外加
   一张待办队列**——每行 `动作 | 对象 | 依据`，例如：

   ```
   merge               | T1 candidate_sha=ab12 | REVIEW_READY 且 checks 已跑（≤1 条行动）
   rebind→resume       | T2 run_id=run-9f      | POLICY_CHANGED，旧证据失效
   project quota clear | P                    | QUOTA_EXHAUSTED，且已过 reset_at
   ```

   **不要用"其余按计划继续"代替队列**：那不是交接，是让下一回合把同一批事实重新发现一遍。
   下一回合用 `watch --after <cursor>` 直接接上，不重新全面查询再问"要不要继续"。
   同时写明 **`owner`**（只给游标不给 owner，等于把"谁来续"留给下一个人猜）：

   | owner | 谁执行续期 | 前提 |
   |---|---|---|
   | `next-turn-agent` | 下一个回合的 agent 用 `[renewal]` 里的命令续跑 | 会话仍在 |
   | `host-cron` | 宿主定时任务（平台能力，需用户授权后创建） | 会话可能关闭 |
   | `human` | 人；只在 `WATCH_ERROR` 或需要判断时选 | 其余情况不得推给用户 |

   脚本退出时已打印 `[renewal] owner=… cursor=… cursor_file=… command="…"`，汇报里
   **原样贴出**，不要改写成"稍后继续监控"。**不承诺**"我会继续盯着"：会话关闭后没有人会
   自动继续监控——除非 `owner=host-cron` 且调度任务已真的创建成功。预算反推的算法与
   "不要用 `--max-seconds 0` 交回回合"见手册 §2。

   #### 6.5 终态核对：`task status --refresh` 才是权威

   - **终止判断读 `task status --refresh`，不读事件历史。** 历史事件里的 `DONE` 不代表当前
     状态；用事件判终态会让监控在启动瞬间被旧事件击退。
   - 终态之后仍要 `task report` 取验收结论：`ALL_TERMINAL` 可以进入汇报，但"成功"由验收
     结论回答，不由终态回答（第 9 步）。
   - `empty_diff=true` 汇报为"零改动可验收"，处置见
     [delivery-policy.md](references/delivery-policy.md) 的「空候选」与手册 §6。

   #### 6.6 动作线：`task logs` 只证明"动过"

   要看 Agent 在做什么，用动作线（与状态线并行，不替代它）。三条事实：
   ① `--follow` 不带 `--tail-bytes` 时**从当前末尾**开始，中途接入看不到之前的进展；
   ② 只有 `kind=text`（说了什么）与 `kind=tool`（动了什么）算可读进展，`kind=record` /
   `kind=raw` 都不是"没有输出"；③ 日志行按**字节**定界，投影只吃**完整行**。

   ```bash
   bash <skill-dir>/scripts/zoe.sh task logs TASK --after "<cursor>" --json   # 增量，非阻塞
   bash <skill-dir>/scripts/zoe.sh task logs TASK --follow --tail-bytes 65536 --projection auto
   ```

   **`task logs` 没有 `--project`**（那是 `watch` 的），也**没有 `--jsonl`**（`--follow`
   本身就是一行一个 JSON）；换 `--run` / `--log` 必须丢弃旧游标。`text`/`events` 同时为空
   时先读 `empty_reason` 再下结论，不要报"日志读取有 bug"——五分支判定表见手册 §9。

   #### 6.7 汇报四档

   分四档，缺任何一档都不算"在监控"（四档都是文字产出，不是额外的工具调用）：

   | 档 | 时机 | 必须包含 |
   |---|---|---|
   | 启动拍 | 派发后第一次汇报 | 派了什么、为什么这样切、本批共享路径有哪些、哪些任务在等槽位 |
   | 进度拍 | 每 8–10 分钟，或任一任务 state/phase/block 变化 | 一版 digest：每任务的 state·phase·耗时·静默·字节 + 最近一条文本 + 最近一个动作 |
   | 终态拍 | 全部目标到终态或需人工介入 | AC 表 + 合并门禁 + `NOT_RUN` 与未验证项 |
   | 配额拍 | 任一派发/恢复返回 `QUOTA_EXHAUSTED`，或 digest 里出现该 `block_code` | **立即停止新派发**；一版 digest + 每任务 `handoff` 的 `worktree_path` / `run_id` / `quiet_seconds` / `quota_reset_at`；恢复顺序（**不含 resume**） |

   进度拍的内容来自 `scripts/zoe-digest.sh`（一次进程输出整张表），不要用"任务在跑，
   等我汇报"这类句子代替：

   ```bash
   bash <skill-dir>/scripts/zoe-digest.sh --project P --targets "T1 T2 T3"
   bash <skill-dir>/scripts/zoe-digest.sh --project P --since .zoe/P-since.json   # 只报变化
   ```

   也不要为了凑内容每轮重贴同一行——`[log]` 与 digest 都只报**新增**。
   **过程观察进汇报，但不进结论**：`动：Edit src/config.py` 是"动过这个文件"，不是"写成功"；
   `说：正在抽查 wall-clock 分支` 是 Agent 的自述，不是验证。两句同时成立，不能用"过程观察
   不是证据"一句话取消汇报义务，也不能用"它说改了"顶替 check 结果。
   检查点节奏：每 5 轮或约每 5 分钟输出一行极简进度（`next_cursor` + state/phase +
   `changed=N`）；`changed=0` 时不要展开 digest。只在**状态或阶段变化、新阻断、Agent 提问
   待回答、到达终态**时汇报，不要每轮重贴一遍快照。

   #### 6.8 会话之外：只读守护

   `zoe-monitor.sh` 是前台有界循环，回合结束即消失。会话关闭后仍要可查时用
   `zoe-watchd.sh start/stop/status`：**只读**常驻守护，变化写 `live.jsonl`、快照写
   `live.md`；不 start/resume/accept（脚本内部拦截，调用即 `exit 70`），不替代合并判断，
   只记录、不推进——无人值守推进需要宿主定时任务。用法与三条边界见手册 §10。

7. **恢复。** 接手一个项目时先执行 `orchestration resume --project P --json`（必要时
   `project context`）读取目标、已派发、等待对象、待答问题与下一步，**不依赖聊天记忆**；
   再对账旧进程、工作区和远端结果，按 recovery-policy 继续未完成阶段。
   不重复启动活跃或存亡不明的写者，不把 PR/CI 故障交回编码 Agent 重写代码。

  **额度耗尽不是恢复问题，是停止问题**（详见
  [recovery-policy.md](references/recovery-policy.md) 的「额度耗尽」）。三条硬规则：
  ① **不要用 `resume` 试探额度**——闸门会拒，未触发时它会真的启动一次 Agent，两种结果都浪费；
  ② 派发即登记、回合末跑 `task digest` / `task handoff show`（本地 CLI，不耗额度），不要等
  耗尽再收尾；③ `quota_reset_at` 过了也**不自动解锁**，必须
  `project quota clear --project P --why "..."`，它只记录人的决定，不验证额度。
  `capabilities.features` 不含 `quota_gate`（runtime < 1.6）时按前两条执行，只是没有"拒绝
  resume"的机械保证——**不要**因为少一个字段就把 `resume` 当成可以试的动作。

   `task recover TASK --confirm-stop` 的语义是"**我确认旧执行已停止**"，不是"我看不到进程"。
   可用的依据包括：`task status --refresh` 的 `progress.process_state=exited`、`task events`
   里该 run 的退出记录、进程树探测为空、写者锁可获得。观测不到（`unknown`）**不构成依据**：
   此时 `recover` 返回 `PROCESS_UNKNOWN` 且不释放配额，继续对账，**不要**起第二个写者。

   收口后统一是 `BLOCKED` + `block_code=RUN_INTERRUPTED`，**不能直接 accept**（`accept` 要求
   `state=REVIEW_READY`、`subject_sha == validated_sha`、工作区指纹未变）。要按 `phase` 与
   有效证据决定**本次从哪个阶段继续**（不是"决定是否永不重跑"）：`phase=acceptance` 且
   `candidate_sha` 与 `validated_sha` **均非空且相等**、证据可校验时才 `resume` 直接到
   `REVIEW_READY`；`verify` 失败的检查仍可能需要返工。两个空 SHA **不能判等**
   （`null == null` 不构成"已验证"）。对照表见
   [recovery-policy.md](references/recovery-policy.md)。

   Agent 提问（`BLOCKED/INPUT_REQUIRED`）时用 `task answer` 记录回答；回答只解除阻塞，
   改验收标准须 `task revise`，否则显式 `task resume`。关键节点用 `task summary submit`
   留一份绑定 `through_event_id` 的可读摘要，不要让摘要覆盖控制器状态。

   **resume 用两段式入口，不要手拼请求体**：`task resume` 的请求要
   `schema_version` / `request_id` / `expected_version` / `authorization_ref` 四要素，
   幂等键是 `digest([action, task, request])` —— 同一个 `request_id` 改了载荷不是"重试"
   而是 `REQUEST_CONFLICT`。因此：

    ```bash
    # 1) 只看不提交：脚本自己跑 status --refresh 取**这一次**的 row_version
    bash <skill-dir>/scripts/zoe-resume.sh preview --project P --task T --reason "RUN_TIMEOUT 后继续"
    # 2) 摘要无误后再提交（原样提交那个文件；重放同一文件是幂等的）
    bash <skill-dir>/scripts/zoe-resume.sh apply --request-file .zoe/P/requests/resume-T-<id>.json
    ```

   `preview` 会在**生成请求之前**拦下 `INPUT_REQUIRED`（先 `task answer`）、
   `PROCESS_UNKNOWN`（先对账 + `recover --confirm-stop`）和不可恢复的 state（`exit 3`，
   不产生文件）；`apply` 先核对文件自身的 `self_sha256`（被手改过就拒，尤其是
   `expected_version`），撞 `STATE_CONFLICT` 只提示"重跑 preview"，**不会**自动改用新版本。
   传输失败/响应丢失时重放**同一个文件**（幂等）；确定是新意图才重新 `preview`。

8. **变更。** 运行中先 pause 并核实安全停止，再 revise 保存新 Spec；保留旧版本。
   需要换执行器时走 `task reassign`（目标 profile 须满足项目准入策略，工作区指纹一致）；
   项目策略变化后用 `task rebind` 显式接纳，旧证据失效。人工改动后旧验证失效。
   不要 reset/clean、删除失败工作区或 force-push。

   **只放宽 `allowed_paths` 时不要 cancel 重派**（那会把已写好的工作区当废料）。先读
   `scope_source`：`spec` 分支改项目配置 + `rebind` **不动** `task_scope`，下一轮必然再撞
   同一个越界；`project` 分支才走 `register` + `rebind`。`spec` 分支用两段式入口，它复用
   工作区——runtime 发现只改了 `allowed_paths` 时直接进 `verify`，不再跑一次 Agent：

   ```bash
   bash <skill-dir>/scripts/zoe-revise-scope.sh preview --project P --task T \
     --add-path docs [--add-path "tests/test_x.py"] --reason "SCOPE_VIOLATION 后放宽范围"
   bash <skill-dir>/scripts/zoe-revise-scope.sh apply \
     --request-file .zoe/P/requests/revise-scope-T-<id>.json
   ```

   `preview` 只落盘请求文件、**不提交**；`apply` 用 `self_sha256` 核对"提交的还是你看过的
   那一份"。退出码 `0`/`2`/`3`/`4`，其中 `3` 表示前置条件不满足（**未生成也未提交**，
   含 `scope_source=project`、state 不可修订、run 未收口），`4` 是运行时拒绝且不自动补救。
9. **收口。** 使用 delivery-policy 检查当前版本的本地验证、证据、CI、人工评审、合并和验收。
   不自行批准合并或验收；区分执行结束、可评审、已合并、已验收和已上线。
   报告按 report-template 输出，必须含「执行期间做出的决定」与「需要人工验证的事项」两节；
   manual 项没有独立判者的写 `pending`，不写成通过。

   **验收有两层**：第一层 checks（exit code + 证据复算），第二层 `task review` 的逐条 AC
   判定（绑定 `validated_sha`、全覆盖、判者独立）。`ACCEPTANCE_UNREVIEWED` 表示第二层
   没做——补判定，**不要**去掉 spec 字段绕过（那是改需求，要人批）。`NOT_VERIFIED` 必须
   在验收请求里 `acknowledged_not_verified` 逐条确认，默认放行等于把"没判"当成"判过了"。

   **合并门禁（`local_artifact` + 无 CI 时不能省）**：这类项目没有 CI/PR 门禁，合并前的验证
   只能由本会话执行，**不能**用"worker 自测过了"替代——worker 的 verify 只证明它自己的
   worktree（前提是 checks 没把 cwd 钉到别处，见第 3 步的 `CHECK_ESCAPES_WORKSPACE`）。

   1. 一次只合一个候选，**合完立刻跑全量 checks**（不是全合完再跑）；
   2. 跑在**集成分支**上，不是各任务的 worktree；
   3. 记录 `integration_sha` + 每个 check 的 exit code + 日志路径，写进报告；
      先看 `concurrent_base`：`kind=overlap` ⇒ 合并后必须重跑全量、不复用候选证据；
      `kind=reverts` ⇒ 候选删掉了别人刚改过的文件，**停下交人**（不是冲突，是丢改动）。
   4. 任一 FAIL ⇒ 停在集成分支，不进 main。修实现（或由人确认的契约变更），不"改测试变绿"；
   5. 报告写「项目级验证已执行」或「未执行」，不写"应该没问题"；
   6. **逐条 AC 核对**：`bash <skill-dir>/scripts/zoe-ac-gate.sh --task TASK` 退出码 0。
      「未记录逐项人工结论」「NOT_VERIFIED 未确认」「无本期证据」任一即失败——它们的共同
      点是**看不出来做没做**。也在**集成分支**上跑，任务 worktree 的通过只证明那棵树；
   7. **清单清零看命令**：`zoe task coverage --project P --markers-file F` 的 `cleared`
      为真。它只把「DONE + accepted + 逐条判定满足」算 covered，`REVIEW_READY` 一律
      pending。**不得**用自己推断的编号映射宣布清零。

   多片共享同一处行为契约（例如同一个接口签名）时，各片单独通过不代表合起来通过：这类批次
   应改用**任务组**（`group accept` 在 `integration_sha` 上跑组 checks），而不是独立任务并行
   加手工合并。

### 用任务组交付

组的价值是**顺序 + 集成 + 一次验收**，不是"多开几个 Agent 更快"：组内串行执行（v1.3 引入，当前版本仍由 `runtime-requirements.json` 的 `group_serial_execution` 保证），同一时刻
只有一个成员在跑。细节、字段与异常处置见 [group-delivery.md](references/group-delivery.md)。

两条硬约束，写在这里避免误用：

- **组内成员不能自验收**：成员调 `task accept` 会被 `STATE_CONFLICT` 拒，验收只能 `group accept`。
- **独立任务不是组成员**：成员绑定只在 `task create` 时发生（`group_id` + `item_id`），
  没有"事后绑定"的命令。所以「并行跑几个任务，最后 group accept 一次」在本版本 **不成立**；
  要并行就各自 `task accept` 并显式安排集成（合并后的结果仍需一次集成检查）。

```text
group plan --project P --request-file plan.json   # 校验 + 路由预演，不写任何东西
group create --request-file plan.json             # 冻结计划，仍不派发
group start GROUP --request-file start.json       # 起后台推进器，父进程立即返回
group status GROUP --refresh                      # 有界对账（不推进）
group resume GROUP --request-file resume.json     # 推进器停止后续跑（先 reconcile 再换租约）
group review GROUP --request-file review.json     # 设计一致性审查结论（计划要求时必需）
group accept GROUP --request-file accept.json     # 一次人工验收
```

必须守住五条：

1. **受理不是推进；`watch` 也不是推进。** `group start` 是 preflight → 铸租约 → spawn
   **短命**推进器 → 立即返回 `accepted: true` / `completed: false`；推进器退出即停止推进。
   `watch` 只读事件表，`group status --refresh` 只对账，两者都**不能让组前进**。恢复只有
   `group start`（READY/PAUSED/BLOCKED）与 `group resume`（先对账、重预检、换租约），按
   `stop.resume_hint` 选——它**按原因给命令**：评审/验收类给 `group review` + `group accept`，
   `review_failed` 给 `group repair`，不是一律 `start`。`stop.needs_human` 为真则先拍板
   （等审查、等验收、看 blockers、`crashed` 先读日志），重启 runner 没有意义；
   `resumable` 与 `needs_human` 不会同时为真。所以正确姿势是"start 之后 `watch` 观察，
   推进器退出后按 `exit_reason` 决定 resume 或等人"。
2. **成员不自验收。** 成员任务停在 `REVIEW_READY`，`task accept` 会返回
   `STATE_CONFLICT`（`kind=group_member`）；验收只走 `group accept`。已集成成员的
   `revise`/`reassign`/`rebind` 一律拒绝（`kind=integrated_member`），修正走新组。
3. **预算是额度，不是进度。** `max_starts` 是计费启动额度（与真实进程数不同口径），
   `max_wall_seconds` 是含休眠的墙钟时长。预算耗尽只停新派发；对账/集成/检查/验收仍要用。
4. **结构覆盖不是语义验证。** 需求→成员→AC 的映射通过只说明"有人认领"；`NOT_RUN` 和
   另一个 SHA 的通过记录都不算通过。
5. **审查要真的做，且由独立上下文做。** 计划里 `review.required` 为真时，只凭"检查全绿"
   进不了 `REVIEW_READY`：必须提交一份绑定当前 `integration_sha`、覆盖全部必需 AC、
   每条证据都可解析的结论。判据与写法见
   [design-review-rubric.md](references/design-review-rubric.md)。`NOT_VERIFIED` 可以记录，
   但必须逐条列进报告，**不写成通过**；`FAIL` 走 `group repair`（受 `max_group_repairs`
   约束，一次只修一条 finding），没有 finding 的改动是新增需求，走计划修订。
   修复后集成版本前移，旧检查与旧审查自动作废，必须重跑并重新审查。
   **执行方是本会话内的独立审查 Agent**（Runtime 只校验、不执行）。用户关掉会话就没人
   提交结论，组停在 `awaiting_design_review`：此时汇报写"等待设计审查"，不得称"全流程
   自动完成"，也不得用实现 Agent 的自述替代。

组汇报按 [group-report-template.md](references/group-report-template.md) 的七段转述，
不要把七段压成"已完成"。

## 每次输出

- 任务 / Spec 版本（设计模式无真实任务 ID 时注明未登记）
- 当前状态、阶段、执行器 profile 与 backend、证据时间
- **可信度**：`trust_level`（verified / declared / unverified）+ 来源；未验证时直接写"未验证执行器"
- **本批内容行**（派发后）：每个在跑任务一条"它在做什么"——来自 digest 或 `task logs`
  的最近一条 `说：` / `动：`。只有状态没有内容，等于没回答"它在干什么"
- 已完成的产物和证据（含 current_evidence_id）
- 未完成项、阻塞原因及处理责任
- 下一步；需要用户决定时说明具体原因

内容行是**汇报素材**，不是验收结论：它可以写进汇报，但不能写成 PASS、已修复或已验证；
反过来，"过程观察不是证据"也不构成省略内容行的理由。两者是两件事。

收尾方式不是自由发挥：派发后默认继续第 6 步的监控循环，**不得**用"需要我现在持续监控吗"/
"要我盯着还是等它们跑完汇报"这类提问代替监控本身。真需要用户拍板时，直接说清要拍什么、
为什么现在必须拍、不拍会卡在哪个状态，并附上当前游标与续接命令。

## 保持边界

默认不自动合并、不部署、不访问生产，不读取或输出密钥。不向 Worker 注入发布凭据。
默认 `local-process` 下 **worktree 不是沙箱**：它只隔离工作文件，Agent 仍以本机账户运行、
可读工作区外的文件与本机凭据；`allowed_paths` + 事后 diff 提供的是问责而非预防。
需要在汇报中说明「受控执行」而不是「已隔离」；平台能力探测失败时停止派发。
未运行检查写 NOT_RUN；未配置 CI 不写 green；成本缺失写 unknown。
会话内的进度监控用第 6 步的循环（真实事件、真实游标），不用"我在关注"替代实际查询；
需要**会话结束后仍继续检查**时才谈宿主调度——用实际已创建成功的调度任务，没有就写
"会话结束后无人监控"并交出游标与续接命令，不以文案代替真实定时任务。不擅自向他人发送通知。
用户提出模型或费用限制时，宿主直接发起的额外评审（含会话内审查 Agent）也必须遵守该限制。
若任务或项目要求**独立评审**，就必须取得符合要求的独立评审：经 Zoe 派发一个已授权 profile
的评审任务，或使用具备独立上下文的审查方。无法确认模型时不要自行启动额外评审 Agent，也不要
用当前会话内的结论替代独立评审——报告写"独立评审未能进行"并说明原因，不得静默降级为"已评审"。
Runtime 不控制宿主，不等于本 skill 可以忽略用户的限制。

`network_profile` / 顶层 `network` 在 `local-process` 下是**声明，不是隔离**：doctor 会输出
`network: host (local-process: not restricted by Zoe)`。它不表示"禁止 CLI 联网"，也不表示
"禁止执行工具访问网络"；不得把它当作"数据不出本机"的证据。
