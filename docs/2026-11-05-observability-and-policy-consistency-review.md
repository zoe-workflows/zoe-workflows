# 可观测性与跨任务一致性：评审裁定与修复方案

| 项 | 内容 |
|---|---|
| 日期 | 2026-11-05 |
| 输入 | 外部评审《总体判断 + P1～P4 + 8 条优化建议 + 监控协议》（下称"评审"） |
| 被评估对象 | `zoe-workflows`（SKILL.md / references / scripts）；`zoe-runtime@1.5.3`（`_profiles` / `_pipeline` / `_prepare` / `_logstream` / `cli`） |
| 方法 | 每条主张回到源码或文档取证；能定位到行的写锚点，不能复现的标 `NOT_REPRODUCED` |
| 结论 | 4 条问题里 **2 条全采纳、1 条部分采纳、1 条不采纳（附重启条件）**；8 条建议采纳 4、改造 1、不采纳 3 |
| 本文位置 | `zoe-workflows/docs/`（不在 `build.py` 的 `WHITELIST` 内，不进入发布包） |

## 0. 一句话

评审的**问题观察基本准确**，但**归因有 5 处偏差**，其中 3 处会导致"改了但没用"：把已在 2026-11-04 落地的能力当成缺口、把已存在的批量通道当成缺失、把 `spec` 未知键当成可用字段。本方案只做**能被验证有用**的改动。

## 1. 判定摘要

| 编号 | 评审主张 | 裁定 | 关键依据 |
|---|---|---|---|
| P1 | 子进程内容不可视 | **成立**（作为汇报契约缺失） | `zoe-monitor.sh:55,57` 默认关且 ≤3 行；SKILL 检查点只有状态字段 |
| P2 | 调度参数污染策略摘要 | **机制成立，但属已接受的设计代价** | `_profiles.py:148-159` 全量摘要；`_pipeline.py:3082-3086` accept 复用它；两份既有文档已记录并接受该代价 |
| P3 | 文件级边界与既有用例冲突 | **成立** | `_backend.py:656-679` 事后判定；`spec-template.md:89-98` 明令不得新增顶层键 |
| P4 | 并行热区无统计 | **部分成立**（归因错误） | `prepare` 不构造 Store，看不到在途任务（`2026-11-04-batch-parallel-dispatch-friction.md` §1.5）；三类分类是宿主侧协议，不是 `prepare` 输出 |
| #1 | 新增 `zoe-digest.sh` | **采纳** | 重复劳动可量化：N 任务 = 1+2N 次调用 |
| #2 | 拆开"证据"与"汇报" | **采纳** | `report-template.md:62-64` 只禁"当证据"，未规定"必须进汇报" |
| #3 | 拆分 `policy_hash` | **本批不采纳**（见 §4.2） | 已有两处决策记录接受该代价；拆分需迁移 attestation/证据/组快照 |
| #4 | cli-contract 补三张表 | **部分采纳** | 通用变更模板已在 `cli-contract.md:268-273`；动作表未重复五要素 |
| #5 | spec 模板增三字段 | **改造采纳** | 未知顶层键无消费者（`spec-template.md:89-91`）；只做 Markdown 影响面 + 模板红线 |
| #6 | runtime 内置 `task digest` | **本批不采纳**（见 §4.3） | `2026-11-04-subprocess-progress-text-visibility.md` §3 已明确拒绝"投影层做归纳" |
| #7 | `prepare` 输出路径热区 | **不采纳**（架构位置错误） | `prepare` 只读、无 Store；热区需要"在途任务集合"，属于编排视图 |
| #8 | 阶段耗时 P90 告警 | **不采纳**（无基线） | 无历史数据；先展示耗时，不做统计模型 |

## 2. 事实核对（5 处需要修正的归因）

### 2.1 P1 的三处事实修正

| 评审表述 | 事实 | 影响 |
|---|---|---|
| "`--with-log` 默认关，开了也只给 ≤3 行" | 成立：`WITH_LOG=0`、`LOG_LINES=3`（`scripts/zoe-monitor.sh:55,57`） | 保留；**不改默认**（默认关是为了不刷屏，改默认会让 `[tick]` 被淹没） |
| "SKILL 检查点只规定 `[tick]` 一行，字段是 `next_cursor + state/phase + 新事件数`" | 不准确：`[tick]` 还带 `alive`/`need_human`/`human`/`phases`/`runs`（脚本 399 行；S8-B1 已落地） | 缺口在**汇报契约**，不在 tick 字段 |
| "report-template 用'过程观察不是证据'一刀切" | 不成立：`report-template.md:62-64` 只禁止把 `[log]` 写成 PASS，**没有**禁止进汇报 | 改为"补正面规定"，不是"撤销禁令" |
| "单次最多 1 MB JSON" | 默认 64 KiB，1 MiB 是上限（`_logstream.py:42-43`） | 成本估算按 64 KiB 算 |

补充一条评审未提的：`task list` 返回的是**完整任务记录**（含冻结 `config` 副本，`cli.py:2123-2124`），40 个任务时会明显臃肿。digest 脚本必须用 `jq` 投影，不能整包透传。

### 2.2 P2：机制成立，但这是**有记录的取舍**

```148:159:zoe-runtime/src/_profiles.py
def policy_digest(c: dict) -> str:
    """Digest of a *normalized* policy.
    ...
    """
    copy = json.loads(json.dumps(c))
    try:
        return digest(normalize_config(copy))
    except Error:
        return digest(c)
```

`normalize_config` 不剔除调度字段，所以 `max_active_tasks` / `timeout_seconds` / `max_attempts` 都进摘要。`accept` 用它复校（`_pipeline.py:3082-3086`），于是"改并发"会让已 `REVIEW_READY` 的任务 `POLICY_CHANGED` —— 评审描述的现象**成立**。

但两处既有决策已经明确记录并接受这个代价：

- `2026-11-04-batch-parallel-dispatch-friction.md` §1.9/§4.1：`timeout_seconds` "属于项目配置，改动会改变 `policy_digest`：在途任务随后 `start/resume` 会撞 `POLICY_CHANGED`，需 `rebind`"，结论是"更便宜的做法是把任务切到能在默认上限内到达可验收点"；
- `2026-11-05-dispatch-retry-and-candidate-verification.md` §8.4：改 `checks` 同样 `policy_hash` 变化，处置是 `register → attest → rebind`，且"这属于用户改变项目政策，要人来批"。

`_progress.py:11-19` 的注释更直接说明了这个取舍：提示阈值**故意**走宿主环境变量而不进项目配置，原因就是"putting a hint threshold there would raise `POLICY_CHANGED` on in-flight tasks"。也就是说"什么该进摘要"是有意识的边界选择，不是疏忽。

评审另外两处判断也需要修正：

| 评审表述 | 事实 |
|---|---|
| "rebind 无 `--all`，40 任务场景 O(n) 手工，缺'批量预览 + 逐条应用'的安全通道" | 通道已存在：`project diff` 输出 `policy_hash` / `changed_fields` / `affected_tasks[]` / `suggested_commands[]`，且明说"逐条替身命令，不批量执行"（`cli-contract.md:187-199`）。缺的是**把 `project diff` 写进流程**，不是缺工具 |
| "`rebind` 的 `reason` 必填但 cli-contract 载荷表未列；`accept` 的 `authorization_ref` 同上" | 通用变更请求模板已列 `schema_version`/`request_id`/`expected_version`/`reason`/`authorization_ref`（`cli-contract.md:266-273`）；缺的是动作表（284-285 行）没有回指这句，读者容易只读动作表 |

但**"必填"本身成立**：

```385:395:zoe-runtime/src/_contracts.py
def require_change_request(req: dict, extra: tuple[str, ...] = ()) -> None:
    """Common shape for v2 mutation requests (reassign / rebind / revise)."""
    ...
    if req.get("schema_version") == 2:
        for key in ("expected_version", "authorization_ref", "reason") + extra:
            require(key in req, "INPUT_INCOMPLETE", "Request requires " + key)
```

`accept` 的逐字比对也成立（`_config.py:1146-1150`，`AUTH_REQUIRED: Authorization reference mismatch`）。

### 2.3 P3：成立，但"加字段"是装饰

`SCOPE_VIOLATION` 是**事后**判定（`_backend.py:656-679`），`allowed_paths` 只能收紧；`prepare` 也不做"公开符号 → 既有用例引用"的反查。所以"改签名必然撞边界"成立。

不成立的是修法：`spec-template.md:89-98` 已明确"**不要新增顶层键**——旧版本不拒绝未知键，但冻结后不会有人按它执行"。在当前 runtime 下加 `affected_existing_tests[]` / `coupled_paths[]`，结果是**被忽略**，不会产生任何诊断。

另外 `merge_order` 放错了层：合并顺序属于组计划（`group-plan-schema.md` 的 `depends_on` / `order`）或本批计划，不是单个 spec 的字段。

### 2.4 P4：分类归错了对象

`prepare` **不做**重叠预检，这是设计而非遗漏（`2026-11-04-batch-parallel-dispatch-friction.md` §1.5："`prepare` 不构造 `Store`，看不到在途任务"）。`OVERLAP_WARNING / INTEGRATION_REQUIRED / EXCLUSIVE_RESOURCE` 是 **SKILL 第 4 步给宿主的分类协议**，不是 `prepare` 的输出。所以"`prepare` 只判三类、不给热区"这个句子把两个层混成了一个。

成立的只有两点：

1. 确实没有"本批 N 个候选共享同一路径"的计数与排序；
2. `base_sha` 在 `create` 时冻结，`start` 前没有"基线是否已经前移"的检查，只能靠人守纪律（本次已踩过一次）。

## 3. 采纳清单

### 3.1 第一批（skill 内可独立完成，不依赖 runtime 升级）

| # | 改动 | 落点 | 为什么值得 |
|---|---|---|---|
| A1 | 新增 `scripts/zoe-digest.sh`：一命令输出每任务两行（状态/阶段/耗时/静默/日志字节 + 最近一条文本 + 最近一个工具） | `scripts/`、`build.py` 的 `REQUIRED_FILES`、`SKILL.md` 第 6 步 | 把 1+2N 次调用压成 1 次进程，让"报内容"从高成本变零成本 |
| A2 | SKILL 拆开"证据纪律"与"汇报纪律"，规定三档汇报 | `SKILL.md` 第 6 步 + 「每次输出」 | 直接消除本次"只报状态不报内容" |
| A3 | `cli-contract.md` 动作表补一行回指 + `POLICY_CHANGED` 标准处置链 | `references/cli-contract.md` | 少两次盲试错；不改 runtime 行为 |
| A4 | `spec-template.md` 增「影响面（既有用例与调用方）」章节 + 一条通用红线 | `references/spec-template.md` | P0-1 那类卡死提前暴露；零 runtime 改动 |
| A5 | SKILL 第 4 步增"共享路径热区"提示（数据来自 digest，不新增判断） | `SKILL.md` 第 4 步 | 降低 3-way 冲突；不改 `prepare` |
| A6 | SKILL 增"改项目配置前必须 `project diff`"纪律 | `SKILL.md` §执行配置与模型授权 | 把 O(n) rebind 从"事故"变成"知情操作" |
| A7 | 监控的 `[tick]` 追加"本批静默最长目标"（不改退出码、不改判定） | `scripts/zoe-monitor.sh` / `.ps1` | 让人一眼看到"谁没在动"，而不是逐条读 |

### 3.2 第二批（需 runtime 配合，单独发版）

| # | 改动 | 前置 | 说明 |
|---|---|---|---|
| B1 | `task list --fields a,b,…`（投影输出） | 无契约破坏，纯增量 | 40 任务时把 `config` 冻结副本排除掉 |
| B2 | `task digest --project P --json`（事实聚合，不做归纳） | 必须重新确认与 §3 拒绝"投影层归纳"的边界 | 定义成"多任务的 status+logs 事实合并"，**不产生结论句**、不进 `task report` |
| B3 | `start` 前校验 `base_sha` 是否仍可达：不可达则 `BASE_DRIFT`，不要等 run 结束才 `VALIDATION_FAILED` | 新增错误码，需登记 `_EXIT_CODES` | 只加"提前失败"，不改基线冻结语义 |

B1/B2/B3 都要同步 `runtime-requirements.json`（`min_version` + `required_capabilities`），因为包装器的 `--check-requirements` 是硬门禁。

## 4. 不采纳与重启条件

### 4.1 #5 的结构化新字段

不采纳 `affected_existing_tests[]` / `coupled_paths[]` / `merge_order` 三个**结构化**字段，改为 Markdown 章节 + 模板红线。理由：无消费者即装饰（`spec-template.md:89-91`），且 `merge_order` 属于组计划层。

**重启条件**：`prepare` 需要据此产出新诊断码（例如 `SCOPE_COUPLED_TESTS`）时，字段与消费者同批落地，才算数。

### 4.2 #3 拆分 `policy_hash`

**本批不采纳**，理由三条：

1. 这是**已记录的取舍**，不是遗漏（§2.2 引了三处）；
2. 拆成 `execution_policy_hash` / `scheduling_policy_hash` 会同时改动 `attestation` 记录、任务冻结 `config`、`group.runtime.policy_snapshot`、`project diff` 与 `rebind` 语义，属于契约级变更，不是"改一个函数"；
3. 语义上并不干净：并发上限变化会影响"同批次的 `allowed_paths` 重叠预检结论"（`max_active_tasks` 从 6 降到 1 之后，原本并行的批次变成串行，重叠风险定性会变）。把它判成"纯调度、与证据无关"需要额外论证。

**重启条件（任一满足）**：① 连续两个迭代里出现"仅为调并发/超时而 rebind 已验收任务"≥3 次；② 出现"调度变更后旧证据是否仍有效"的实际争议；③ 需要在不打断 REVIEW_READY 的前提下热调并发。

届时的最小收窄方案（不是全量拆分）：只对 `accept` 使用"执行相关子集"摘要，`start`/`resume`/`group` 仍用全量，避免一次改四个判定点。

### 4.3 #6 runtime 内置 digest

**本批不采纳**。`2026-11-04-subprocess-progress-text-visibility.md` §3 明确拒绝两件相关的事：

- "文本进 `progress.json` / `task status` / 事件表"；
- "为快照再加一个'摘要/结论'字段 —— 语义归纳不是投影层的职责；要结论就 `task summary submit` 或派只读任务"。

A1 的脚本正好落在"派只读任务"这条被允许的路径上。**重启条件**：A1 在 40+ 任务或 1 MiB 日志下被证明超时/解析失败；届时的 B2 必须保持"只聚合事实、不产结论"。

另按 `2026-10-30-usage-evaluation-and-optimization.md` §7-4「不要在 skill 侧新增 preflight.py 复制 runtime 的判断」，A1 **不得**自己判断"是否卡住/是否成功"，只做展示。

### 4.4 #8 阶段耗时 P90 告警

不采纳。当前没有历史耗时分布，P90 只能是编出来的数字。A1 先输出 `phase` + 已运行时长，等 `.zoe/<project>-events.jsonl` 攒够样本再谈基线。

## 5. 详细改动规格

### A1 `scripts/zoe-digest.sh`

```text
zoe-digest.sh --project P [--targets "T1 T2" | --targets-file F]
              [--out .zoe/P-digest.md] [--tail-bytes 131072] [--lines 2]
              [--no-content] [--json]
```

- 数据源只有两处：`task status T --refresh --json`（权威状态 + `progress`）与 `task logs T --json --tail-bytes N`（内容）；`task list --project P --json` 仅用于解析目标集合。**不读 SQLite、不读 `progress.json` 文件、不推进任何状态。**
- 每任务产出 1 行状态（`state · phase · 已运行 · 静默 · 字节`）+ 至多 `--lines` 条内容：
  `text` 与 `tool` 合并后按时间取最后 N 条，**先按内容去重**（同一条工具调用连续出现
  会制造"一直在动"的假象）。
- `--no-content` 只跑 status，用于任务数 > 20 或本机 CLI 慢时的降级；此时表格里内容列写 `skipped (--no-content)`，**不得**写"无输出"。
- 退出码：`0` 生成成功；`2` 用法/依赖错误（缺 `jq`、缺 `--project`、`--tail-bytes` 越界）；`11` 全部 `task status` 都读失败（与 monitor 的 `WATCH_ERROR` 同族）。
- `rotated=true` 或 `empty_reason=no_new_records` 时内容列写 `（无新增）`；`empty_reason=rotated` 写 `（日志已轮转）`；不得把空内容当成"卡住"。
- 输出 Markdown 表 + 末尾一行 `<!-- digest generated at <ts> cursor=<n> -->`（给人工比对用，不作为事实源）。

**版式**：

```text
P1-3 时间契约与 MarketView   RUNNING · implement · 26m · 静默 37s · 608KB
     说：两个解释器都通过，正在抽查 Clock.stamp() 的墙钟分支。
     动：Bash pytest / Read clock.py:120-160
```

**硬约束（写进脚本注释）**：

1. 不参与终态判定：`alive` / 完成与否只由 `task status` 回答，digest 不产出"完成/失败"字样；
2. 失败隔离：单个任务读不到只记 `[warn]`，不影响其他任务，也不改退出码（聚合后才判 11）；
3. 不上传、不落状态库；`--out` 只写调用方指定路径，默认写 `.zoe/<project>-digest.md`；
4. 不复制 runtime 判断：`SCOPE_VIOLATION` / `REVIEW_READY` / `empty_candidate` 原样转述字段，不重新解释。

### A2 SKILL 三档汇报

在 `SKILL.md` 第 6 步「检查点节奏」后插入：

```text
汇报分三档，缺任何一档都不算"在监控"：
- 启动拍（派发后第一次汇报）：派了什么、为什么这样切、本批共享路径有哪些；
- 进度拍（每 8–10 分钟或任一任务状态/阶段变化）：一版 digest，含每任务最近一条文本与最近一个动作；
- 终态拍：AC 表 + 合并门禁 + 未验证项。

过程观察进入汇报，但**不得**写成验收结论：`动：Edit src/config.py` 是"动过这个文件"，
不是"写成功"，更不能替代 check 结果。这两句话同时成立，不要用一句盖住另一句。
```

同时把「每次输出」一节从"六项状态字段"扩为"六项 + 本批内容行"，明确 `task logs`/digest 的输出属于**必报项**。

### A3 cli-contract 补两处

1. 在动作表（279-287 行）上方加一句：
   `下表只是动作专属字段；所有 v2 变更请求都还必须带 schema_version / request_id / expected_version / authorization_ref / reason（见上「请求模板」），缺任一即 INPUT_INCOMPLETE。`
2. 在 `POLICY_CHANGED` 行（693 行）补标准处置链：
   `先 project diff 看影响面（是否只改了调度字段）→ 逐任务 rebind(target_policy_hash=<new_policy_hash>) → 需要时 resume 重签证据 → 再 accept；不得跳步直接 create 新任务。`

### A4 spec 模板影响面章节

在 `## 文件边界` 之后插入：

```text
## 影响面（既有用例与调用方）
本次改动是否触及公开契约（导出符号、接口签名、CLI 参数、schema 字段）？
若触及，逐条列出必须同步修改的既有测试/调用方文件，并说明"只做参数对齐，不得删减断言"：

- 契约变化：`FetchRequest.q` 由可选改为必填
- 必须同步：`tests/test_w02_data.py`（仅参数对齐，断言数量不变）
- 未纳入 `allowed_paths` 的后果：该 run 会以 `SCOPE_VIOLATION` 收场，改动留在 worktree 但不成为 candidate
```

并在「文件边界」的并行段落补一条红线：**改公开签名时，同步修改的既有用例文件必须同时进 `allowed_paths`**，否则应在派发前拆成"先契约、后实现"两个任务。

### A5 热区提示

第 4 步「并行重叠预检」后补：

```text
本批共享路径要**计数**再决定，而不是只看"有没有重叠"：
- 用 digest 的 `--json` 输出统计每个路径被几个候选的 `task_scope` 覆盖；
- 同一路径被 ≥3 个候选触及 ⇒ 按共享集成点处理（前置 scaffold 或末尾接线），不要靠合并顺序；
- 计数是静态快照（TOCTOU 依然存在），不提供互斥。
```

注意与 `2026-10-30-usage-evaluation-and-optimization.md` §7-2 一致：只提示、不阻断、不要求重切。

### A6 配置变更纪律

在「执行配置与模型授权」末尾补：

```text
改任何项目配置（尤其 max_active_tasks / timeout_seconds / max_attempts / checks）之前，
先跑 `zoe project diff --config <new> --json`，把 affected_tasks[] 与 suggested_commands[]
原样列给用户：这属于"用户改变项目政策"，需要人批，且已 REVIEW_READY 的任务会失效。
不要用"调个并发而已"概括。
```

### A7 `[tick]` 追加静默最长目标

`[tick]` 行末尾追加 `quiet=<task>:<秒>`（取本批 `quiet_seconds` 最大的仍在跑目标；无目标时 `quiet=none`）。**不改变任何退出条件**，与 S8-B1 的 `phases=`/`runs=` 同风格（逗号分隔、空值写 `none`）。

## 6. 顺序、版本、回滚

| 序 | 动作 | 版本影响 | 回滚 |
|---|---|---|---|
| 1 | A3 + A4 + A5 + A6（纯文档） | 无 | 直接回退文本 |
| 2 | A1（新脚本）+ `build.py` 登记 + 可执行位 | 无（不调 `min_version`） | 删脚本与三处引用 |
| 3 | A2（SKILL 汇报契约） | 无 | 回退该节 |
| 4 | A7（monitor 两脚本同批） | 无（`[tick]` 是展示行） | 回退追加字段 |
| 5 | B1/B2/B3（runtime） | 抬 `min_version` + 登记 capability | 按版本回退；旧 skill 仍可运行 |

`build.py --check` 会校验 `REQUIRED_FILES`、可执行位与 `docs/` 不进包，A1 必须同时改这三处。

## 7. 验收（可判错）

| # | 断言 | 判法 |
|---|---|---|
| 1 | digest 在 3 个任务上只起 **1** 次 shell 进程 | `--out` 与 stdout 一致；`strace`/计时不作为判据，改为断言脚本内 CLI 调用次数 ≤ 1+2N（脚本 `--debug-calls` 输出计数） |
| 2 | digest **不产出**终态结论 | 输出中不含 `已完成` / `失败` / `PASS` 字样；`REVIEW_READY` 原样出现 |
| 3 | `--no-content` 时内容列不写"无输出" | 断言出现 `skipped (--no-content)` |
| 4 | 单任务 `status` 失败不影响其他任务 | 用假 `ZOE_BIN` 令 T2 返回非 0，断言 T1/T3 仍有行、退出码 0 |
| 5 | 全部 `status` 失败 ⇒ 退出码 11 | 同上，全部失败 |
| 6 | SKILL 三档汇报可被判违规 | 文档负向断言：不出现"要不要我继续盯着"；不出现把 `[log]` 写成 PASS 的表述 |
| 7 | cli-contract 动作表回指存在 | `grep -c "所有 v2 变更请求"` ≥ 1；`POLICY_CHANGED` 行含 `project diff` 与 `rebind` |
| 8 | spec 模板影响面章节存在且与 `allowed_paths` 不矛盾 | 章节标题存在；正文含"不得删减断言"与 `SCOPE_VIOLATION` 后果 |
| 9 | `[tick]` 新增字段不改变退出码 | `--max-rounds 1` 时对同一夹具仍得 0/2/10/11 中的预期值 |
| 10 | 既有门禁不回归 | `zoe-workflows/build.py --check`、`zoe-runtime/tests/contract/test_skill_cli_contract.py`、`test_doc_contracts.py` 全绿 |

## 8. 风险

1. **digest 成本仍是 O(N)**：它把"N 次人工调用"压成"1 次进程 + 2N 次内部 CLI"，不是 O(1)。40 任务时先用 `--no-content`，不要声称"恒为一个查询"。
2. **内容行会被误读成验收结论**：A2 的措辞必须与 `report-template.md:62-64` 同时出现，任何一处松口都会让 `[log]` 变成"通过"的依据。
3. **A5 热区计数是 TOCTOU**：两个编排会话同时统计会得出相同结论，不提供互斥（沿用既有结论）。
4. **A7 是展示行**：`quiet` 变大不等于卡住，`phase` 不变也不等于卡住；两句话都要在文档里。
5. **B3 会新增错误码**：`BASE_DRIFT` 需要进 `_EXIT_CODES` 与 `cli-contract.md` 的恢复动作表，否则宿主只能靠字符串猜。

## 9. 附：关键锚点（2026-11-05 快照）

```text
zoe-runtime/src/_profiles.py:148-159        policy_digest = digest(normalize_config(c))（全量）
zoe-runtime/src/_pipeline.py:3082-3086      accept 用 policy_digest 复校 → POLICY_CHANGED
zoe-runtime/src/_pipeline.py:2133-2155      rebind：target_policy_hash 必须等于当前策略
zoe-runtime/src/_contracts.py:385-395       v2 变更请求五要素（reason/authorization_ref 必填）
zoe-runtime/src/_config.py:1143-1150        authorize：authorization_ref 逐字比对
zoe-runtime/src/_backend.py:656-679         SCOPE_VIOLATION（事后 diff，allowed_paths 只能收紧）
zoe-runtime/src/_prepare.py:38-49           BLOCKING 含 CHECK_ESCAPES_WORKSPACE
zoe-runtime/src/_prepare.py:116-125         SCOPE_DIRECTORY_LEVEL（仅告警）
zoe-runtime/src/_logstream.py:42-53         DEFAULT_TAIL_BYTES=65536 / MAX=1MiB / 投影目标字段
zoe-runtime/src/cli.py:2123-2124            task list 返回完整任务记录
zoe-runtime/src/cli.py:2333-2342            task status 的 progress 行（bytes/quiet/process_state）
zoe-workflows/scripts/zoe-monitor.sh:55,57  WITH_LOG=0 / LOG_LINES=3
zoe-workflows/SKILL.md:612-648              动作线（已有能力，缺汇报义务）
zoe-workflows/references/cli-contract.md:187-199  project diff（影响面 + suggested_commands）
zoe-workflows/references/cli-contract.md:266-273  v2 变更请求通用模板
zoe-workflows/references/spec-template.md:89-98   不得新增顶层键（未知键不生效）
zoe-workflows/references/report-template.md:62-64 过程观察不是证据（未禁止进汇报）
zoe-workflows/docs/2026-11-04-subprocess-progress-text-visibility.md §3  明确不做"投影层归纳"
```

## 10. 实施记录（2026-11-05，第一批）

### 10.1 逐项状态

| 项 | 状态 | 落点 |
|---|---|---|
| A1 `zoe-digest.sh` | **完成** | 新增 `scripts/zoe-digest.sh`；`build.py` 的 `REQUIRED_FILES` 与可执行位检查同步；`SKILL.md` 第 6 步新增"要一版摘要用 digest"段 |
| A2 SKILL 三档汇报 | **完成** | `SKILL.md` 第 6 步「检查点节奏」后新增三档表 + "过程观察进汇报、不进结论"；「每次输出」新增「本批内容行」并补两段边界 |
| A3 cli-contract 两处 | **完成** | 动作表前新增"五要素 + authorization_ref 逐字相等对 accept 同样成立"；`POLICY_CHANGED` 行改为 `project diff → rebind → resume → accept` 处置链 |
| A4 spec 模板影响面 | **完成** | `spec-template.md` 新增「## 影响面（既有用例与调用方）」；「文件边界」补"改公开契约时同步用例必须进 `allowed_paths`" |
| A5 热区计数 | **完成** | `SKILL.md` 第 4 步新增共享路径计数（1 / 2 / ≥3 三档处置）+ TOCTOU 与"不要求重切"的边界 |
| A6 配置变更纪律 | **完成** | `SKILL.md`「执行配置与模型授权」末尾新增 `project diff` 前置 + "用户改变项目政策要人批" |
| A7 `[tick]` 静默列 | **完成（POSIX）** | `zoe-monitor.sh` / `.ps1` 同语义追加 `quiet=<task>:<秒>`；`status` 的 jq 表达式从 7 字段扩为 8 字段（`\037` 分隔不变） |
| B1 `task list --fields` | **完成** | `cli.py`（parser + `_project_task_rows`）；未知字段报 `INPUT_INCOMPLETE` |
| B2 `task digest` | **完成** | 新增 `src/_digest.py`；`cli.py` parser/dispatch；`capabilities().observation`；`SUPPORTED_CAPABILITIES` |
| B3 `BASE_DRIFT` | **完成** | `_worktree.base_reachable` + `_pipeline._start_locked` 首次派发前校验；`_EXIT_CODES` / `_routing` / 契约测试同步 |
| 版本与门禁 | **完成** | runtime `1.5.3 → 1.6.0`；`runtime-requirements.json` `min_version 1.6.0` + 3 个新能力名；README 同步 |

### 10.2 实现中定下的三处细节（与 §5 的措辞差异）

1. **`--lines` 的语义**：§5 写的是"说/动 各取最新 1 条"，实现改为"`text` 与 `tool` 合并后
   按时间取最后 N 条，**先按内容去重**"。理由：实测同一任务连续出现两条相同的
   `TaskUpdate`，逐类各取一条会输出两行完全一样的"动"，制造"一直在动"的假象——这正是
   `--with-log` 当年踩过的坑。文档已同步为合并语义。
2. **标题截断按 codepoint**：`jq '.[0:40]'`，不用 shell 的 `${var:0:40}`。中文标题按字节切
   会产生半个字符。
3. **`quiet_seconds` 缺失写 `-` 而不是 `0`**：`progress` 整块缺失（没有 run）或
   `last_output_at` 为空时，`quiet` 是 `null`。"读不到"与"很安静"必须能分开，所以展示为
   `静默 -`，监控的 `quiet=` 也只在本轮真的读到数字时才报告（`quiet=none` 表示"没有可报的"）。

### 10.3 验收执行结果

| # | 断言 | 结果 |
|---|---|---|
| 1 | CLI 调用次数 = 1 + 2N（带 `--targets` 时 = 2N） | 2 任务 → 4 次；4 任务 → 8 次；`--no-content` 1 任务 → 1 次（`--debug-calls` 实测） |
| 2 | 不产出终态结论 | 输出只有 `state`/`phase`/内容行；`REVIEW_READY` 原样 |
| 3 | `--no-content` 写 `skipped (--no-content)` | 通过 |
| 4 | 单任务失败不影响其他 | 未单独构造；代码路径为 `continue` + `STATUS_OK/FAIL` 计数 |
| 5 | 全部失败 ⇒ 11 | 假 `ZOE_BIN` 实测 `exit=11` |
| 6 | 参数越界 ⇒ 2 | `--tail-bytes 0` 实测 `exit=2` |
| 7 | 既有门禁不回归 | `build.py --check` 通过；`test_doc_contracts.py` + `contract/test_skill_cli_contract.py` **20 passed** |
| 8 | 热区统计正确 | 真实项目（`factorX`）4 任务实测识别 `serve.sh`、`src/investment_os/entry/cli.py` 各 2 个候选 |
| 9 | `[tick]` 新增列不改退出码 | 实测输出 `quiet=task-47170b14b07f4bf9:123`，退出码仍 `0` + `[stop] reason=BUDGET_EXHAUSTED` |
| 10 | 原生 digest 只花 1 次调用 | `ZOE_BIN` 指向 1.6.0 源码时 `--debug-calls` 输出 `[calls] 1`，与回退路径的 `5`（2 任务）区分开 |
| 11 | 两条路径输出同构 | 同一批 2 个任务，原生与回退的状态行/内容行字段一致（`state · phase · 时长 · 静默 · 字节`） |
| 12 | `--fields` 拼错即报错 | `--fields task_id,stte` → `INPUT_INCOMPLETE`，`details.unknown=["stte"]`、`details.available` 含真实字段 |
| 13 | `BASE_DRIFT` 三态 | `tests/test_v160_digest.py`：祖先 → `True`、孤儿提交 → `False`、缺失对象 → `False`、非仓库 → `None` |
| 14 | 跨项目目标被拒 | `task digest --project mine --targets T1`（T1 属于 other）→ `PROJECT_MISMATCH` |

### 10.4 未验证项（不得写成已验证）

| 项 | 原因 | 处理 |
|---|---|---|
| `.ps1` 与本机实机一致 | 本机无 `pwsh`（与 S8 门槛 9 同状况） | 只做了静态同构改写（相同参数、相同字段、相同行前缀）；Windows 独立用例未跑，记 `NOT_VERIFIED` |
| digest 在 40+ 任务时的耗时 | 只有 14 个非终态任务的样本 | 已知成本是 O(N) 次 CLI；超过 20 个目标先用 `--no-content` |
| `--out` 默认路径 `.zoe/<project>-digest.md` 在只读 cwd 下的行为 | 未构造只读目录 | 代码里 `mkdir -p` 失败只 `[warn]`，不影响 stdout 与退出码 |
| `BASE_DRIFT` 的**端到端**触发（真实 `task start` 命中它） | 需要在临时项目里造"已改写的目标分支 + 已存在任务"，成本高于它证明的东西 | 已用单元测试覆盖三态与判定分支；端到端仍记 `NOT_RUN`，不写成"已实测" |
| 本机 `zoe` 仍是 1.5.3（pipx 安装，非 editable） | 未执行 `pipx install -e` 重装 | 所有 1.6.0 行为通过 `PYTHONPATH=<repo> python3 -m src` 验证；**技能包的门禁会拒绝旧运行器**，这是预期行为 |

### 10.5 第二批（B1–B3）落地后的边界

1. **A1 与 B2 的关系已定**：`zoe-digest.sh` 优先调 `task digest`（1 次调用），旧运行器自动回退
   到逐任务读取。渲染留在技能侧，事实只来自 runtime——同一条信息不会有两个来源。
2. **B2 仍然不产结论**：`_digest.py` 的输出里没有 verdict 字段，`note` 明写
   "facts only … no output does not prove a hang"。这是 §4.3 的硬边界，不是措辞偏好。
3. **B3 只在首次派发时校验**：`resume` 不校验，因为它继续的是已冻结的 worktree；此时拦住
   它只会把正在推进的任务卡死，而合并不了的问题由 `project diff` 与人工处理。
4. **`BASE_DRIFT` 不阻断"判定不了"**：`git` 读不到 → `None` → 放行。它与 `PROCESS_UNKNOWN`
   的处置不同，因为后者是写者状态未知（安全边界），前者只是提前失败的优化。
5. **版本门禁是硬门，脚本回退不是它的替代**：`min_version` 抬到 `1.6.0` 后，经
   `scripts/zoe.sh` 调用时旧运行器会被整包拒绝（`RUNTIME_INCOMPATIBLE`，退出码 5）。脚本内的
   回退分支不是为"本技能包 + 旧运行器"准备的，而是给两种真实场景：直接调 `zoe`（绕过包装器，
   例如排障时用 `ZOE_BIN`）、以及脚本被单独拷到别处使用。两处降级不能互相顶替。

