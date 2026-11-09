# 并行批次派发的摩擦收敛（评估 + 优化方案 v2）

| 项 | 内容 |
|---|---|
| 日期 | 2026-11-04 |
| 输入 | ① 本轮 T4/T5 批次执行评估（7 条问题）；② 对 v1 的可落地性评审（6 类必改 + B1–B5 重排 + 6 组新测试 + 四阶段路径） |
| 被评估对象 | `zoe-workflows`（`SKILL.md`、`references/*`、`scripts/*`、`build.py`）；`zoe-runtime@1.5.1` |
| 方法 | 每条建议先回到两仓源码与既有文档取证，再判定「文档缺口 / 执行不合规 / 运行时缺口」；评审提出的每处修正同样先取证，再决定是否改设计 |
| 本文位置 | `zoe-workflows/docs/`（不在 `build.py` 的 `WHITELIST` 内，不进入发布包） |
| 核验说明 | 源码以**符号名**为准；`1.5.1` 快照时间为 2026-11-04。凡「未实测」的推断已在条目内注明 |

## 修订记录

| 版本 | 变化 |
|---|---|
| v1 | 七条建议的判定 + S1～S7 改法；Skill A 项 + Runtime B1～B5（整体列为可选） |
| **v2** | 按评审修订 8 处：<br>① **S1 删除"顺序追加（C）"作为正式模式** —— git 合并不认"只追加"的约定，且 scaffold 接口必须是稳定契约、接线任务必须消费已集成产物（S1）<br>② **S3 把"无重叠即可并行"降级为风险预检**，补 TOCTOU 与三类重叠概念，明确静态检查不提供原子互斥（S3 / §1.11）<br>③ **S2 区分"新请求"与"同请求重传"**，脚本改为 `preview` 写文件 + `apply <file>` 提交指定文件，不再每次隐式重建（S2）<br>④ **B1（`expected_version: "latest"`）从"可选"改为"暂缓"**，若将来要做必须带 state/phase/run_id 前置条件（§0.2 / S2）<br>⑤ **S4 补机器可读结束原因**，预算改用单调时钟（新增 `--max-seconds`），并纠正"interval × rounds ≈ 时长"的估算（S4）<br>⑥ **S5 拆分依据改为三个维度**（可验收 / 可恢复 / 依赖冲突）；**B3 升为 P0**（S5）<br>⑦ **S6 修正证据链**：`--no-probe` 通过只证明静态规则通过；B2 改为"先测量，再优化缓存复用"（S6）<br>⑧ **S7 让 confirm 以 preview 文件为输入**并校验 project/profiles/动作未扩张（S7）<br>另：B5 只修注释（不引资源锁引擎）；S4 与 S8 的监控改动**合并为一次脚本变更**；新增"脚本纪律"与"四阶段实施路径" |

---

## 0. 结论

### 0.1 七条建议的判定

| # | 原建议 | 判定 | 本轮是否实施 | 主要调整 | 落点 |
|---|---|---|---|---|---|
| 1 | Spec 中把 `cmd/zoe/main.go` 排除出 `allowed_paths`，合并后由编排者手动接线 | **目标成立，做法否决** | 必做（文档） | 收敛为**两种**正式模式（前置 scaffold / 末尾接线）；删除"顺序追加"作为推荐；补两条硬条件 | S1 |
| 2 | `task resume` 只传 `task_id` + `strategy`，自动取最新 `row_version` | **成立，做法改写** | 必做（脚本） | `preview` / `apply <file>` 两段；区分新请求与同请求重传；不做 `expected_version=latest` | S2 |
| 3 | create 前强制 `task prepare` | **部分成立** | 必做（文档） | `prepare` 早已在 `SKILL.md` 第 3 步（本轮属执行不合规）；补"派发闸门"+ 三类重叠风险分级，且**不宣称互斥** | S3 |
| 4 | monitor 作为唯一监控手段 | **方向成立，需补语义** | 必做（文档 + 脚本） | 新增机器可读 `stop_reason`；预算改单调时钟；与 S8 的监控改动合并 | S4 |
| 5 | 复杂度预估 / 显式更长超时 | **推荐做法否决，文档化采纳** | 必做（文档 + B3） | 拆分依据改三维度；`timeout_seconds` 文档化并**升 B3 为 P0** | S5 |
| 6 | 在 skill 中写死必须传 `agent_profile: cb-run` | **不采纳写死** | 必做（文档） | 三步诊断法；`--no-probe` 只区分静态/动态；B2 先测量 | S6 |
| 7 | 提供 `attest.sh` 一键脚本 | **采纳但改形** | 建议同批 | 两段式，`confirm --preview f --policy-hash H`；校验预览输入未扩张 | S7 |

### 0.2 Runtime 项优先级（按评审重排）

| 项 | v1 | v2 | 理由 |
|---|---|---|---|
| B1 `expected_version: "latest"` | 可选 | **暂缓** | `row_version` 是乐观并发控制；在锁内解析为当前值等于绕过调用方对状态的原始认知。即便将来做，也必须要求调用方同时给出 `state` / `phase` / `current_run_id`，由运行时锁内核验——不是单给一个 `latest` |
| B2 路由探测优化 | 可选（预算可配置） | **P1，先测量** | 先证明"确实存在重复探测/预算耗尽"（缓存键含 `env_names` 只是**推断**，§1.7 未实测）；优先"复用一次探测"，其次才是"预算可配置"——配置化可能把性能问题变成更长的等待 |
| B3 `timeout_seconds` 校验 | 可选 | **P0，本轮完成** | 配置类型错误不应等到 run 的监视循环才暴露；改动小、无行为争议 |
| B4 `allowed_next` 补 `task resume` | 可选 | **P1，同批** | 接管入口对最需要动作的状态什么都不给，正是本轮"手工摸索"的来源 |
| B5 `shared_resources` | 实现或删注释 | **只修注释** | 为一个未实现的字段引入锁/租约/崩溃恢复/死锁处理=过度设计；未来有真实互斥需求时独立立项 |

### 0.3 明确不采纳 / 暂缓

| 项 | 理由 |
|---|---|
| "顺序追加到注册表末尾"作为正式并行模式 | git 合并依据共同祖先与实际差异，**不认"只追加"的约定**；三个并行切片从不同基点追加仍可能冲突或彼此覆盖 |
| 用静态路径预检宣称"已保证互斥" | TOCTOU：两个编排器可同时通过检查（§1.11）；Skill 层只能降低风险 |
| 本轮引入资源锁 / 租约 / 占用登记引擎 | 需求未证实；复杂度收益比不成立。分类概念先落文档，运行时能力独立立项 |
| `expected_version: "latest"` | 弱化 optimistic concurrency 的原语义（§0.2 B1） |
| 新增 `zoe-prepare.sh` / `zoe-route.sh` / `zoe-recover.sh` 等包装脚本 | 无重复劳动证据；脚本越多人越容易各自实现一套状态校验（§4.3 脚本纪律） |
| 在通用 skill 中硬编码某个 `agent_profile` | 环境绑定规则会腐化，且绕开"授权变更只能由人发起" |
| `attest` 一键到底 | 中间少了用户同意；`--expect-*` 只是防错位 |
| 按预估时长/行数决定拆分 | 与「不按『时长 / 行数 / 是否盯着』路由」冲突 |

> 追加项（同轮）：S4 只解决"监控只有一条事实来源"，那条来源里仍缺"子进程在做什么"的文字线，
> 见 [2026-11-04-subprocess-progress-text-visibility.md](2026-11-04-subprocess-progress-text-visibility.md)（S8-A～S8-E）。
> **两者的监控改动必须合并为一次脚本变更**（stop_reason + `--max-seconds` + `[tick]` 带 phase + `--with-log`）。

---

## 1. 事实核对

### 1.1 越界改动是硬失败，不是提示

`_backend.scope()` 在每次 run 收尾时对 `git diff base_sha` + untracked 求差，逐条与 `allowed_paths` / `protected_paths` 比对，任一越界即：

```text
SCOPE_VIOLATION: <n> path(s) violate the frozen policy
details: violations[] / missing_paths[] / allowed_paths[] / scope_source
```

任务级范围来自 spec（`_pipeline._resolve_task_scope`），且只能收紧项目范围（`_contracts` 拒绝「Spec allowed_paths widen the project policy」）。

两条硬事实：

1. 若 spec 的 `allowed_paths` **不含**入口文件，而 Worker 为实现子命令改了它（常规动作），本次 run 一定以 `SCOPE_VIOLATION` 收场；改动留在 worktree 但不成为 candidate；
2. 「由编排者合并后手动接线」把业务代码写回编排会话：本 skill 的边界是「允许读取代码和差异、编写 Spec/请求/报告；业务代码由 Worker 实现」，手写接线既越界，也绕过 checks、证据链与独立判者。

**结论**：根因不是"路径声明不够窄"，而是"多个切片都要改同一个集成点"。修法是把集成点变成**单独的一次串行执行**。

### 1.2 同一文件的并行，靠"缩小范围"解决不了

`references/decomposition-patterns.md` 已写明：`allowed_paths` / `expected_paths` 重叠是**集成风险提示**，不是拒绝理由；运行期副作用不算进 worktree 隔离。它对「共享生成目录 / 固定端口」有交代，对「共享**源文件**（入口注册、路由表、schema 索引）」没有可执行方案 —— 这是本轮 T4c 合并冲突暴露的文档缺口。

### 1.3 `shared_resources` 只是声明，不是互斥

`_profiles.normalize_config()` 的注释写着 "Two tasks sharing any resource are serialized"，但全仓只有这一处提到该字段：

```text
zoe-runtime/src/_profiles.py    normalize_config()   仅校验形状并规范化 {kind, id}
zoe-runtime/src/_pipeline.py    无引用
zoe-runtime/src/_store.py       无引用
zoe-runtime/src/_group_runner.py 无引用
```

**当前没有任何代码按 `shared_resources` 串行化任务**。因此：不得把它写成"会自动排队"的保证；注释与实现不一致本身是缺陷（B5 只修注释）。

### 1.4 `task resume` 的请求体是四要素 + 幂等哈希

`start()`（`resume` 与 `start` 同一函数）在写者锁内依次校验：

| 校验 | 字段 | 失败码 |
|---|---|---|
| 幂等键 | `schema_version` ∈ {1,2}、`request_id` | `INPUT_INCOMPLETE` / `REQUEST_CONFLICT` |
| 授权 | `authorization_ref`（比对**任务冻结配置**）且 `authorized_actions` 含 `execute` | `AUTH_REQUIRED` / `POLICY_DENIED` |
| 并发版本 | `expected_version` == 当前 `row_version` | `STATE_CONFLICT`（"Refresh expected_version"） |
| 可恢复性 | `state ∈ READY/PAUSED/BLOCKED`；`block_code != INPUT_REQUIRED` | `STATE_CONFLICT` |
| 策略一致性 | 项目当前 `policy_digest` == 任务冻结值 | `POLICY_CHANGED` |
| 授权确认 | 有效 `attest` 记录覆盖本次候选 | `ALLOWLIST_UNCONFIRMED` |
| 策略语义 | `strategy ∈ auto/workspace` | `CAPABILITY_UNSUPPORTED`（`native`） |

幂等键是 `digest([action, task_id, request])`（`_store._operation_key`），**载荷进哈希**：

> 同一个 `request_id` 改了 `expected_version` 再提交 ⇒ `REQUEST_CONFLICT`，**不是**「重试」。

这条决定了脚本的形态：**同一份请求（同 id、同载荷）可安全重传；新意图必须新请求**（S2）。

### 1.5 `task prepare` 已经存在，缺的是「闸门」与「重叠预检」

`_prepare.prepare()` 是只读实现（不建 `Store`、不建 `state.db`），报告含：`prepared`、`diagnostics[]`（`code`/`field`/`reason`/`suggested_change`/`requires_approval`/`source`）、`profile`（含 `conflicts`）、`checks.preflight`、`allowed_paths.warnings`、`snapshot.policy_hash`。

`SKILL.md` 第 3 步已写「写完不要直接 create：先做一次只读准备」，`cli-contract.md` 亦有「只读准备」整节。**本轮「直接 create + start」属执行不合规，不是文档缺失。**

它覆盖不到的只有一类：**跨任务重叠**。`allowed_paths.warnings` 来自 `_config.path_warnings()`，判的是项目级声明（`SCOPE_INVALID` / `SCOPE_COVERS_REPO` / `SCOPE_MISSING`）；`prepare` 不构造 `Store`，看不到在途任务。

### 1.6 监控脚本的语义边界

| 事实 | 值 |
|---|---|
| 只观察 | 读 `task status`（权威）+ `zoe watch`（事件）；不推进任务或组 |
| 参数 | `--project` / `--targets` / `--targets-file` / `--events` / `--cursor-file` / `--interval` / `--max-rounds`；**没有 `--json`，也没有 `--max-seconds`** |
| 依赖 | `jq`、`bash`、可执行的 `zoe`；缺一即 `exit 2` |
| 退出码 | `0` 全部终态 **或** `--max-rounds` 到期（同码不同义）、`2` 用法/依赖、`10` 剩余目标都需人、`11` `watch` 连续失败到 `--max-errors` |
| 节奏 | 每轮一行 `[tick]`；感知延迟 ≈ `--interval` + 每轮 CLI 查询耗时 |
| 游标 | 默认 `./zoe-cursor.txt` / `./zoe-events.jsonl`（按项目隔离需显式给路径） |
| 不做的事 | 不推进组、不判断「成功」（只判终态） |

因此评审指出的两处要补：**结束原因不可机器判定**（`0` 双义）、**预算只按轮数估算**（漏掉每轮查询与重试耗时）。

### 1.7 候选级 `ENVIRONMENT_ERROR` 有三个来源，`cb-run` 不是结论

| 触发 | 判据 | `detail` 文案 | 真实含义 |
|---|---|---|---|
| 探测预算耗尽 | 单次 `plan_route` 的 `time_budget` 固定 `5.0s`，逐候选 `doctor(probe=True)` | `probe budget exhausted` | **探测慢**，不是环境坏 |
| `doctor.ready=false` | 六项合取（`git`/`process_identity`/`platform_lock`/`platform_tree`/`checks_preflight_ok`/`placeholders_ok`） | `doctor reports not ready` | 环境或配置 |
| CLI 未解析 | `resolution_path is None` | `agent CLI not resolved on this host` | 该 profile 的 `env_names` 下找不到二进制 |

可能放大第一条的条件：`_discovery` 的缓存键是 `(cli, explicit, env_names, probe)`，**每个 profile 的 `env_names` 不同就会各起一次子进程**。该推断**未实测**，只能作为待验证假设（S6 第一步就要求先看 `detail`，而不是先信这条推断）。

另一条易误读的事实：`decide()` 在**显式指定**时把候选收窄为 1 个且不回落，所以此时的 `ENVIRONMENT_ERROR` 只说明"这一个候选不可用"。

### 1.8 `project attest` 已有 `--expect-*`，摩擦在参数构造与绑定

`_project_attest()` 支持 `--project` / `--profiles` / `--dry-run` / `--expect-policy-hash` / `--expect-profiles`；比对与写入在同一把 control 锁内完成，不一致返回 `ATTEST_PRECONDITION_FAILED` 且**不写入**。

因此第 7 条不是能力问题，而是**预览与确认的绑定问题**：只比 hash + profile 集合，还不能证明"project、动作、关键执行配置也没变"（S7）。

### 1.9 `timeout_seconds` 是项目级、未校验、未文档化、且进 `policy_digest`

| 事实 | 证据 |
|---|---|
| 读的是**项目配置**顶层字段 | `_backend.LocalProcess`：`deadline = now + self.c.get("timeout_seconds", 3600)` |
| 默认 3600s | 同上 |
| 没有校验 | `validate_config()` 全文无该字段：**缺字段**才用默认值；类型写错不会在注册/预检期被拒，只会在 run 的监视循环里暴露为运行期错误 |
| 两仓文档都没写 | `SKILL.md` / `references/*` / runtime `docs` 检索 0 命中；仅 `project-profile.advanced.example.json` 有一个 `3600` 示例 |
| 改动会改策略摘要 | `_profiles.policy_digest()` = `digest(normalize_config(c))`，整份配置参与 |

因此「给这个任务更长超时」在当前版本**不存在**：只能改项目级配置，而改它会让**所有在途任务**撞 `POLICY_CHANGED`（需 `rebind`）。

### 1.10 超时丢失的是"上下文"，不是"文件"

1. 控制器只在 `phase=verify` 里 `git add --all` + `commit` 生成 `candidate_sha`；实现阶段不提交；
2. `RUN_TIMEOUT` 后任务停在**可 resume** 状态，`block_code` 保留 `RUN_TIMEOUT`（源码注释：任务级错误码保持原值）；
3. `_worktree.quarantine()` 只在闸门失败（模型身份 / 费用）时调用，`RUN_TIMEOUT` **不隔离**工作区；`resume` 用 `strategy=workspace` 复用同一 worktree；
4. `attempts` 在 spawn 之前 `+1`（`update(attempts=t["attempts"] + 1)`），每次 resume 都消耗一次；`max_attempts` 默认 3。

结论：**代码没丢**，丢的是「上一个 Agent 的理解」。所以恢复的价值取决于新 run 能否快速接管已有改动（`task handoff` + prompt 里的上次失败记录）。

### 1.11 静态预检 ≠ 原子互斥（评审新增，v2 采纳）

| 时刻 | 编排会话 A | 编排会话 B |
|---|---|---|
| T1 | 检查文件 X 未被占用 | |
| T2 | | 检查文件 X 未被占用 |
| T3 | 判定可派发 | |
| T4 | | 判定可派发 |
| T5 | `create`+`start` A | |
| T6 | | `create`+`start` B |

两个会话都通过了预检，仍然同时占用同一逻辑集成点 —— 典型 TOCTOU。Skill 层能做的是**降低风险并给出推荐顺序**，不是提供互斥保证。

同时要纠正一处直觉：worktree 隔离下，**相同路径不等天然互相覆盖**；真正的冲突发生在候选合并、共享外部可变资源、依赖契约变更这三处。

### 1.12 三类重叠（文档概念，不新增字段/错误码）

| 分类 | 含义 | 处置 |
|---|---|---|
| `OVERLAP_WARNING` | 共享源码路径；独立 worktree 可安全开发 | 可并行；**记录合并风险**与合并顺序 |
| `INTEGRATION_REQUIRED` | 共享入口、注册表、schema 索引 | 走 S1 的 A/B：串行 scaffold 或末尾接线 |
| `EXCLUSIVE_RESOURCE` | 共享外部可变资源（固定端口、测试库、生成目录、远端环境） | 必须串行；未来由 Runtime 的占用登记保证（本轮不做） |

---

## 2. 采纳项与详细改法

### S1 集成点冲突：两种正式模式 + 两条硬条件（P0）

**目标**：让「新增一个需要注册的入口」在并行批次里冲突可预期，且不把业务代码推给编排者。

**落点**：`references/decomposition-patterns.md` 新增小节；`SKILL.md` 第 4 步「四条硬前提」第 3 条后补一句指向。

**改法**：

```text
【新增小节】模式二之一：共享集成点（入口注册 / 路由表 / schema 索引）

同一文件是多个切片的必经改动点，并行改它必然冲突。`allowed_paths` 重叠不是
拒绝理由，但**把它从范围里删掉也不是解法**：Worker 为了让产物可用通常会改它，
而越界改动会让该 run 以 SCOPE_VIOLATION 收场（改动留在 worktree，不成为 candidate）。

只有两种正式模式：

| 模式 | 做法 | 适用 |
|---|---|---|
| A. 前置 scaffold（首选） | 先派一个**串行**任务，只做"入口注册 + 空实现桩"，AC 是「编译通过、既有命令不受影响」；随后并行各片只在本片包里实现，`allowed_paths` 不含入口文件 | 入口只需加注册行、各片互相独立 |
| B. 末尾接线 | 并行各片都不碰入口；合并后派一个串行任务，`allowed_paths` 只含入口文件，AC 含「新命令 `--help` 可用」+ 集成检查 | 入口改动需要看过三片产物才能确定 |

两种模式的硬条件（缺一条就把冲突推迟到验收阶段）：

1. **scaffold 形成的接口是稳定契约**：后续切片不得各自调整 scaffold；要改就回
   到 scaffold 任务（新一次串行执行），不能在并行片里"顺手改一下"；
2. **接线任务必须消费已集成的上游产物**：不得在任意旧基线上执行；完成条件至少
   包含"入口可用"与"集成检查通过"，而不是只"编译通过"。

不要用"三片都只追加到注册表末尾 + 约定合并顺序"：git 合并依据共同祖先与实际
差异，**不认"只追加"的约定**；三个切片从不同基点追加仍可能冲突或彼此覆盖。
这只能作为人工应急（且必须由人解冲突），不作为模式推荐。

也不要把 A/B 写成"编排者合并后手动接线"：业务代码由 Worker 实现，编排者只写
Spec/请求/报告；手写接线既不进 checks 也不进证据链。
```

**判错**：文档保留"顺序追加"作为推荐模式；或出现「把入口文件排除出 `allowed_paths`、由编排者合并后手动接线」；或声称 `shared_resources` 会串行化同一文件。

### S2 `resume` 脚本：`preview` / `apply` 两段，区分两种重试（P0）

**目标**：把「查 `row_version` → 拼 JSON → 撞 `STATE_CONFLICT` → 再查」压成可审查的两步；同时**不制造重复执行**。

**落点**：新增 `scripts/zoe-resume.sh`（POSIX，依赖 `jq`）；`SKILL.md` 第 7 步引用；`build.py` 的 `REQUIRED_FILES` 补登；`references/recovery-policy.md` 补「超时后恢复」。

**核心修正**：v1 的「每次重新生成 `request_id`」会把**传输重试**也变成新意图。正确语义是：

| 场景 | 行为 |
|---|---|
| 新一次恢复意图 | 新 `request_id`（新请求文件） |
| 同一请求传输失败/响应丢失，不确定是否已提交 | **保留原 `request_id` 与原载荷**重放，或用 `task status --refresh` 查结果 |
| `STATE_CONFLICT`（版本已前进） | **重新 `preview`** 生成新请求 |
| `PROCESS_UNKNOWN` | 禁止 resume，先做执行归属核查（`task recover` 路径） |

**脚本契约**：

```text
bash <skill-dir>/scripts/zoe-resume.sh preview --project P --task T [options]
    --strategy S          auto(默认) / workspace
    --reason TEXT         写入请求的 reason（给人看的短句）
    --authorization-ref R 缺省取 `task status --json` 的 config.authorization_ref（任务冻结值）
    --out DIR             默认 .zoe/<P>/requests
  → 只落盘请求文件 + 打印人可读摘要（state/block_code/row_version/strategy），不提交

bash <skill-dir>/scripts/zoe-resume.sh apply --request-file F [--json]
  → 原样提交该文件（不改 id、不改载荷）；打印返回的 state/row_version
  → STATE_CONFLICT：提示"版本已前进，重跑 preview"，**不自动改用新版本**
```

`preview` 的四条闸门（缺一不出文件）：

1. `state ∈ READY/PAUSED/BLOCKED`；
2. `block_code=INPUT_REQUIRED` → `exit 3` 并提示 `task answer`；
3. `block_code=PROCESS_UNKNOWN` → `exit 3` 并提示先对账；
4. `expected_version` 取 **`--refresh` 之后**的 `row_version`（不要复用上一次 `status` 的输出）。

**为什么不走 `expected_version: "latest"`**：见 §0.2 B1。脚本把版本选择权留在调用方，`apply` 只在用户看过预览后执行——这比引入 `latest` 更便宜，也不削弱乐观并发控制。

**判错**：文档写"resume 失败就换新 id 再提交一次"；或 `apply` 内部重新构造请求；或 `apply` 在 `STATE_CONFLICT` 后自动改用最新版本。

### S3 派发闸门 + 三类重叠预检（P0，**不宣称互斥**）

**目标**：让"没跑预检"结构性不可能漏，并把重叠风险分级；**不**声称提供了原子互斥。

**落点**：`SKILL.md` 第 3 步末尾（闸门）、第 4 步（重叠预检）；`cli-contract.md` 不动。

**改法（第 3 步末尾）**：

```text
**派发闸门（create 之前，逐条核过才算过）**：

1. `task prepare --project P --spec spec.json` 返回 `prepared: true`，且
   `diagnostics[]` 里 `requires_approval: true` 的项都有明确的人类批准记录；
2. `profile.conflicts` 为空（未知 profile、`MODEL_PIN_CONFLICT` 都在这里出现）；
3. 本批次要并行的每一片，与在途任务的重叠已分类并处置（见第 4 步）；
4. 项目声明了 `routing` 时，`route plan` 的候选集合与预期一致（见 S6）。

缺任一条就**不要 create**：`create` 会重算并拒绝，但只给"第一个错误"，
`prepare` 给的是一次看全。两者信息量不同，不能互相替代。

注意 `prepared: true` 只表示"没有阻断性问题"，**不保证 `start` 成功**：
后面的准入（策略摘要、attest、owner、槽位）是另一组条件。
```

**改法（第 4 步，四条硬前提之后）**：

```text
**并行重叠预检：这是风险分级，不是互斥保证**

`prepare` 不做这件事（它不构造 Store，看不到在途任务）：

    zoe task list --project P --json
    zoe task status T --json --refresh        # 读 task_scope / state / phase

判据按 `_paths.covers` 语义（目录前缀包含 / 路径相同）；`task_scope` 为空表示
沿用项目范围，此时按**项目范围**比较（保守取大）。

| 分类 | 判定 | 处置 |
|---|---|---|
| OVERLAP_WARNING | 共享源码路径，但各自 worktree 可安全开发 | 可并行；把"合并顺序 + 谁负责解冲突"写进本批计划 |
| INTEGRATION_REQUIRED | 共享入口/注册表/schema 索引 | 走 S1 的模式 A/B，不靠"记得小心点" |
| EXCLUSIVE_RESOURCE | 共享外部可变资源（固定端口、测试库、生成目录、远端环境） | 必须串行（同一时刻只跑一个） |

**两个必须写明的限制**：

1. 这是**派发前**的静态检查，两次检查之间状态可能变化（TOCTOU）；两个编排
   会话同时检查同一路径时，都可能通过。它降低风险，**不提供原子互斥**；
2. worktree 隔离下相同路径不等天然互相覆盖；真正的冲突在候选合并、共享外部
   资源、依赖契约变更这三处。

也不要试图用 `shared_resources` 声明同一文件来换取排队：当前版本该字段只做
规范化，不产生任何串行化。
```

**判错**：文档把重叠预检写成"保证不会冲突/已互斥"；或写「`prepare` 能发现并行冲突」；或把 `prepared: true` 写成「保证 start 成功」。

### S4 监控：结束原因可机器判定 + 单调预算（P0，与 S8 合并）

**目标**：一条事实来源，且"为什么停"可被宿主直接读取，不依赖人看日志。

**落点**：`scripts/zoe-monitor.sh` / `.ps1`（**与 S8-B1/B2 同一次改动**）、`SKILL.md` 第 6 步。

**改法 1（脚本）**：新增两类输出，**不改现有退出码**：

```text
--max-seconds N    实际截止时刻（单调时钟），与 --max-rounds 取先到者
--stop-file F      把结束原因写成 JSON（默认不写）

[stop] reason=<ALL_TERMINAL|BUDGET_EXHAUSTED|HUMAN_REQUIRED|WATCH_ERROR|DEPENDENCY_ERROR>
```

`--stop-file` 内容：

```json
{"monitor_stop_reason":"BUDGET_EXHAUSTED","all_terminal":false,
 "next_cursor":"…","rounds":12,"elapsed_seconds":301}
```

实现要点：预算用**单调时钟**（`date +%s` 差值或 `SECONDS` 亦可，但必须与实际耗时比较），不再用 `interval × rounds` 估算——每轮还有 CLI 查询与重试耗时。

**改法 2（SKILL 第 6 步）**：

```text
**宿主侧怎么用**（GUI 宿主、无附着终端时）：

1. 把监控作为**后台任务**起，回合内不阻塞；
2. 预算用 `--max-seconds`（配合 `--max-rounds` 做硬保险），让它略小于本回合可用
   时长；回合末读它的**退出码 + `[stop] reason` + 末几行**；
3. 退出后按 `reason` 分流，**先** `task status --refresh` 核对，再决定续跑还是汇报。

`[stop] reason` 是唯一允许被引用的"结束原因"：
- `ALL_TERMINAL` → 可以进入汇报，但仍需 `task report` 的验收结论；
- `BUDGET_EXHAUSTED` → **不是完成**，带 `next_cursor` 续跑；
- `HUMAN_REQUIRED` → 逐个人工处理项；
- `WATCH_ERROR` / `DEPENDENCY_ERROR` → 监控本身不可用，不是任务失败。

**禁止把 `sleep N && task status` 当主循环**：没有游标（重启即丢停机期间事件）、
没有"需人工介入即停"、没有 liveness 证据（`[tick]`）。它只在 `watch` 不可用时兜底，
且兜底时仍要自维护游标与同样的结束条件。
```

**判错**：文档把「脚本返回 0」或「`--max-rounds` 用满」写成完成；或把 `interval × rounds` 当作时长保证；或把 `WATCH_ERROR` 读成任务失败。

### S5 拆分三维度 + `timeout_seconds` 文档化 + B3 升 P0（P0 / P1）

**目标**：减少 `RUN_TIMEOUT` 的实际发生率，并让"超时之后怎么办"有确定答案。

**落点**：`decomposition-patterns.md`（拆分依据）、`runtime-contract.md`（`timeout_seconds` 首次文档化 + B3）、`recovery-policy.md`（超时后恢复）、`worker-prompt.md`（一条纪律）。

**改法 A（拆分依据：三个维度，不是只看 AC）**：

```text
拆不拆，看三件事；只满足"有独立 AC"并不足以拆：

| 维度 | 判断问题 | 不满足时 |
|---|---|---|
| 可独立验收 | 这一片能否定义明确的 check 与交付证据？ | 拆了也只是同一判据跑两次 |
| 可独立恢复 | 失败后能否只重跑这一片，而不是推倒整条任务？ | 拆分反而放大重跑成本 |
| 依赖与冲突 | 前后依赖能否写清、共享集成点是否可收敛？ | 先按 S1 处理集成点，再谈并行 |

典型仍需拆的例子：一次数据迁移只有一个最终验收目标，但包含 schema 变更、数据
迁移、应用兼容验证三个**天然有序**的步骤 —— 依据是"可独立恢复"（失败只需重跑
其中一步），不是"有三个 AC"。

不要用"预计 15 分钟 / 50 分钟 / 代码行数"作依据：这与「不按『时长 / 行数 /
是否盯着』路由」是同一条纪律。长跑本身不是问题，**跑完才发现没到可验收点**才是。
```

**改法 B（`timeout_seconds` 文档化）**：

```text
【新增小节】单次 run 的墙钟上限（`timeout_seconds`）

| 项 | 值 |
|---|---|
| 作用域 | **项目级**，不是任务级、不是 profile 级 |
| 默认 | `3600`（秒）；**缺字段**时用默认值 |
| 生效点 | 本机后端在 run 监视循环里按墙钟判定，超时以 `RUN_TIMEOUT` 结束该 run |
| 副作用 | 属于项目配置，改动会改变 `policy_digest`：在途任务随后 `start/resume` 会撞 `POLICY_CHANGED`，需 `rebind` |

因此：**不存在"给这个任务单独延长超时"的开关**。要延长只能改项目配置并接受
上述代价；更便宜的做法是把任务切到"能在默认上限内到达可验收点"。
该字段在 v1.5.1 **不参与 `validate_config`**：写成字符串之类的形态不会在注册/
预检期被拒，只会在 run 的监视循环里暴露为运行期错误（B3 修这个）。
```

**改法 C（超时后的恢复，`recovery-policy.md`）**：

```text
`RUN_TIMEOUT` 之后：任务停在可 resume 状态，`block_code` 保留 `RUN_TIMEOUT`；
该 run 已消耗一次 attempt（spawn 之前就 +1，`max_attempts` 默认 3）。

resume 之前看清三件事：

1. 工作区还在：RUN_TIMEOUT 不触发隔离，未提交改动仍在 worktree；
2. 会有新 run：commit 只发生在 phase=verify 且 checks 通过后，新 run 面对的是
   "半成品工作区"，必须先核实已有改动（`task handoff show` + 上次失败记录），
   否则会重复劳动或覆盖；
3. 预算在减少：每 resume 一次消耗一次；连续超时最容易撞 RETRY_EXHAUSTED。
   第二次仍超时就该改拆分，而不是继续 resume。

恢复同样受准入约束：`PROCESS_UNKNOWN` 不得直接 resume（先对账）；
`POLICY_CHANGED` 需先 `rebind`；`INPUT_REQUIRED` 需先 `task answer`。
```

**改法 D（`worker-prompt.md` 补一句）**：

```text
   自测与落盘按"可交付切片"推进：每完成一个切片就跑一次批准的自测命令，并把当时
   的文件变更与结论写进结果文件；不要等到最后一次性输出——被中断时，上一份结果
   文件就是下一个 run 的 handoff。
```

**Runtime B3（升 P0）**：

```text
validate_config() 增加 timeout_seconds 校验：
- 必须是整数秒（显式排除 bool —— Python 里 isinstance(True, int) 为真）；
- 范围 60..86400，越界给 INPUT_INCOMPLETE，reason 写清合法区间；
- doctor 的 checks 里回显生效值（如 checks["run_timeout_seconds"]），
  便于"实际会用多少"可观测；
- 不引入任务级超时，不改 policy_digest 口径。
```

**判错**：文档出现「按预估时长决定是否拆分」；或写「`timeout_seconds` 可按任务指定」；或把"只有一个 AC"当成"不能拆"。

### S6 候选级 `ENVIRONMENT_ERROR`：三步诊断，不写死 profile（P1）

**目标**：让「自动路由选到某候选就报 `ENVIRONMENT_ERROR`」有可复现的定位路径，且结论与证据强度匹配。

**落点**：`SKILL.md` 第 2 步（`ready` 子项表之后）；`runtime-contract.md`（路由诊断小节）。

**改法**：

```text
**`ENVIRONMENT_ERROR` 出现在候选上时，按三步取证，不要跳到结论**：

1. 先看是什么：`route plan --json`（或 `create` 的 details）里 candidates[] 的
   `code` / `detail` / `layers`。三者同码不同因：
   | detail | 含义 |
   |---|---|
   | probe budget exhausted | 候选探测超预算（不是环境坏） |
   | doctor reports not ready | 六项合取有一项为假 |
   | agent CLI not resolved on this host | 该 profile 的 env_names 下找不到二进制 |
2. 再分静态/动态：`route plan --json --no-probe`。**它成功只说明"不探测时静态规则
   通过"，不能证明 CLI 可执行、依赖完整、模型可用，也不能单独证明预算问题。**
3. 再单独验该候选：`zoe doctor --project P --agent-profile <候选> --json`，看
   `checks` / `resolution` / `resolution_notes` / `policy_problems`，并**自己计时**
   （doctor 目前不输出探测耗时，用 `time` 包一层）。

只有当多次观察都指向"探测慢"时，才考虑 §4-B2（优先复用探测、缓存，其次才是预算
可配置）。

三处纪律：

- **显式指定时候选只有一个**：此时的 ENVIRONMENT_ERROR 只说明"这一个候选不可用"，
  不能读成"整份白名单都不可用"；
- **不得因此自行换 profile**：候选被排除是环境或授权结论，换执行配置只能用户决定；
- 若要固定默认档，改的是**项目配置**（`routing.mode` / `default_agent_profile`），
  改完必须重新 `attest`，在途任务 `rebind`。
```

**判错**：文档写「`--no-probe` 成功就证明是探测预算问题」；或出现「本环境必须显式传 `<某 profile 名>`」。

### S7 `attest.sh`：确认绑定到完整预览输入（P1）

**目标**：把「dry-run → 人工确认 → 写入 → 核对」的机械部分脚本化，且**确认的是同一份预览**。

**落点**：新增 `scripts/zoe-attest.sh`；`SKILL.md`「执行配置与模型授权」第 1–3 步引用；`build.py` 的 `REQUIRED_FILES` 补登。

**改法（`--preview` 是 Skill 脚本参数，不是运行时命令）**：

```text
bash <skill-dir>/scripts/zoe-attest.sh preview --project P [--profiles a,b] [--out F]
  → 落盘预览文件（policy_hash / confirmed_profiles / execution[] / previous /
    project_id / requested_actions），打印人可读表格；不改任何记录

bash <skill-dir>/scripts/zoe-attest.sh confirm --preview F --policy-hash H [--confirm-profiles …]
  → 校验预览文件完整性：
      1. 文件里的 project_id == 本次要写入的 project；
      2. --policy-hash 与文件里的 policy_hash 逐字相等；
      3. --confirm-profiles ⊆ 文件里的 requested_profiles（**不得扩张**）；
      4. requested_actions 与关键执行配置（backend/profile/endpoint）未变；
      5. 文件未被修改（脚本记录自身写入的 sha256，confirm 时核对）；
  → 全部通过后，把预览里的参数**原样**交给
    `zoe project attest --expect-policy-hash H --expect-profiles …`（运行时仍会锁内再比一次）
  → 返回后逐字核对 policy_hash / confirmed_profiles：
      ATTEST_PRECONDITION_FAILED → 未写入，重新 preview + 重新取得同意
```

三条纪律不变：

1. `confirm` 必须带 `--policy-hash`；脚本不提供"不带 hash 直接写"的路径；
2. **只有用户明确同意后才能运行 `confirm`**；脚本降低手抄成本，不降低同意门槛；
3. 脚本**不自动挑选** profile；收窄集合只能来自用户的表达。

另加一条：脚本**不新增授权数据库、不做审批流**。预览文件是临时产物（默认落在 `.zoe/<P>/attest/`，可被覆盖），真相仍在运行时的 attest 记录里。

**判错**：脚本提供"一键 preview+confirm"；或 `confirm` 只比 hash 不比 project/profiles；或文档把「脚本跑成功」写成「用户已确认」。

---

## 3. 明确不做

| 项 | 理由 |
|---|---|
| 从 `allowed_paths` 删掉共享集成点、合并后手写接线 | 越界即 `SCOPE_VIOLATION`；编排者写业务代码越界且无独立判者 |
| "顺序追加 + 约定合并顺序"作为正式并行模式 | git 不认约定；不同基点的追加仍可能冲突/覆盖（S1） |
| 用静态预检宣称"已互斥" | TOCTOU；两个编排会话可同时通过（§1.11） |
| 本轮引入资源锁 / 租约 / 占用登记引擎 | 需求未证实；`shared_resources` 只修注释（B5） |
| `expected_version: "latest"` | 弱化 OCC；若要做必须带 state/phase/run_id 前置条件（§0.2 B1） |
| 用 `shared_resources` 当文件级互斥锁 | 运行时未实现（§1.3） |
| 新增 `zoe-prepare.sh` / `zoe-route.sh` / `zoe-recover.sh` | 无重复劳动证据；见 §4.3 脚本纪律 |
| 按时长/行数预估决定拆分 | 与既有路由纪律冲突 |
| 在通用 skill 里硬编码某个 `agent_profile` | 环境绑定规则会腐化，且绕开"授权变更只能由人发起" |
| `attest` 一键到底 | 少了用户同意；`--expect-*` 只是防错位 |
| 把 `sleep + status` 写成与脚本等价 | 无游标、无 needs-human、无 liveness 证据 |
| Skill 侧再造一套「并行冲突检测引擎」 | 事实源仍是 `task_scope` 与 `_paths.covers`；给判据与命令即可 |
| 为长任务新增"任务级 timeout" | 会把策略摘要变成"半个策略"；先解决口径（B3 只做校验与回显） |

---

## 4. 实施路径与工作量

### 4.1 四阶段（按评审建议，先固定 Runtime 契约，再适配 Skill，最后合并监控改动）

| 阶段 | 内容 | 依赖 |
|---|---|---|
| **一：Runtime 最小修复** | B3（`timeout_seconds` 校验 + doctor 回显）、B4（`allowed_next` 补 `task resume`）、B5（只修 `shared_resources` 注释） | 无 |
| **二：Skill 核心流程** | S1（两种模式）、S3（闸门 + 三类重叠）、S5-A/C/D（拆分三维度、恢复、worker 纪律）、S6（三步诊断）、S5-B（`timeout_seconds` 文档化，随 B3 一起写） | 一（B3 的 doctor 字段决定文档写法） |
| **三：脚本与观测** | S2（`zoe-resume.sh`）、S7（`zoe-attest.sh`）、**S4 + S8 合并的 monitor 改动**（stop_reason / `--max-seconds` / `[tick]` phase / `--with-log`） | 一（B4 影响接管提示） |
| **四：端到端验收** | 并行派发 → 运行监控 → 超时恢复 → 验证 → 候选验收（§5 集成测试） | 二、三 |

### 4.2 工作量

| 阶段 | 项 | 估时 |
|---|---|---|
| 一 | B3 0.3 + B4 0.2 + B5 0.1 | 0.6 |
| 二 | S1 0.4 + S3 0.5 + S5-A 0.2 + S5-B 0.3 + S5-C/D 0.3 + S6 0.4 | 2.1 |
| 三 | S2 0.7 + S7 0.6 + monitor（S4+S8 合并）1.0 | 2.3 |
| 四 | 集成测试 + 三仓门禁 | 0.8 |
| 合计 | | **≈5.8 人日**（不含 Runtime B2，不含 S8-E 条件实施） |

比 v1 的 3.4 人日高，主要差在：monitor 从"改文档"变成"脚本 + 语义"、S2 从"生成请求"变成"两段式 + 幂等语义"、新增集成级验收。

### 4.3 脚本纪律（评审第七条，作为长期约束）

| 脚本 | 只做 | 不做 |
|---|---|---|
| `zoe-monitor` | 统一观测：状态 + 事件 + 结束原因（+ 可选的文字进展） | 不推进任务/组、不判成功、不实现状态机 |
| `zoe-resume` | 构造请求（preview）、提交请求（apply） | 不决定"该不该 resume"、不改版本、不换 profile |
| `zoe-attest` | 生成预览、校验预览、原样转交运行时 | 不选 profile、不代替用户同意、不建授权库 |

通用约束：

1. 每个脚本**不得自实现**状态校验、错误码映射、配置解析、授权逻辑——它们是运行时的职责，脚本只做薄入口；
2. 新增包装脚本前必须先有"重复劳动证据"（同一套命令在一次批次里被手工重复 ≥3 次）；
3. 脚本失败必须可区分"用法错误 / 前置条件不满足 / 环境不可用"，并映射到稳定退出码。

---

## 5. 验收：反例优先

### 5.1 原有 8 组（保留）

| # | 反例 | 通过标准 | 覆盖 |
|---|---|---|---|
| 1 | 三片并行都要改入口文件，且 spec 的 `allowed_paths` 不含它 | 该 run 以 `SCOPE_VIOLATION` 结束（验证"排除法不是解法"），文档指向 S1 的 A/B | S1 |
| 2 | `block_code=INPUT_REQUIRED` 时跑 `zoe-resume.sh preview` | `exit 3`、不产生请求文件、提示 `task answer` | S2 |
| 3 | `block_code=PROCESS_UNKNOWN` 时跑同一命令 | `exit 3`、不产生请求、提示先对账 | S2 |
| 4 | 同一 `request_id`、改 `expected_version` 提交 | `REQUEST_CONFLICT`（证明"新意图必须新请求"） | S2 |
| 5 | `monitor --max-rounds 1` 退出时任务仍 RUNNING | 汇报不得出现"已完成"，且 `[stop] reason=BUDGET_EXHAUSTED` + `next_cursor` | S4 |
| 6 | 某候选 `detail=probe budget exhausted` | 三步诊断能复现：`--no-probe` 通过**且** 单独 doctor 计时超预算，才判为预算 | S6 |
| 7 | 改 `timeout_seconds` 后对在途任务 `resume` | `POLICY_CHANGED`，提示 `rebind` | S5 / B3 |
| 8 | 超时后 `status --refresh` | 工作区未隔离、未提交改动仍在；`resume` 复用同一 worktree | S5-C |

### 5.2 新增 6 组（评审建议）

| # | 反例 | 通过标准 | 覆盖 |
|---|---|---|---|
| 9 | 两个编排会话同时检查同一源码路径 | 静态预检**不得**被文档或输出宣称为原子互斥；`OVERLAP_WARNING` 分类出现且带合并风险提示 | S3 / §1.11 |
| 10 | `resume apply` 提交成功但响应丢失 | 用同一请求文件重放返回同一结果（幂等），**不产生第二次 run** | S2 |
| 11 | `preview` 之后任务状态变化 | `apply` 返回 `STATE_CONFLICT`，不得静默改用新版本 | S2 |
| 12 | `attest preview` 之后配置或 profile 集合变化 | `confirm` 失败且**未写入**；`--confirm-profiles` 扩张被拒 | S7 |
| 13 | monitor 预算到期但任务仍在跑 | 明确 `BUDGET_EXHAUSTED`；退出码与 `ALL_TERMINAL` 可区分（至少通过 `[stop] reason` / `--stop-file`） | S4 |
| 14 | `RUN_TIMEOUT` 后恢复工作区 | 未提交改动保留、校验执行归属、`attempts` 恰好 +1、不绕过准入（`PROCESS_UNKNOWN`/`POLICY_CHANGED` 各自报错） | S5 / §1.10 |

### 5.3 集成级验收（最关键的一条）

> 三个 Worker 在独立 worktree 中并行完成三个 CLI 子命令（其中一个中途 `RUN_TIMEOUT` 后 resume），
> 经**串行接线**、集成验证与最终验收后：三个命令都能正常运行；
> 且每个候选的变更来源、验证结果、接收记录可与 `task report` / 事件流**对账一致**。

这一条同时覆盖 S1（接线模式）、S3（重叠预检）、S4（监控与结束原因）、S5（超时恢复），以及控制器提交边界。**没有它，即使所有脚本测试通过，也不足以证明"并行批次派发问题已解决"。**

### 5.4 门禁

| 门禁 | 断言 |
|---|---|
| `zoe-runtime/tests/contract/test_skill_cli_contract.py` | `cli-contract.md` 的 ```text 块里每个命令/选项都真实存在。**脚本用法不要放进该 text 块**（首 token 是 `bash`，会被判成未知子命令）；写 `SKILL.md` / `runtime-contract.md` |
| `zoe-runtime/tests/test_contract_artifacts.py` | `build.py --check` 为空；两个新脚本进 `REQUIRED_FILES`；`docs/` 不进包 |
| `zoe-runtime/tests/test_doc_contracts.py` | `SKILL.md` 仍含 `max_active_tasks`、`verification_scope`、`NOT_RUN`、`dispatch_pending`；禁用短语不回归 |
| `zoe-workflows/build.py --check` / `--pack` | 打包含新脚本且可执行位正确（对照 `scripts/zoe.sh` 的断言方式） |
| `zoe-monitor.ps1` | 与 `.sh` 同参数、同 `[stop] reason` 词表、同退出码；Windows 独立用例（不靠 bash 推断） |

### 5.5 负向文案断言

1. 不出现「把 `<入口文件>` 排除出 `allowed_paths`，合并后手动接线」。
2. 不出现「三片只追加到末尾即可并行」。
3. 不出现「静态预检保证互斥 / 不会冲突」。
4. 不出现「`shared_resources` 会让共享同一资源的任务排队」。
5. 不出现「按预估时长/行数决定是否拆分」或「`timeout_seconds` 可按任务指定」。
6. 不出现「`--no-probe` 通过就证明是探测预算问题」。
7. 不出现「本环境必须显式传 `<profile 名>`」。
8. 不出现「`sleep N && task status` 与监控脚本等价」。
9. 不出现「`attest.sh` 一键完成确认」或「`--max-rounds` 用满 = 完成」。

---

## 6. 风险与边界

1. **S2 解决"手工"，不解决"竞态"**：`preview → apply` 之间版本仍可能前进，表现为 `STATE_CONFLICT` 并要求重跑 `preview`。把它写成"不会再冲突"是错的；`latest` 已被否决（§0.2 B1），所以这个窗口是**有意的**：让调用方看见并决定。
2. **S1 的两种模式都不是零成本**：都引入一次串行任务与一次额外检查；收益是"冲突可预期 + 集成点被验收"，不是"并行度不变"。
3. **S3 只降低风险**：静态预检与执行之间存在 TOCTOU；跨会话并发无法根治。真正需要强互斥的共享外部资源，本轮只能靠"人定的串行顺序"。
4. **S5 不改超时机制**：文档化 + 校验等于"让配置错得早、看得见"，不等于提供任务级旋钮。
5. **S6 的证据强度是分层的**：`detail` → `--no-probe` → 单独 doctor + 计时，三步各自只能证明各自的事；把第二步当结论是 v1 的错误。
6. **S7 的边界**：`--expect-*` + 预览校验保证"预览的与被写入的是同一份、且未扩张"，不证明"用户读懂了那份表"，也不防同机写权限的伪造。
7. **S4 与 S8 必须一次改完**：同一份 monitor 脚本同时承载 stop_reason、预算、phase、`--with-log`；分两次改会让脚本处于半新半旧状态（尤其 `.ps1` 容易漏）。
8. **不新增 Zoe 子命令**：全部动作复用 `task prepare|create|start|resume|status|report|list`、`route plan`、`project attest|context`、`orchestration resume`、`scripts/zoe-monitor.*`。

---

## 7. 附：关键锚点（`zoe-runtime@1.5.1`，2026-11-04 快照）

```text
src/_backend.py:scope()                    越界 → SCOPE_VIOLATION（violations/missing_paths/scope_source）
src/_backend.py:execute()                  deadline = self.c.get("timeout_seconds", 3600) → RUN_TIMEOUT
src/_pipeline.py:_resolve_task_scope()     spec 范围只能收紧；落 task["task_scope"]
src/_pipeline.py:start()                   authorize → POLICY_CHANGED → attest → expected_version → state 闸门
src/_pipeline.py:start()                   update(attempts=+1) 在 spawn 之前（resume 也消耗）
src/_pipeline.py (verify)                  git add --all + commit 仅在 checks 通过后
src/_worktree.py:quarantine()              仅闸门失败时隔离；RUN_TIMEOUT 不隔离
src/_prepare.py:prepare()                  只读；diagnostics / profile.conflicts / allowed_paths.warnings
src/_config.py:path_warnings()             项目级路径声明告警（非跨任务）
src/_config.py:validate_config()           无 timeout_seconds 校验（B3 目标）
src/_config.py:doctor()                    ready = 六项合取；返回 checks（B3 可回显 timeout 生效值）
src/_routing.py:collect_snapshot()         time_budget=5.0 固定；超预算 → ENVIRONMENT_ERROR
src/_routing.py:decide()                   显式指定收窄为 1 候选且不回落
src/_discovery.py                          _PATH_CACHE/_VERSION_CACHE 键含 env_names（推断，未实测）
src/_profiles.py:normalize_config()        shared_resources 仅校验+规范化（注释声称串行化，未实现）
src/_profiles.py:policy_digest()           digest(normalize_config(c)) → 含 timeout_seconds
src/_store.py:_operation_key()             digest([action, task, request]) → 同 id 改载荷 = REQUEST_CONFLICT
src/_context.py:_allowed_next()            BLOCKED(非 INPUT_REQUIRED) 不给 task resume（B4）
src/_orchestration.py:resume()             dispatchable[].action = task resume / task answer
src/cli.py:_project_attest()               --expect-policy-hash / --expect-profiles，锁内比对
zoe-workflows/scripts/zoe-monitor.sh       退出码 0(终态|max-rounds)/2/10/11；无 --json/--max-seconds；只观察
zoe-workflows/scripts/zoe-monitor.ps1      需与 .sh 同步（参数/词表/退出码）
zoe-workflows/references/decomposition-patterns.md   仅覆盖运行期副作用，未覆盖共享源文件
zoe-workflows/references/worker-prompt.md            "不提交、不推送、不创建 PR"
zoe-workflows/build.py:WHITELIST/REQUIRED_FILES      新脚本须进 REQUIRED_FILES；docs/ 不打包
zoe-runtime/tests/contract/test_skill_cli_contract.py cli-contract 的 text 块只允许真实 zoe 命令
```
