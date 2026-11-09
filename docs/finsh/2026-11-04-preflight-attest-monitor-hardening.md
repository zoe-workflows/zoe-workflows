# 预检 / 授权 / 监控的摩擦收敛（评估 + 优化方案 v2）

| 项 | 内容 |
|---|---|
| 日期 | 2026-11-04 |
| 输入 | ①《zoe-workflows Skill 优化汇总》7 条建议；② 对 v1 的设计评审（6 条修正 + 发布建议） |
| 被改对象 | `zoe-workflows`（`SKILL.md`、`references/*`、`runtime-requirements.json`、`build.py`）；`zoe-runtime` 仅两处单列项（见 §4-B） |
| 方法 | 每条建议先回到 `zoe-runtime@1.5.1` 源码取证，再判断"是文档缺口、是表述错误、还是运行时缺口"；对评审意见同样取证，不整段照抄 |
| 本文位置 | `zoe-workflows/docs/`（不在 `build.py` 的 `WHITELIST` 内，不进入发布包） |
| 核验说明 | 源码以**符号名**为准；文中行号是 2026-11-04 快照。v1 的源码行为由本仓复核，评审也未独立复跑，故两处结论都以本文重核为准 |

## 修订记录

| 版本 | 变化 |
|---|---|
| v1 | 7 条原建议 + 2 条顺带缺口（S1–S9），逐条判定并给出可粘贴改法 |
| **v2** | 按评审修正 6 处，其中 3 处是**会制造新故障的操作指引**：<br>① **S3 重写**：删掉"先按 `standard` 登记"，改为按真实费用档登记；删掉"`reported_mismatch` → 先补别名"；明确 probe 是**计费、需授权、仍受身份闸门约束**的真实调用（§1.8）<br>② **S2 补一致性**：`attest --dry-run` 与正式写入之间存在 TOCTOU，当前命令**没有任何 expected-\* 参数**（§1.9）；补 Skill 侧缓解 + 单列一个 Runtime 参数<br>③ **S1/S7 统一预检口径**：删掉"预览与实际不会分叉"的绝对化表述（v1 自己在 S7 给过反例，§1.10）；预检改为三种场景，不再要求每个任务跑三条命令<br>④ **S4 删除 `["bash","-c","cd <repo> && …"]`**：检查必须在任务 worktree 上跑，回到原仓库会造出"仓库绿、产物错"的假通过<br>⑤ **S5 不强制 `.sh`**：退出码 `0` 同时表示"全部终态"和"`--max-rounds` 到期"，不能都走收口；补状态目录与 Windows 协议<br>⑥ **S6 补前置与成功条件**：`--confirm-stop` 需要有"旧执行已停止"的依据；两个空 SHA 不得判等；"不重跑实现"只能表述为"本次恢复从哪个阶段开始" |

---

## 0. 结论

### 0.1 本轮评审的判定

| 评审意见 | 判定 | 处理 |
|---|---|---|
| S3 不得为标定模型而改变费用档；probe 不等于免费/免授权 | **成立，且是最高优先级** | S3 整条重写；新增 §1.8 依据 |
| 删掉 `reported_mismatch / mixed → 先补别名` | **成立** | 改为"保持不匹配 + 标定未完成"，别名须有作用域清楚的上报证据并经用户确认 |
| S2 缺"用户看见 A、实际确认了 B"的处理 | **成立** | 补 §1.9 现状核验（当前不支持）+ Skill 侧缓解 + §4-B1 单列 Runtime 参数 |
| S1 与 S7 的"预览不会分叉"自相矛盾 | **成立** | 改为"同一决策函数 + 相同有效输入/配置/环境快照 → 相同结果"，并压缩成三种场景 |
| S1 的"去掉 `require_real_e2e`"应从常规排障删除 | **成立** | 从排障动作删除；改策略属用户决定 |
| S1 自动模式不要因默认 profile 失败否决全部候选 | **成立**（且当前实现本就是候选级） | 写成"读候选级结果"，并说明 `explicit` 下天然只有一个候选 |
| S4 删除 `cd <repo>` 的 cli 形式 | **成立，且与本文 §1.5 自相矛盾** | 删除；保留直接 argv 与 worktree cwd |
| S4 `deferred` 不等于"让 Agent 自己装依赖" | **成立** | 改为"仅表示推迟确认" |
| S5 退出码 `0` 的两种含义不能统一走收口 | **成立** | 改为"正常退出后必须做一次状态核对"，区分窗口到期/终态/监控故障 |
| S5 强制 `.sh` 不成立，需覆盖 Windows 与多项目状态目录 | **部分成立** | 采纳协议层要求；Windows 实现单列（§4-B2），文档给出宿主侧等价协议 |
| S6 `--confirm-stop` 需要依据；空 SHA 不得判等 | **成立** | 补前置条件与非空断言 |
| S6 "不重跑实现"应表述为阶段起点 | **成立** | 改写为"本次恢复从哪个阶段开始"，`verify` 失败仍可能返工 |
| S9 改的是 Skill 对 Runtime 的最低版本要求 | **成立** | 明确归属；验收改为用**打包产物**验证 1.5.0 被拒 / 1.5.1 被接受 |
| 先做低风险项，五个反例回放决定是否发布操作指引 | **成立** | §4 分 A/B/C；§5 列五反例 |

### 0.2 最终形态

| 项 | v2 判定 | 与 v1 的差异 | 落点 |
|---|---|---|---|
| S1 预检 | 采纳，改为**按场景执行** | 三条命令不再是无条件门槛；补候选级读取；删"去掉 `require_real_e2e`" | §2 S1 |
| S2 授权确认 | 采纳，补**预览—写入一致性** | 新增 TOCTOU 处理与 Runtime 参数需求 | §2 S2 / §4-B1 |
| S3 模型别名 | **重写后采纳** | 真实费用档；probe 需授权且计费；不自动补别名 | §2 S3 |
| S4 checks | 采纳诊断，**删除 `cd <repo>`** | 保留直接 argv；补负向验收 | §2 S4 |
| S5 监控 | 采纳**协议**，不强制 Bash 实现 | 退出码 0 不再等于完成；状态目录；Windows 协议 | §2 S5 / §4-B2 |
| S6 恢复 | 采纳，补异常分支 | 前置依据、非空 SHA、阶段起点措辞 | §2 S6 |
| S7 `route` 模板 | 采纳 | 修正 `task_type` 优先级表述 | §2 S7 |
| S8 错误码 | 采纳 | 不变 | §2 S8 |
| S9 版本门槛 | 采纳（先实施） | 明确是 Skill 侧声明；打包产物验证 | §2 S9 |

**不采纳**：把"三条预检"设成每个任务的硬门槛；为标定模型而临时降档；在 `checks` 里 `cd` 回原仓库；把 `bash -c` 当作 PATH/Windows 的解法；把 `sleep + status` 轮询写成等价方案；用 `mixed` 整组登记别名。

---

## 1. 事实核对

### 1.1 当前 `ready` 不包含 `adapter_approved`

`_config.doctor()` 的 `ready` 是六个条件的合取，`require_real_e2e` 才追加第七项：

| 子项 | 含义 | 故障面 |
|---|---|---|
| `git` | 宿主机装了 git | 宿主机缺工具 |
| `process_identity` | 进程身份是真探测（`/proc` / `proc_pidinfo`，不靠 `ps`） | 平台层不可用，派发必以 `PROCESS_UNKNOWN` 收场 |
| `platform_lock` | 共享/独占锁可用 | 平台层不可用 |
| `platform_tree` | 进程树"有进程/已清空"两态判定都正确 | 平台层不可用 |
| `checks_preflight_ok` | 每条 check 的 `argv[0]` 能解析，或属于 `shell`/`deferred` | **项目 checks 写错**（只有 `unresolved`/`invalid` 算失败） |
| `placeholders_ok` | 没有 `REPLACE_WITH_*` / `<FILL:*>` / `/absolute/path/to/*` | 配置没填完 |
| `trusted`（仅 `require_real_e2e: true`） | 该 backend 有真实 e2e 记录（= `checks.adapter_approved`） | 严格项目准入 |

`checks.adapter_approved` 是**可信度标签**，不是入场券。原建议「`adapter_approved` 必须为 true，否则 create 必失败」在**旧运行时**（容器后端时代，`ready = git ∧ docker_ready ∧ adapter_approved ∧ process_identity`）成立，在当前版本不成立。

> 结论：写成「读 `ready` 的与项并按子项分诊」，不写"必须为 true"。

### 1.2 同一句错误文案有两个来源

| 出现时机 | 来源 | 触发条件 | 正确动作 |
|---|---|---|---|
| `task create` → `ENVIRONMENT_ERROR: doctor reports not ready` | `_routing` 的 L2 候选排除（`collect_snapshot` 每候选一次 `doctor`，`decide` 把 `ready=false` 排除成候选自己的 `code` 或兜底 `ENVIRONMENT_ERROR`） | **仅**当项目配了 `routing` 段，或请求里带了 `route` | 读候选级 `code` / `details.gaps`，或重跑 `route plan` 看每个候选；按 §1.1 子项修环境 |
| `task start/resume` → `ENVIRONMENT_ERROR: doctor failed; verify the execution environment and profile` | `_pipeline._start_locked` 的硬闸门（只在 `phase ∈ {prepare, implement, verify}` 检查） | 任何项目 | 同上；`phase=acceptance/publish/ci` 时**不做**这项检查 |

**候选级而非项目级**：自动模式下 `decide()` 对每个候选各自判定，单个候选的 `doctor` 失败只排除它自己，全部失败才报 `ROUTE_NO_ELIGIBLE` + `details.gaps`。`explicit` 模式天然只有一个候选，它失败就是本次请求失败——不要据此推断"整份白名单都不可用"。

### 1.3 `task recover` 之后不能直接 `accept`

- `task recover --confirm-stop` 收口后写入 `state=BLOCKED`、`block_code=RUN_INTERRUPTED`（`cli._task_recover`）。
- `task accept` 的前置是 `state == REVIEW_READY`，且 `subject_sha == validated_sha`、工作区指纹未变（`_pipeline.accept`）。

所以「`candidate_sha == validated_sha` 就跳过 resume 直接 accept」不成立；正确路径是 `recover → resume → REVIEW_READY → accept`。

`--confirm-stop` 的语义是**人已确认旧执行停止**，不是"我看不到进程"。可用的依据包括：`task status --refresh` 的 `progress.process_state=exited`、`task events` 里该 run 的退出记录、进程树探测为空、写者锁可获得。观测不到（`unknown`）**不构成依据**——`_task_recover` 在进程树 `None` 或写者锁被占时返回 `PROCESS_UNKNOWN` 且不释放配额，这是有意的。

### 1.4 `route` 块有前置条件

`_routing.plan_route` 的硬校验：请求里出现 `route` 而项目 `routing.mode != "auto"` → `INPUT_INCOMPLETE`（"enable routing or drop the route block instead of having it ignored"）。

`references/project-profile.example.json` 是 `"mode": "explicit"`，因此 `route` 只能进**独立的 routed 模板**，不能进最小示例。

### 1.5 两处 PATH **与两处 cwd** 都不同

| 阶段 | `cwd` | PATH 来源 |
|---|---|---|
| `doctor` 的 `checks_preflight` | 项目 `repo` | `doctor` 进程自身的 PATH（`resolve_check(..., search_path=None)`） |
| 执行前复校（`run_checks` → `resolve_check`） | **任务 worktree** | supervisor 继承的 `os.environ["PATH"]` |

两条推论（v1 只写了第一条）：

1. PATH 可能不同（GUI 宿主常缺 `/usr/local/bin`、`~/.local/bin`、版本管理器 shim）。
2. **cwd 必须不同**：检查跑在 worktree 上，验证的是本次候选。任何把 cwd 挪回原仓库的写法都会让"原仓库是绿的、候选是坏的"变成一次绿色通过。

### 1.6 监控脚本的运行前提与两处语义陷阱

`scripts/zoe-monitor.sh`：

- 只用 `ZOE_BIN`（默认 `zoe`），**不认 `ZOE_SRC`**：直接 `"$ZOE_BIN" watch …`，不补 `PYTHONPATH`。源码绑定环境会 `exit 2`；要么 `pipx install -e`，要么给 shim 并让 `ZOE_BIN` 指向它。
- 包装器的 `--which` 输出的是 **JSON 对象**，不是裸路径；`ZOE_BIN=$(… --which)` 是错误用法。已安装环境用 `ZOE_BIN=$(command -v zoe)`。
- 依赖 `jq`；缺则 `exit 2`。**这不是任务故障**：应回退到宿主侧 `watch --follow` + 状态核对，而不是把运行中的 Agent 报成失败。
- **退出码 `0` 有两种含义**：`[done] all targets final` 与 `[stop] max rounds reached`（`--max-rounds` 到期）。两者都返回 0，但后者完全可能仍有任务在跑。
- 游标与事件文件默认写在**当前工作目录**（`./zoe-cursor.txt`、`./zoe-events.jsonl`）。同一目录监控两个项目或两组目标会共用一份游标，导致静默跳过事件。
- 只有 `.sh`，没有 PowerShell/批处理等价物（`scripts/` 下仅 `zoe.sh`/`zoe.cmd`/`zoe.ps1` 是**包装器**，不是监控器）。

### 1.7 版本门槛缺口

`model_aliases` 与 `alias_confirmed` 是 1.5.1 引入的（更早版本以 `Unknown profile fields` 拒绝），而 `runtime-requirements.json` 的 `min_version` 仍是 `1.5.0`。改的是 **Skill 对 Runtime 的最低要求**，不是 Runtime 自身版本。

### 1.8 probe 是真实调用：计费、需授权、仍过身份闸门

`purpose: "probe"` 只影响**质量归因**（`_routing` 把 probe 记为 `excluded`），不改变执行链：

| 环节 | 对 probe 是否生效 | 依据 |
|---|---|---|
| 授权确认（`ALLOWLIST_UNCONFIRMED`） | **生效**（create/start 前置） | `_pipeline._require_attested` |
| 费用闸门 | **生效**（run 记录成本后评估，越限 `SPEND_LIMIT_EXCEEDED` / `SPEND_UNVERIFIABLE`） | `_pipeline._gate_spend` |
| 模型身份闸门 | **生效**（pin 下不匹配即 `MODEL_MISMATCH`） | `_pipeline._gate_model_identity` |
| 尝试次数 / 并发槽 | **生效** | `attempts` 在启动 Agent 前 +1 |

由此推出两条：**探测会花钱，也会按 `cost_ceiling` / `spend_guard` 被判**；"用户不想用某个贵模型"时，连 probe 都不能替他调——必须先拿到明确授权。

补充一条有用的事实：`MODEL_MISMATCH` 被拒时，`block_details` 里已经带 `reported` / `reported_models` / `request_echoes` / `declared_aliases`，`task status --json` 返回完整任务记录（含 `block_details`）。**所以"按真实费用档登记、撞了 mismatch 再标定"是可行的**，不需要为了拿上报名而降档。

### 1.9 `project attest` 当前没有"预览—写入"一致性参数（TOCTOU）

`_project_attest` 的流程是：读当前配置 → 计算 `policy_digest(c)` → 写记录（`--dry-run` 只是跳过最后一步）。参数只有 `--project` / `--profiles` / `--dry-run` / `--json`，**没有** `--expect-policy-hash` 之类的比对参数。

因此存在真实窗口：dry-run 展示 `policy_hash=H1`，用户同意；写入前另一进程改了模型/端点，写入时算出 `H2` 并落盘——用户确认过 A，系统记录了 B。

- 写入响应会返回 `policy_hash` 与 `confirmed_profiles`，所以**事后可以发现不一致**（发现后必须重新展示并重新决定；记录无法删除，下一次确认会覆盖它）。
- 写入前再读一次只能缩短窗口，**不能消除**。彻底解决要在同一个受保护操作里比对，属 §4-B1 的 Runtime 项。

另外：`previous` 非空只说明"曾经确认过某份配置"，**不能单独证明本次候选已被确认**——判定要看 `details.reason` 与 `policy_hash` 是否一致。

### 1.10 "预览与实际不会分叉"的准确表述

`route plan` 与 `task create` 确实共用 `decide()`，但**输入不同**：`route plan` 不读 Spec 文件，`create` 会把 `spec.document` 传进去。当 `task_type` 只写在 Spec 里时，预演按 `unknown` 匹配、create 按 Spec 匹配——这就是 v1 自己写出的反例。

准确表述：**同一决策函数，在有效输入、配置与环境快照相同时才给出相同结果**。所以预演要把实际任务类型显式放进请求，并且预演通过不等于 create 会成功（还不校验 Spec 合法性与授权确认记录）。

---

## 2. 采纳项与详细改法

### S1 预检：按场景执行，不做成每次三条命令（P0）

**目标**：预检只在"能提供新信息"时执行，且答案要能指向下一步。

**落点**：`SKILL.md` 第 2 步「核实依赖」；`references/runtime-contract.md` 的就绪度小节。

**改法**：

```text
先判场景，再决定跑什么。三条只读命令不是每个任务的固定仪式：

| 场景 | 判据 | 动作 |
|---|---|---|
| 无 `routing` 段的项目 | 项目配置里没有 `routing` | 只跑 `doctor --project P --require-ready`；不需要路由预演，也不需要白名单确认 |
| 首次接入 / 配置变过 / 确认缺失 | 无 `routing` 以外的新项目；`attest --dry-run` 的 `previous` 为空或 `policy_hash` 不一致；`ALLOWLIST_UNCONFIRMED` | 加跑 `project attest --dry-run`（见 S2）；需要预演时 `route plan --request-file`，**并把实际 `task_type` 放进请求** |
| 已确认、配置未变的日常任务 | 上面的条件都不成立 | 不重复跑三条预检；准入由 create/start 自身的硬校验负责 |
```

`doctor` 的 `ready` 是六个条件的合取（`git` ∧ `process_identity` ∧ `platform_lock` ∧ `platform_tree` ∧ `checks_preflight_ok` ∧ `placeholders_ok`），`require_real_e2e: true` 的项目再加 `trusted`。`checks.adapter_approved` 只表示"该 backend 有真实 e2e 记录"，**默认不是** ready 的条件。

未就绪时按子项分诊：

| 子项为假 | 故障面 | 动作 |
|---|---|---|
| `git` | 宿主机缺工具 | 装工具 |
| `checks_preflight_ok` | 项目 checks 配错（`unresolved` / `invalid`） | 改 `checks[*].argv`，见 S4 |
| `placeholders_ok` | 配置没填完 | 填 `REPLACE_WITH_*` / `<FILL:*>` |
| `platform_lock` / `platform_tree` / `process_identity` | 平台层不可用 | 停止派发，先修平台层 |
| `trusted`（仅严格项目） | 无真实 e2e 记录 | 补 `compatibility_evidence`，或改用**已获准且已验证**的候选 |

严格项目缺 e2e 记录时，**不要**把"去掉 `require_real_e2e`"当排障动作：那是用户改变项目政策，需要明确决定并重新 `register` + `attest`。

`doctor` 通过只说明它覆盖的环境条件满足，**不**说明 Spec 合法，也不说明任务一定能启动。`create` 报 `ENVIRONMENT_ERROR: doctor reports not ready` 时，读候选级 `code` / `details.gaps`（或重跑 `route plan`），不要在同一个环境下重试 `create`。

**判错**：把三条预检写成每个任务的硬门槛、或写"`adapter_approved` 必须为 true 否则 create 必失败"、或把"去掉 `require_real_e2e`"列为常规动作，判失败。

### S2 授权确认：确认表 + 预览—写入一致性（P1）

**目标**：用户看到的候选集合与执行配置，就是最终被记录的对象。

**落点**：`SKILL.md`「执行配置与模型授权」；`references/cli-contract.md`（`project attest` 用法 + 错误码 S8）。

**改法**（替换「新配置要先确认一次」整段）：

**新配置要先确认一次，确认表由 runtime 生成。** 声明了 `routing` 段但没有有效确认记录时，create/start/reassign 返回 `ALLOWLIST_UNCONFIRMED`（`details.next` 给出下一步）。标准流程：

1. `zoe project attest --project P [--profiles a,b] --dry-run` ——**预览时就带上收窄子集**，否则"预览的是全集、确认的是子集"。
2. 读返回：`policy_hash`、`confirmed_profiles`、`execution[]`（每个候选的 `model` / `model_aliases` / `permission_profile` / `cost_class` / `model_unresolved`）、`previous`。把 `execution[]` **原样**列给用户；`previous.policy_hash != policy_hash` 时明说"配置已变更"。
3. 用户明确同意后，用**同一组参数**去掉 `--dry-run` 执行一次，并核对返回的 `policy_hash` 与 `confirmed_profiles` 是否与预览逐字一致：

   | 写入返回 | 含义 | 动作 |
   |---|---|---|
   | 与预览一致 | 确认的就是用户看过的 | 继续；在汇报里写明 `policy_hash` |
   | `policy_hash` 变了 | 预览与写入之间配置被改（TOCTOU，§1.9） | **视为未确认**：重新展示差异、重新取得同意；不得说"已确认" |
   | `confirmed_profiles` 变了 | 白名单同时被改 | 同上 |

4. 配置变更后**主动**提示需要重新确认（任何换模型/端点/权限档/加 profile 都会让记录失效）。`ALLOWLIST_UNCONFIRMED` 先读 `details.reason`：

| `details.reason` | 含义 | 动作 |
|---|---|---|
| `missing` | 没有记录 | 走 1–3 |
| `policy_changed_since_attestation` | 记录绑定旧摘要 | 重新展示 → 重新确认 |
| `candidate_not_confirmed` | 本次候选不在确认集合里 | 换已确认候选，或重新确认并包含它 |
| `record_invalid` | 记录不合规（缺 `policy_hash` 等） | 重新确认（坏记录按未确认处理） |

用户没有明确同意时**不得**调用 `project attest`。`previous` 非空不等于"本次已确认"。

**必须写明的边界**：第 3 步只能**发现**不一致、不能**阻止**写入——当前 `project attest` 没有 expected-\* 参数（§1.9）。彻底解决见 §4-B1；在它落地前，文档不得声称"确认是原子的"。

**判错**：把 preview 的 `--profiles` 去掉后再正式写入、写入后不核对摘要、或宣称"确认不会错位"，判失败。

### S3 模型身份标定：按真实配置登记（P0，重写）

**目标**：让新 profile 的第一次运行尽可能一次通过，且**不通过降档、不改真实成本声明**来绕过身份闸门。

**落点**：`SKILL.md`「执行配置与模型授权」；`references/runtime-contract.md` 首次接入顺序。

**改法**（替换关于 `cost_class` / `model_aliases` 的整段）：

**按真实配置登记，再标定。** 模型身份分三层，不要越层表述：`model_unresolved=false` 只说"配置指定了模型"；`run.model_identity` 是"CLI 自报"这一层的结论；"服务端实际用了该模型"当前没有证据源。

1. **照真实费用档登记** `cost_class`（`premium` 就是 `premium`）。`premium` 会默认 `pin_model=true`，这是要求，不是障碍：pin 接受 `reported_match`（逐字一致）与 `alias_confirmed`（上报值落在 `model_aliases` 内）。
2. **探测必须先获授权**：probe 是真实模型调用，**计费、受 `cost_ceiling` / `spend_guard` 约束、过模型身份闸门**（§1.8）。用户不愿调用某个贵模型时，不得以"只是探测"为由替其发起。
3. **探测方式**：`task create` 给 `"purpose": "probe"`（结果不进质量统计），`start` 后读 `task report TASK --json` 的 `requested_model` / `reported_model` / `reported_models[]`（`scope=request_echo` 是请求名回显，**不参与判定**）/ `model_identity` / `identity_basis`。
4. **撞上 `MODEL_MISMATCH` 不是死路**：被拒时 `block_details` 已带 `reported` / `reported_models` / `request_echoes` / `declared_aliases`（`task status --json` 可读），标定证据照样拿得到。工作区会被隔离成 patch（不丢失但停住），对 probe 任务影响可忽略。
5. **登记别名要有依据，不是看到差异就补**：

   | 观测 | 允许的动作 |
   |---|---|
   | `reported_match` | 无需别名，可直接 `premium` |
   | `reported_mismatch` / `mixed` | **默认保持不匹配**。只有当上报名的作用域清楚（是同一 provider 的别名而非另一个模型）、命名关系有可信依据、且用户确认后，才登记 `model_aliases` |
   | `mixed`（多个不同名） | **不得整组写入别名**；先查清为什么一次运行出现多个模型标识 |
   | `unobserved` | 查适配器输出协议；pin 无法满足，需与用户决定是否改为显式声明或换候选 |

6. 别名或模型变更都会改变配置摘要：`register` → 重新 `attest`（S2）→ 用新的 probe 任务复验。汇报措辞固定为 **"按声明等价"**（`identity_basis=declared_alias`），**不得**写成"已证明使用该模型"。

**明确禁止**：用 `cost_class` 降级来"关掉"身份要求；为标定把 `premium` 临时登记成 `standard` 且不告知用户；把 `mixed` 整组加入白名单；在用户未授权时用 probe 试探贵模型。

**判错**：文档出现"先按 standard 登记再升 premium"、"`reported_mismatch` → 先补别名"、"probe 不产生费用"，任一即判失败。

### S4 checks：诊断保留，删除迁回原仓库的写法（P2）

**目标**：让"测试通过"确实来自本次候选，并且预检失败能指向正确动作。

**落点**：`references/runtime-contract.md`（`checks_preflight` 表之后）、`SKILL.md` 第 2 步子项表（S1 已引用）。

**改法**：

`checks_preflight` 每个状态各对应一种动作，只有 `unresolved` / `invalid` 计入 `ready`：

| status | 含义 | 计入 ready | 动作 |
|---|---|---|---|
| `ok` | 现在就能解析到绝对路径 | 否 | 无 |
| `shell` | `argv[0]` 是 shell；内部命令**不做静态解析** | 否 | 仅用于确需管道/条件时；声明"内部命令不可验证" |
| `deferred` | 安装/构建后才产生（`node_modules/.bin`、`bin`、`target`…） | 否 | **仅表示推迟确认**：不算配置错，也不代表本次一定会跑通 |
| `unresolved` | 裸名不在 PATH，或相对路径不存在且不像生成物 | **是** | 改 `argv` 或修 PATH |
| `invalid` | `argv` 为空/形态非法 | **是** | 补 `argv`（注册期本该就拒） |

**检查的 cwd 是任务 worktree**（§1.5）：写 `["bash","-c","cd <repo> && …"]` 会让检查跑在原仓库上，最坏结果是"原仓库绿、候选坏、Zoe 拿到绿色结果"。**不要**用 `bash -c` 迁就宿主 PATH，也不要靠它解决 Windows——它既不改变 PATH 来源，也不保证 `bash` 存在。

写法排序：

1. 首选直接 argv（`["go","test","./..."]`、`["pnpm","exec","vitest","run"]`），由 runtime 决定 cwd；
2. 工具不在 PATH 时，**装到宿主 PATH 或写可解析的绝对路径**，而不是换 shell；
3. 确需管道/条件才用 shell 形式，并接受"内部命令不可验证"；
4. `deferred` 的工具由任务自己准备，但**不要**据此推断"Agent 会装依赖"——那条链没有任何保证。

`doctor` 的这部分输出应被读作**"当前环境预检"**；执行阶段以实际 cwd、实际解析到的工具与退出码为准。

**负向验收（最高价值）**：在一个夹具里让**原仓库测试通过、候选 worktree 测试失败**，最终验证必须是 `FAIL`。这条能同时抓住"cwd 指错"和"预检当执行用"两类错误。

**判错**：文档出现 `cd <repo>`（或任何指向原仓库的 cwd 切换）、把 `deferred` 解释成"Agent 会自己装依赖"，判失败。

### S5 监控：强制"可续读、可判断"的协议，不强制 Bash 实现（P1）

**目标**：任何时候都能回答"任务在哪个状态、证据在哪、谁还需要动作"，且不把窗口到期当完成。

**落点**：`SKILL.md` 第 5 步末尾（硬约束）+ 第 6 步（退出原因与回退协议）；`references/runtime-contract.md` 观测小节。

**改法**（第 5 步末尾新增）：

**`start` 成功后立即进入监控。** 脚本化监控是首选实现，不是唯一实现：要求是**可续读（游标）+ 可判断（状态快照）**，不是"必须跑 .sh"。

```bash
# 每个项目/目标集合用自己的状态目录：游标与事件文件不要共用到别的项目里
# （脚本不会自动建目录，先 mkdir -p .zoe）
mkdir -p .zoe
ZOE_BIN=$(command -v zoe) \
  bash <skill-dir>/scripts/zoe-monitor.sh \
    --project P --targets "T1 T2 T3" --interval 10 \
    --cursor-file .zoe/P-cursor.txt --events .zoe/P-events.jsonl
```

**退出后必须做一次状态核对**，因为脚本的正常退出有两种含义（§1.6）：

| 退出码 / 末行 | 含义 | 动作 |
|---|---|---|
| `0` + `[done] all targets final` | 全部目标到达终态（DONE/CANCELLED） | 逐目标汇报；`CANCELLED` 单独写，不并入"完成" |
| `0` + `[stop] max rounds reached` | **窗口到期，不代表完成** | `task status --refresh` 逐个核对；仍有运行项 → 保存游标继续监控，不写"已完成" |
| `2` | 用法/依赖错误（缺 `jq`、缺 `--project`、`zoe` 不可用） | 回退到 `watch --follow` + `status --refresh` 协议继续监控；**不得**把运行中的 Agent 报成故障 |
| `10` | 剩余目标都需人工介入 | 按 `[needs-human]` 行分流：`INPUT_REQUIRED` → `task answer`；`BLOCKED` 看 `block_code`；`REVIEW_READY` → `task report` + 提交人工验收 |
| `11` | `zoe watch` 连续失败达上限 | 修可达性后带 `next_cursor` 续跑；"读不到"不等于"还在跑"，也不等于"失败" |

三条纪律：

- **监控器正常退出 ≠ 任务完成；任务进入终态 ≠ 任务成功。** 终态只回答"不会再自己前进"，成功由验收结论回答。
- 游标按项目/目标集合隔离；处理完事件再推进游标，重启时先读游标再决定是否初始化。
- 宿主侧等价协议（Windows 或脚本不可用时）：`watch --project P --jsonl --after <cursor> --max-events 200` 取事件并记录 `next_cursor`，`task status --refresh` 取权威状态，按上表分流。**同一套语义，换实现不换判断。**

**判错**：把"脚本退出 0"或"`--max-rounds` 用满"汇报成任务完成；在缺 `jq` 时把任务报成失败；同一目录并用一份游标监控两个项目，判失败。

### S6 `PROCESS_UNKNOWN` 恢复：前置依据 + 阶段起点（P2）

**落点**：`references/recovery-policy.md`（`PROCESS_UNKNOWN` 行之后）、`SKILL.md` 第 7 步（一句判定依据）。

**改法**：

`task recover TASK --confirm-stop` 之后统一是 `BLOCKED` + `block_code=RUN_INTERRUPTED`。

**收口前先有依据**：`--confirm-stop` 表示"我确认旧执行已停止"，依据是状态/事件/进程树/写者锁，而不是"我看不到进程"。`task status --refresh` 显示 `process_state=unknown`、进程树判定为 `unknown`、或写者锁被占时，`recover` 会返回 `PROCESS_UNKNOWN` 且不释放配额——此时继续对账，**不要**起第二个写者。

**然后按 `phase` 与有效证据决定从哪个阶段继续**（不是"决定是否永不重跑"）：

| 观测 | 判定 | 本次恢复从哪开始 |
|---|---|---|
| `phase=acceptance` 且 `candidate_sha`、`validated_sha` **均非空且相等**，`current_evidence_id` 非空、证据可校验、工作区指纹未变 | 实现与验证都已完成，只差人工验收 | `resume` 直接到 `REVIEW_READY`（不启动 Agent、不耗 attempt）→ 按 delivery-policy 提交 `accept` |
| `phase=publish` / `ci` | 产物已验证，卡在远端或 CI | 先核对远端是否已有提交/PR（`REMOTE_UNKNOWN` 不当作无漂移），再 `resume` 从发布/查 CI 继续 |
| `phase=verify` | 实现完成、验证未完成 | `resume` 从 checks 继续；**检查失败仍可能需要返工**，不要预先承诺"不会再调 Agent" |
| `phase=implement` / `prepare`，或 `candidate_sha` 与 `validated_sha` 任一为空/不等 | 实现未完成或证据已失效 | `resume` 继续实现（消耗一次 attempt） |
| 证据缺失、或阶段与产物互相矛盾（如 `phase=acceptance` 但无证据/指纹不符） | 不能猜 | 先对账（`task report`、`task events`、`rebase` 之外的只读手段），必要时 `task rebind` 重验或 `revise` |

两个常见误判：

- **两个空 SHA 不能判等**：`null == null` 不构成"已验证"。
- `resume` 会按**当前**配置重新核对授权确认记录；配置变过会报 `ALLOWLIST_UNCONFIRMED`——那是重新确认授权，不是重跑实现，不要因此 `revise`/`reassign`。

**判错**：文档写"`candidate_sha == validated_sha` 时 recover 后直接 accept"、或写"恢复后保证不再调用 Agent"，判失败。

### S7 create 请求的 `route` 模板（P3）

**落点**：新增 `references/create-request.routed.example.json`；`build.py` 的 `REQUIRED_FILES`；`references/cli-contract.md`「创建请求」节；`SKILL.md` 第 5 步一句前置条件。

**改法**（新文件内容）：

```json
{
  "schema_version": 2,
  "request_id": "<FILL:全局唯一；同一任务重试复用原值>",
  "project_id": "<FILL:已注册且 routing.mode=auto 的项目 id>",
  "title": "<FILL:一句话任务标题>",
  "spec_file": "<FILL:spec 文件路径>",
  "delivery_mode": "local_artifact",
  "authorization_ref": "<FILL:与项目配置 authorization_ref 完全一致>",
  "route": {
    "task_type": "feature",
    "requirements": {
      "needs_tool_use": true
    }
  }
}
```

`cli-contract.md` 补：

```text
`route` 是可选块，**要求项目 `routing.mode` 为 `auto`**；`explicit` 项目里出现 `route`
会以 `INPUT_INCOMPLETE` 拒绝（不静默忽略）。字段：

| 字段 | 作用 |
|---|---|
| `route.task_type` | 匹配 `routing.rules[].task_type` 的 `prefer` 列表；取值 `bugfix/feature/refactor/test/docs/chore/review/unknown/*` |
| `route.requirements` | L1 硬条件：`context_budget` / `needs_tool_use` / `structured_result` / `input_modalities` / `data_residency` / `min_capability` / `permission_profile_in` / `non_interactive` / `structured_input` / `session_resume` / `pin_model` |

`task_type` 的取值顺序：`route.task_type` > spec 文档的 `task_type` > `unknown`。
未命中任何 `rules` 项时走 `routing.fallback`（`ask` 给选项，`default_profile` 用默认），
没有"按白名单顺序自动挑一个"。

`route plan` 不读 spec 文件：`task_type` 只写在 spec 里时，预演按 `unknown` 匹配而
create 按 spec 匹配。要预演准，就把 `task_type` 写进请求。
```

`SKILL.md` 第 5 步补一句：

```text
需要路由时在请求里给 `route.task_type` 与 `route.requirements`（要求项目 `routing.mode=auto`；
`explicit` 项目不要带 `route`，否则 `INPUT_INCOMPLETE`）。`task_type` 的取值顺序是
「请求 → Spec 文档 → unknown」，不传不代表一定是 `unknown`。
```

**判错**：把 `route` 加进 `create-request.example.json`（与 `explicit` 示例冲突）；或写"不传一定是 `unknown`"，判失败。

### S8 `ALLOWLIST_UNCONFIRMED` 进错误码表（P1）

**落点**：`references/cli-contract.md` 错误码表（`POLICY_CHANGED` 附近），新增一行：

```text
| `ALLOWLIST_UNCONFIRMED` | 声明了 `routing` 段的项目没有有效的授权确认记录 | 读 `details.reason`（`missing` / `policy_changed_since_attestation` / `candidate_not_confirmed` / `record_invalid`），按 S2 流程确认；不得绕过、不得自行修改白名单 |
```

**判错**：把该码解释成"环境未就绪"或"重试即可"，判失败。

### S9 最低版本门槛（P0，先实施）

**落点**：`zoe-workflows/runtime-requirements.json`：`"min_version": "1.5.0"` → `"1.5.1"`。

这是 **Skill 对 Runtime 的最低要求**，不是 Runtime 版本变更。发布前用**实际打包产物**验证：把包装器指向 1.5.0 的运行器 → `RUNTIME_INCOMPATIBLE`（exit 5）；指向 1.5.1 → 门禁通过。

**判错**：只在源码树里用 `python -m src` 验证、未用 `dist/zoe-workflows.zip` 的内容验证，判失败。

---

## 3. 明确不做

| 项 | 理由 |
|---|---|
| 把三条预检设成每个任务的硬门槛 | 无 `routing` 的项目不跑路由；日常任务重复预检不产生新信息 |
| 为标定模型而临时降档 / 用 `cost_class` 关掉身份要求 | 改的是"用户声明的真实成本"，且会让后续任务在错误的成本假设下派发 |
| 用 probe 试探用户未授权的贵模型 | probe 计费且过闸门（§1.8） |
| `reported_mismatch` / `mixed` → 自动补别名 | 一次请求 A 返回 B 可能是合法别名，也可能是实际换了模型 |
| 在 `checks` 里 `cd <repo>` 或用 `bash -c` 迁就 PATH | 让检查跑在原仓库上会造出假绿；也不会修好 GUI PATH 或 Windows |
| 把 `sleep + status` 轮询写成等价方案 | 无游标、无"需人工介入就停"的语义 |
| 强制 `.sh` 实现 | 协议层要求（游标 + 状态核对）才是本质；Windows 走宿主等价协议 |
| runtime 侧给 `unresolved` 加颜色 | 渲染问题；`ready` 与顶层 `checks_preflight` 已给全信息 |
| 自动 `project attest` / 自动改 `allowed_profiles` | 等于替用户授权 |
| skill 侧第二套预检引擎 | `route plan` 与 create 共用同一决策函数；自算必分叉 |

## 4. 实施与工作量

### A. 文档 / 模板 / 打包（低风险，先做）

| 序 | 改动 | 文件 | 估时 |
|---|---|---|---|
| 1 | S9 版本门槛 + 打包产物验证 | `runtime-requirements.json` | 0.1 |
| 2 | S7 routed 模板 + 配对说明 | 新 `references/create-request.routed.example.json`、`cli-contract.md`、`build.py`、`SKILL.md` 第 5 步 | 0.4 |
| 3 | S8 错误码 | `cli-contract.md` | 0.1 |
| 4 | S1 三种场景 + 子项表（含 `adapter_approved` 纠正） | `SKILL.md` 第 2 步、`runtime-contract.md` | 0.5 |
| 5 | S4 状态表 + 删除 `cd <repo>` + 负向验收 | `runtime-contract.md`、`SKILL.md` | 0.3 |
| 6 | S2 确认流程 + 一致性核对 | `SKILL.md`、`cli-contract.md` | 0.5 |
| 7 | S3 重写（真实档次 + 授权 + 不自动补别名） | `SKILL.md`、`runtime-contract.md` | 0.5 |
| 8 | S5 监控协议（退出原因分流 + 状态目录 + 宿主等价协议） | `SKILL.md` 第 5/6 步、`runtime-contract.md` | 0.4 |
| 9 | S6 恢复前置 + 阶段起点 | `recovery-policy.md`、`SKILL.md` 第 7 步 | 0.3 |

A 合计约 **3.1 人日**（v1 的 2.7 人日只覆盖了其中一部分；此处按修正后的内容重算）。

### B. Runtime 项（单列，不进上面的估算）

| 项 | 内容 | 为什么需要 | 粗估 |
|---|---|---|---|
| B1 `attest` 预览—写入一致性 | `project attest --expect-policy-hash H [--expect-profiles a,b]`：在同一把锁内比对当前摘要与候选集合，不一致则拒绝写入并返回差异；不带该参数时行为不变 | §1.9 的 TOCTOU 无法用 Skill 侧读一次消除 | 0.5–1 |
| B2 Windows 监控实现 | 与 `.sh` 同语义的宿主侧实现（或官方文档化"宿主等价协议"作为支持口径） | §1.6：当前只有 Bash 脚本 | 1–2 |

B 未完成前，文档必须写"确认只能事后发现不一致"、"Windows 走宿主等价协议"，不得写成等价能力。

### C. 后置观察项

- `mixed` 的成因排查（一次运行出现多个模型标识是适配器解析问题还是真的切换）。
- 是否需要在 `task status` 里把 `block_details` 提到更显眼的位置（当前在完整任务记录里）。

## 5. 验收：五个反例优先于新增强制语句

| # | 反例 | 通过标准 | 覆盖 |
|---|---|---|---|
| 1 | 确认期间配置变化 | dry-run 展示 H1 → 改配置 → 正式 `attest`（带 `--expect-policy-hash H1`）**被拒**且不落新记录；无该参数时，Skill 必须发现 `policy_hash` 不一致并判定"未确认" | S2 / B1 |
| 2 | 未授权的 premium probe | 无确认记录时 `create` 直接 `ALLOWLIST_UNCONFIRMED`；`$ZOE_HOME` 无新 run、无模型调用 | S2 / S3 |
| 3 | 原仓库绿、候选红 | 夹具里注入"worktree 才失败"的用例，最终验证必须 `FAIL` | S4 |
| 4 | 监控窗口到期 | `--max-rounds 1` 退出后任务仍 RUNNING；汇报不得写"已完成"，且带游标续接 | S5 |
| 5 | 旧进程归属未知 | `PROCESS_UNKNOWN` 下 `start`/`resume` 被拒；不产生第二个写者 | S6 |

**门禁（跨仓 CI）**：

| 门禁 | 断言 |
|---|---|
| `tests/contract/test_skill_cli_contract.py` | `cli-contract.md` 里每个 `text` 代码块中的命令行/选项都真实存在（S1/S2/S7 新增的命令行必须逐个核对） |
| `tests/test_contract_artifacts.py` | `build.py --check` 为空；新 reference 进 `REQUIRED_FILES`；`docs/` 不进包 |
| `tests/test_doc_contracts.py` | `SKILL.md` 必须仍含 `max_active_tasks`、`verification_scope`、`NOT_RUN`、`dispatch_pending` |
| `build.py --pack` + 真实运行器 | S9：1.5.0 被拒（exit 5）、1.5.1 通过 |

**负向文案断言**（人工过一遍）：

1. 不出现「`adapter_approved` 必须为 true 否则 create 必失败」。
2. 不出现「recover 后直接 accept」或「恢复后保证不再调用 Agent」。
3. 不出现「先按 `standard` 登记」或「`reported_mismatch` → 先补别名」或「probe 不产生费用」。
4. 不出现 `cd <repo>` 形式的 checks 示例。
5. 不出现「不传 `task_type` 一定是 `unknown`」。
6. `create-request.example.json` 不含 `route`。

## 6. 风险与边界

1. **预检通过 ≠ create 成功**：`route plan` 不读 Spec、不校验授权确认记录；`doctor` 不校验 Spec 合法性。文档必须保留这句，否则只是把"doctor ready 却失败"换成"route plan 通过却失败"。
2. **确认不是原子的**（在 B1 之前）：Skill 只能发现不一致，不能阻止写入。这是本轮唯一"文档无法自洽、必须改 Runtime"的点，不能靠更多文案掩盖。
3. **S9 是行为变更**：1.5.0 宿主从可运行变为 `RUNTIME_INCOMPATIBLE`，需要发布说明与打包产物验证。
4. **`shell` 形式的 checks 仍不可静态验证**：文档只能承认，不能声称已验证；且不得用它绕 cwd/PATH/Windows。
5. **监控的语义边界**：窗口到期、终态、成功是三件事；文档与汇报必须分开写。
6. **本方案不新增 Skill 侧命令**：所有动作复用 `doctor` / `route plan` / `project attest` / `task status|report|events|recover|resume|accept` / `zoe-monitor.sh`。

## 7. 附：关键锚点（符号名，2026-11-04 快照）

```text
zoe-runtime/src/_config.py:doctor()                     ready 六项合取 + require_real_e2e 追加 trusted
zoe-runtime/src/_config.py:checks_preflight()           cwd=repo、search_path=None 的静态预检
zoe-runtime/src/_config.py:resolve_check()              ok/shell/deferred/unresolved/invalid
zoe-runtime/src/_config.py:attestation_status()         missing / policy_changed_since_attestation / candidate_not_confirmed / record_invalid
zoe-runtime/src/_routing.py:plan_route()                route 块要求 routing.mode=auto；不读 spec 文件
zoe-runtime/src/_routing.py:task_type_of()              route.task_type > spec.task_type > unknown
zoe-runtime/src/_routing.py:collect_snapshot()/decide() 每候选一次 doctor（候选级排除），ready=false → 候选自己的码
zoe-runtime/src/_routing.py:raise_for_plan()            auto → ROUTE_NO_ELIGIBLE + details.gaps；explicit 单候选 → 该候选的码
zoe-runtime/src/_routing.py:normalize_requirements()    premium → pin_model 默认 true
zoe-runtime/src/_pipeline.py:create()                   routing 或 route 存在才走 plan_route
zoe-runtime/src/_pipeline.py:_require_attested()        ALLOWLIST_UNCONFIRMED + details.reason/next
zoe-runtime/src/_pipeline.py:_start_locked()            BLOCKED 可 resume；doctor 只在 prepare/implement/verify
zoe-runtime/src/_pipeline.py:run_checks()               执行前复校：cwd=workspace、search_path=os.environ["PATH"]
zoe-runtime/src/_pipeline.py:_gate_model_identity()     MODEL_MISMATCH 的 block_details 已含 reported/reported_models/request_echoes/declared_aliases
zoe-runtime/src/_pipeline.py:_gate_spend()              费用闸门对所有 run 生效（含 purpose=probe）
zoe-runtime/src/_pipeline.py:accept()                   state 必须 REVIEW_READY；subject_sha == validated_sha
zoe-runtime/src/cli.py:_task_recover()                  recover → BLOCKED + RUN_INTERRUPTED；树 unknown/写者锁被占则不收口
zoe-runtime/src/cli.py:_project_attest()                只有 --project/--profiles/--dry-run/--json，无 expected-*（TOCTOU）
zoe-runtime/src/cli.py:_route_command()                 route plan：只读预览，不传 spec_document
zoe-runtime/src/cli.py:_status_or_report()              status --json 返回完整任务记录（含 block_details）
zoe-runtime/src/_reports.py:snapshot()                  reported_model / reported_models / model_identity / identity_basis
zoe-runtime/src/_routing.py:attribution()               purpose=probe → 质量归因 excluded（不影响授权与费用）
zoe-workflows/scripts/zoe-monitor.sh                    退出码 0(终态|max-rounds)/2/10/11；ZOE_BIN 默认 zoe；依赖 jq；仅 .sh
zoe-workflows/build.py:WHITELIST / REQUIRED_FILES       docs/ 不打包；新增 reference 必须进 REQUIRED_FILES
zoe-runtime/tests/contract/test_skill_cli_contract.py   cli-contract 的 text 块命令必须真实存在
zoe-runtime/tests/test_doc_contracts.py                 SKILL.md 必须保留 max_active_tasks / verification_scope / NOT_RUN / dispatch_pending
```
