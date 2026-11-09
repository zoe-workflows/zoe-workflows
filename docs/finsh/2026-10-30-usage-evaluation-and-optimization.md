# zoe-workflows / zoe-runtime 使用评估与优化方案（v2）

| 项 | 内容 |
|---|---|
| 评估日期 | 2026-10-30（v2 同日修订） |
| 被评对象 | `zoe-workflows`（skill 层：SKILL.md + references + 包装器）、`zoe-runtime`（运行器，v1.4.1） |
| 输入材料 | 《Zoe Workflows Skill 实战评估 v2（zoe-go 自举开发）》+ factorX Wave 0 复盘 + 对本文 v1 的独立评审意见 |
| 评估方法 | 逐条核对判断 → 对照 `zoe-runtime` 源码取证（文件:行号）→ 给出可落地项与**可判错的**验收口径 |
| 本文位置 | `zoe-workflows/docs/`（不在 `build.py` 的 `WHITELIST` 内，不进入发布包） |

## 修订记录

| 版本 | 变化 |
|---|---|
| v1 | 基于实战报告的首版方案（可观测性 P0 / 编排 P1 / 语义纠偏 P2） |
| **v2** | 采纳外部评审 12 项意见，**撤回 6 项**：①「独立 task 并行 → `group accept` 一次验收」不成立（非成员会被拒）；②`stalled_seconds` 改为 `quiet_seconds` 且不主张「无输出=卡死」；③日志 follow 的验收条件从「5–15 秒必有 tool」改为「有新增才输出」；④删除 skill 侧 `scripts/preflight.py`（规则应留在 runtime）；⑤不推荐默认 `bash -lc`，改为直接 argv + runtime 同环境解析；⑥「几千条事件必然让查询退化」「事件 ID 不连续破坏游标」两处未经验证的断言删除。另修正 `--json` 计数（原写 19 处，实为 5 处/全文 29 处）与 `--json` 的性质认定（兼容选项，非缺陷）。 |
| **v3** | 全部设计已落地：运行器 1.5.0（事件过滤 / 日志增量流 / 运行观测 / 检查预检 / CLI help）+ skill（两种交付模式、并行波次可选规程、观测与动作两线监控）。落地清单与取舍见 §12。 |

---

## 0. 结论先行

1. **方向保留：先补可观测性，再改善编排体验。** 本轮只做四件事：事件过滤、增量日志读取、运行观测、检查命令预检。其余（自动拆分、机器可读命令清单、并行与组验收打通）均后置。
2. **报告的 2 条前提是错的**：
   - 「`task logs` 不存在」→ 存在（`cli.py:654`），缺的是 `--follow` 与流式消费协议。
   - 「路径重叠应警告或拒绝」→ 运行期无写冲突（每任务独立 worktree + 每任务写者锁），重叠代价在**集成期**；且「有重叠就重切」与「不设硬闸」自相矛盾。
3. **v1 最严重的错误是「并行 → 一次组验收」不成闭环。** `group accept` 只认**组内成员**：绑定发生在 `task create` 时（必带 `group_id` + `item_id`），事后没有任何命令能把独立 task 变成成员；`integration_preconditions` 直接校验 `task["group_id"] == group["group_id"]`（`_integration.py:173-177`）。因此必须**显式分成两种交付模式**（§4-1），不得混写。
4. **进度不可见的根因是信息密度，不是监控姿势**：`implement` 是 6 阶段里最长的一个，但整段只有一个 `phase` 值和一次 `last_progress_at` 写入（`_pipeline.py:1372`、`_pipeline.py:2262`）。
5. **「存活」与「有输出」是两件事。** heartbeat 只能报告观测事实（`observed_at` / `last_output_at` / `quiet_seconds` / `process_state`），不能推断「卡死」或「有效推进」；观测进程自己失联时，必须显示「观测过期」，不能继续显示健康心跳。
6. **检查命令预检属于 runtime**，且必须与实际执行使用**同一套环境解析**；默认写法是直接 argv（`["go","build","./..."]`），不是 `bash -lc`（Windows 与登录 shell 都不保证一致）。skill 只解释诊断、排波次，不维护第二套规则。
7. **CLI 可发现性要靠行为验证，不靠 argparse 清单**：`watch --project` 恰恰是「参数被接收但行为没实现」，自动导出参数表发现不了它。`--json` 在默认 JSON 的命令上是**兼容选项**，应写清「默认即 JSON」，不是缺陷，也不应删除。

---

## 1. 事实核对（源码取证）

| # | 待核说法 | 代码事实 | 判定 |
|---|---|---|---|
| 1 | 「CLI 没把 agent.log 桥接到事件流；`task logs --follow` 不存在」 | `task logs` 存在（`cli.py:368-373`、`cli.py:654-678`），是**一次性 tail**（默认 64KB、上限 1MB，无轮询）；`watch --follow`（`cli.py:743-771`）流的是 SQLite `events` 表（`_store.py:371-391`），事件全为状态类，无 `agent_output`/`tool_use` | 部分成立：命令有，`--follow` 与消费协议缺 |
| 2 | 「监控轮询是用法错误」 | `_PHASE_ORDER` 只有 6 值（`_pipeline.py:1372`）；`last_progress_at` 仅阶段切换时写（`_pipeline.py:2262`） | 主因是设计缺口，不是用法 |
| 3 | 「没有自动拆解能力」 | `decompose/auto split` 在 `src/` 0 命中；`group plan` 只校验外部 `plan.json` | 成立，但**不应**做成 CLI 命令（§7-1） |
| 4 | 「T2/T3 改同一目录会并行冲突」 | 每任务独立 worktree（`_pipeline.py:2281`）；写者锁按 task_id（`_pipeline.py:792-806`，`TASK_BUSY`） | 不成立：运行期不冲突，代价在集成 |
| 5 | 「路径重叠应警告或拒绝」 | 无跨任务 `allowed_paths` 重叠检测；仅组内 `expected_paths` 重叠给 warning（`_groups.py:599-631`）；越界才是硬拒（`_groups.py:488-497`） | 现象成立；处置改为「风险提示 + 排波次」 |
| 6 | 「check 绝对路径换机器就挂」 | check 以 argv 直接执行（`_pipeline.py:1542`）；`_build_env` 的 `PATH` 直接继承控制进程（`_backend.py:254-258`）；`doctor` 只探 `git`/`gh`（`core.py:191`）；`_config.py:150-157` 只校验 argv 形态 | 成立；且会滑到 verify 阶段才暴露 |
| 7 | 「group 管理顺序 + 一次验收（并行）」 | 组命令面完整，但 v1.3 组内**串行**（`_group_runner.py:721-726`） | 需修正：group ≠ 并行 |
| 8 | 「`watch --project` 按项目过滤」 | `--project` 仅被 argparse 接收（`cli.py:295`），`_watch_once` 传 `store.events(None, ...)`（`cli.py:723`） | **已存在缺陷**：不过滤 |
| 9 | 「max_active_tasks=3 未被利用」 | 默认 1、上限 8（`_config.py:16`、`_config.py:138-142`）；硬闸在 `_pipeline.py:1065-1071`，拒绝码 `SLOT_BUSY` | 成立；报告写 `RESOURCE_CONFLICT` 有误 |
| 10 | （评审指出）独立 task 能否走 `group accept` | 成员绑定只发生在 `task create`（`cli-contract.md:173-178`）；`integration_preconditions` 要求 `task.group_id == group_id`（`_integration.py:173-177`）；CLI 无「绑定既有任务入组」命令 | **不能**；v1 的闭环方案作废 |
| 11 | （评审指出）项目事件过滤能否靠 `task_id IN` | 任务事件 payload **不含 `project_id`**（`_store.py:205-229`）；组事件 `task_id` 为 `None`、只有 `group_id` | 不能覆盖组事件/项目事件；需显式归属（§3-1） |
| 12 | （评审指出）把观测阈值写进项目配置是否安全 | `policy_revision = digest(config)[:16]`（`_pipeline.py:464`），组准入逐次比对（`_group_runner.py:640`、`_integration.py:188-213`） | **不安全**：改任何配置字段都会让在途任务/组撞 `POLICY_CHANGED` |

> 结论：**不是 skill 不支持并发，也不是编排者姿势错，而是运行器把「进度」压成了 6 值枚举。** 这决定了优化必须先补观测，再谈编排。

---

## 2. 根因分层

| 根因 | 表现 | 归属 | 量级 |
|---|---|---|---|
| R1 阶段粒度 + 无观测事实 | 20 分钟只见 `RUNNING/implement` | runtime（`_pipeline.py` / `_backend.py`） | 小 |
| R2 agent.log 只可 dump 不可流 | 需手拼 `runs/<run_id>/agent.log` 再 `tail -f` | runtime（`cli.py`） | 小 |
| R3 事件流无过滤 | 并行后事件无法按项目/组/任务收敛 | runtime（`cli.py` + `_store.py`） | 中（需行为测试） |
| R4 缺「两种交付模式」的显式区分 | 用独立 task 期待一次验收（不可实现），或用 group 期待并行（串行） | skill（SKILL.md） | 极小（文档） |
| R5 检查命令无前置解析校验 | 绝对路径 check 到 verify 才炸；依赖生成工具的 check 被误判配置错 | runtime（`doctor`）+ skill（写法规范） | 小 |
| R6 文档说过滤、实现不过滤 | `watch --project` 空转 | 双方 | 极小 |

---

## 3. P0：可观测性

### 3-1 事件过滤与游标语义（**先做**，因为需要行为测试）

先说清「过滤」不是加一个参数就完事：

| 语义点 | 冻结内容 |
|---|---|
| 归属来源 | 新事件**写入时显式带 `project_id`**（`_store.py:205-229` 目前没有）；旧事件回查：任务事件 → `tasks.project_id`；组事件（`task_id=None`）→ 组的 `project_id`；无归属的事件不得被猜成任何项目，列入 `unattributed` 计数 |
| 组合过滤 | `--project` / `--group` / `--task` 同时给出时取**交集**，并校验归属一致（task 不属于该 project → 报 `INPUT_INCOMPLETE`/`PROJECT_MISMATCH`，不静默返回空） |
| 游标推进 | 按**已扫描**范围推进，不按已匹配范围。即使本页没有匹配事件，`next_cursor` 也必须前进，否则宿主在无关事件里无限打转 |
| 分页 | 匹配事件多于 `--max-events` 时不得丢弃：返回 `has_more=true`，宿主用 `next_cursor` 续取；`--max-pages` 只在单次调用内限制扫描量 |
| 空响应 | 只表示「本次查询正常、无匹配事件」。**它不代表 Agent 健康、也不代表有进展**——这一句要写进 SKILL.md 与 help |
| 过滤不影响不变量 | `cursor_expired`（epoch 变化）的语义不变：换 `next_cursor` 从头重来，不算任务失败 |

**为什么必须带行为测试**：多项目交错写事件、组事件与项目事件混在同一条流里、过滤后仍要推进游标——这三种组合靠人工点一遍看不出来。

---

### 3-2 运行观测（替代 v1 的「heartbeat / stalled_seconds」）

**目标**：只报告观测事实，不做推断。

`runs/<run_id>/progress.json`（沿用 v1 的落盘位置，字段重定义）：

```json
{"api_version": 2, "run_id": "...", "log": "agent", "log_generation": 1,
 "bytes": 184320,
 "observed_at": 1793500042.0,
 "started_at": 1793499400.0,
 "last_output_at": null,
 "quiet_seconds": 642.0,
 "process_state": "alive"}
```

| 字段 | 含义 | 约束 |
|---|---|---|
| `observed_at` | 监控进程最后一次**完成**观测的时刻 | 宿主读到时若 `now - observed_at > stale_after`，状态显示「观测过期」，**不得**继续显示健康心跳 |
| `last_output_at` | 最近一次观测到日志增长的时刻 | 从未产生输出时为 `null`；`quiet_seconds` 从 `started_at` 起算 |
| `quiet_seconds` | 距最近一次输出的秒数 | **命名不用 `stalled`**：无输出不能证明卡死；有输出也不能证明有效推进 |
| `process_state` | 基于现有身份探测的 `alive` / `exited` / `unknown` | 与 `quiet_seconds` 并列展示，不互相替代 |
| `log_generation` | 日志被轮转/替换时自增 | 与字节偏移共同构成「读到哪」的身份 |

实现约束：

1. 挂载点复用 `_backend.py:157-177` 的 0.3s 循环（第 170 行本就在 `stat` 日志大小）。
2. **双阈值节流**：`min_write_interval`（默认 10s）**且** `min_byte_delta`（默认 8KB）同时满足才落盘；不能只在 64KB 时写，也不能每秒写。
3. **不写 DB、不发事件**：事件表语义是状态迁移；且 `_watch_once` 每轮都查该表，写入放大会放大读侧成本。
4. **阈值不进项目配置**：`policy_revision = digest(config)[:16]`（`_pipeline.py:464`），把 `stale_after`/`min_write_interval` 放进项目配置会让**只改提示阈值就触发在途任务 `POLICY_CHANGED`**（`_group_runner.py:640`、`_integration.py:188-213`）。放宿主机级别（`--home` 下的设置）或 CLI 参数。
5. 静默验证不能只用 POSIX 的 `kill -STOP`；Windows 需一个可控的静默测试进程（如只 `sleep` 不输出的脚本）。

---

### 3-3 `task logs --follow`：先把消费协议冻住

接口（保持 `api_version: 2`、退出码走 `_EXIT_CODES`）：

```text
zoe task logs TASK [--run RUN_ID] [--log agent] [--follow]
                [--cursor run:gen:offset] [--jsonl] [--timeout 60] [--max-bytes 1048576]
```

**冻结语义（首版）**：

| 项 | 语义 |
|---|---|
| 显式 `--run` | 只跟随该 run；run 结束后**读尽剩余内容再退出**，不无限等待 |
| 未指定 `--run` | 首次解析并**打印实际 run_id**，随后固定该 run；不做静默跳转（避免人和日志对不上） |
| 游标 | `run_id + log_generation + byte_offset` 三元组，不是裸 offset |
| 轮转/截断 | 不能只看 `size < offset`：需校验文件身份（inode/device）与首若干字节指纹；generation 变化时输出 `{"kind":"log_rotated","generation":N,"offset":0}` 并从 0 续读 |
| 有界性 | `--timeout` 到期退出；最大行长度、最大缓冲、最大单次输出都设上限 |
| 边界情况 | 末尾无换行按「不完整行」暂存不输出；UTF-8 跨块用增量解码器，不产生乱码或替换字符 |
| 输出上限 | 触达 `--max-bytes` 时返回明确原因 + 续读游标，不静默截断 |
| `--jsonl` | **每一行都是 JSON 对象**。普通文本包成 `{"kind":"raw","text":...}`，不混入裸文本 |
| 脱敏 | **`raw` 不等于绕过脱敏**。文本、工具参数、路径、命令一律过脱敏；已知完整行脱敏只降低跨块泄漏风险，不能承诺覆盖所有秘密形式，报告需说明该限制 |
| 逐条识别 | 不做「首行非 JSON 就永久降级 raw」：启动提示可能是文本、后续才是结构化事件，必须**逐条**判断 |
| 投影来源 | 按适配器的 `output_protocol` 定义行形状（`codebuddy` = `json-final`，`opencode` = `json-events`…）。**终态解析器不能直接当流式解析器**：`codebuddy.parse_output`（`_agents/codebuddy.py:157-199`）只找最后一条 `type=result`，需要单独的「行分类器」 |
| 不虚构 | 只在**日志新增完整记录**时输出；静默期间不产出、不补造，也不把它当成失败 |

**验收（替换 v1 的「每 5–15 秒必有 tool 行」）**：

- 追加一条完整记录后，在约定延迟内可见；无新增时**没有任何输出**；
- 断开后用返回的游标续读，**不重不漏**；
- 文件被替换、被截断、末尾无换行、UTF-8 跨块四种情况各有断言；
- 输出上限触达时给出原因与续读游标；
- 未登录场景（codebuddy 只吐一行纯文本）能被逐条识别为 `kind=raw` 且已脱敏。

---

## 4. P1：skill 编排规程

### 4-1 先分清两种交付模式（替代 v1 的「并行 → 组验收」）

| 模式 | 适用 | 派发方式 | 收口方式 | 硬约束 |
|---|---|---|---|---|
| **任务组交付** | 需要**一次完整交付 + 一次验收**（含组级检查、设计一致性审查） | `group create` → `group start`，成员由组冻结快照创建（create 时带 `group_id` + `item_id`） | `group accept`（成员 `task accept` 会被 `STATE_CONFLICT` 拒） | v1.3 **组内串行**，不要期待吞吐 |
| **独立任务并行** | 需要吞吐、各片独立可交付、集成由人安排 | 独立 `task create` + `start`，数量 ≤ `max_active_tasks` | 各自 `task accept`；集成/合并由人（或后续组）承担 | **不得调用 `group accept`**：非成员会被拒，且没有「事后绑定入组」的命令 |

一句话：**要一次交付 → 串行组；要并行 → 独立任务 + 显式集成步骤。** 两者拼接（并行再组验收）当前版本不支持，文档不得暗示支持。

### 4-2 「并行波次」作为**可选**规程（不与组验收绑定）

SKILL.md 第 4 步已有判据、缺动作序列。补一节，但只写「什么时候可以并行」，不写「并行后自动收口」：

**四条硬前提**（任一不满足 → **分波次或按依赖串行**，而不是合并成一个大 Spec）：

1. 没有「A 的产物是 B 的输入」的代码依赖；
2. 每片有独立 AC 与可执行 check（或明确的 `verification_scope.checks`）；
3. **运行期副作用不冲突**：共享数据库/实例、固定端口、外部服务、共享生成目录、全局缓存；
4. 有明确的集成本体（谁合、按什么顺序）与**独立判者**的验收。

**风险提示（不是重切条件）**：`allowed_paths` 交集或 `expected_paths` 重叠 → 建议排成两波、或指定合并顺序。**重叠本身不构成拒绝理由**——v1 的「有重叠就必须回 ① 重切」与「它不是硬闸」自相矛盾，已删除。

**动作序列**：

```text
① 切片 → 用现有 group plan --project P --request-file plan.json 做**只读预演**（看 warnings，不写任何东西）
② 选模式：一次交付 → 组；吞吐 → 独立任务（≤ max_active_tasks）
③ 监控两线：
   A 状态线：task events T --follow / watch --follow --jsonl --after <cursor>
   B 动作线：task logs T --follow --jsonl        （§3-3 交付后可用）
④ 独立任务模式：逐个 accept + 人工安排集成；组模式：group accept
```

**canary 显式化**：自举首波允许「1 个 canary + N 个正式」，但必须写明这是 canary，并在 canary 到 `REVIEW_READY` 时**立刻放量**，而不是等人验收完。把保守变成**有期限的策略**，而非默认行为。

---

### 4-3 检查命令预检：留在 runtime，默认直接 argv

| 层 | 内容 |
|---|---|
| **默认写法**（skill 只给规范） | `["go","build","./..."]`。**不推荐默认 `bash -lc`**：登录 shell 不保证与宿主一致（GUI 宿主、Windows、非交互环境都可能没有 profile），且与「默认支持 Windows」冲突 |
| **runtime 预检** | 在**实际检查执行的 cwd / PATH / 环境规则**下解析 `argv[0]`，返回解析到的绝对路径；**执行时再次校验**，避免预检与运行用不同工具（`_build_env` 见 `_backend.py:240-283`，执行点 `_pipeline.py:1542`） |
| **shell 形式** | `argv[0]` 是 shell 时只验证 **shell 本身**可执行，并明确标记「内部命令静态解析未知」；**不解析 `bash -c` 的内层首词**——变量赋值、管道、条件、函数、引号都会让这种判断失真。需要更强保证时要求**显式依赖声明** |
| **可用性分级** | 系统工具缺失（`go`/`git`/`gh`）→ 可提前阻断；**依赖安装后才生成的项目内工具**（`node_modules/.bin/*`、`bin/*`）→ 标 `deferred`，不得在安装前判成配置错误 |
| **诊断命名** | `doctor` 输出 `checks_preflight`：`{check_id, argv0, resolved_path, status: ok/unresolved/deferred, hint}` |
| **不做什么** | 不在 skill 侧再写一套解析规则（见 §7-4） |

> `126/127` 已被 `_pipeline.py:1490-1492` 归为**环境失败**而非测试失败——「工具找不到」现在不会被误判成代码错，只是报得晚。前置到 `doctor` 即可。

---

## 5. P2：语义纠偏（文档级，零代码）

| 位置 | 现状 | 应改为 |
|---|---|---|
| SKILL.md「用任务组交付」 | 易读成「组 = 并行」 | 明确 **v1.3 组内串行**（`_group_runner.py:721-726`），并指向 §4-1 的两种模式 |
| 监控章节 | 只说 `watch --follow` | 补两线监控（状态线 + 动作线），并写清：**空返回只表示无匹配事件，不表示健康或进展** |
| 排障表 | 部分文档写 `RESOURCE_CONFLICT` | 并发拒绝码是 `SLOT_BUSY`（`_pipeline.py:1065-1071`）；`details` 给只读快照 |
| 检查写法 | 无规范 | 默认直接 argv；不写死绝对路径；依赖生成工具标 `deferred`（§4-3） |
| 观测阈值 | 无说明 | 阈值属**观测设置**，不进项目配置（否则触发 `POLICY_CHANGED`，§3-2-4） |

---

## 6. CLI 可发现性：分三层验证

| 层 | 验什么 | 手段 | 能否发现 `watch --project` 缺陷 |
|---|---|---|---|
| 结构 | 命令、参数、默认值是否在 help 与文档中 | `zoe <cmd> --help` 存在一行描述；参数带默认值；文档命令集与实现一致的静态检查 | **不能** |
| 行为 | 过滤是否生效、输出格式是否兑现、游标是否推进 | 行为测试（双项目交错事件、日志轮转、`--jsonl` 输出形状） | **能** |
| 能力 | skill 依赖的功能是否由当前 runtime 支持 | `capabilities` 声明**能力面**（如 `event_filter: project|group|task`、`logs_follow: 1`），带版本；不是全量命令清单 | 能（新增能力必须被声明） |

结论性修正：

- `--json` 在默认输出 JSON 的命令上**保留为显式兼容选项**，help 写「默认即 JSON；此开关为兼容保留」，**不认定缺陷，不删除公开参数**；也不为了「让参数看起来有效」去改默认格式。
- `--jsonl` 需要真正的行为定义（每行一个 JSON 对象，普通文本包成对象）。当前 `_watch_follow` 恒打印紧凑 JSON（`cli.py:767-768`）而 `args.jsonl` 从未被读取——这是**行为未定义**，不是「参数多余」。
- `capabilities.commands`（机器可读全量命令模型）**后置**；本轮只做 help 文案 + 行为回归。

---

## 7. 明确**不要**做的五件事

1. **不要做 `zoe skill decompose --doc X.md`。** 切片判断依赖「这些文件会不会被同一个人改」这类语义信息，标题级解析必错，代价是 `SCOPE_VIOLATION` + rebind。机器只做校验（`group plan` 预演），不臆测意图。
2. **不要把 `allowed_paths` 重叠做成 runtime 硬闸，也不要在 skill 侧把它写成「必须重切」。** 独立 worktree + 每任务写者锁已保证运行期无写冲突；重叠是**集成风险**，工具是「提示 + 排波次」。
3. **不要把 Agent 输出写进 `events` 表。** 理由不是「几千条必然让查询退化」（未做性能测试不得断言），而是三者不同：**用途**（事件=状态迁移审计，日志=动作流）、**体量**（一次实现可产生上千条记录）、**保留策略**（事件长期留存，日志按 run 清理）。另外，事件 ID 不连续本身**不**破坏游标——游标按已扫描范围推进即可。
4. **不要在 skill 侧新增 `preflight.py` 复制 runtime 的判断。** 两套规则必然漂移；runtime 返回诊断，skill 只做解释与排波次。
5. **不要把 `bash -lc` 作为默认写法，也不要解析 `bash -c` 的内层命令。** 见 §4-3。

---

## 8. 实施顺序与工作量

| 序 | 项 | 归属 | 估时（含行为测试） | 依赖 |
|---|---|---|---|---|
| 0 | **前置门**：上一轮的迁移守卫、发布兼容、真实端到端验证若未闭环，优先于本轮体验优化 | — | — | — |
| 1 | 事件过滤（`--project/--group/--task`）+ 游标推进 + 行为测试 | runtime | 1.5–2 人日 | 无 |
| 2 | help 文案（每个子命令一行描述 + 参数默认值）与**现有输出契约**说明（`--jsonl`、`task logs` 是快照） | runtime + skill | 0.5 人日 | 无 |
| 3 | 最小 `task logs --follow`（§3-3 协议，先支持 `--run` 显式模式） | runtime | 1.5–2 人日 | 2（先定输出契约） |
| 4 | 运行观测 `progress.json` + `status` 展示（含观测过期） | runtime | 1–1.5 人日 | 无 |
| 5 | `doctor` 检查预检（同环境解析、`deferred` 分级、执行时复校） | runtime | 1 人日 | 无 |
| 6 | 「两种交付模式 + 并行波次（可选）」写进 SKILL.md | skill | 0.5 人日 | 1、3（否则无法观察） |
| 7 | `capabilities` 能力面（后置） | runtime | 1 人日 | 6 之后视需要 |

**不做估时乐观化**：第 1 项 v1 估 0.5 人日，是把它当成「加参数」；实际涉及归属回查、交集语义、游标推进与三组行为测试。

---

## 9. 验收判据（替换 v1 的 KPI 表）

v1 的指标有 5 处不成立，均已删除：槽位利用率越高越好、首条工具动作 ≤60s、`blocked` 次数=人工介入次数、把 `126/127` 放进 `block_code` 集合、零集成冲突作为通用承诺。

本轮采用 6 条**可判错**的判据：

| # | 判据 | 通过标准 |
|---|---|---|
| 1 | 项目隔离 | 两个项目交错产生事件，过滤结果**不串项目且不漏事件**；组事件与项目事件都能被正确归属 |
| 2 | 日志增量 | 追加后及时可见，无新增时不产出；断线续读、轮转、截断、末尾无换行、UTF-8 跨块均正确 |
| 3 | 观测语义 | 静默与监控失联被区分；`process_state=unknown`/观测过期**不会**被自动判成执行失败 |
| 4 | 检查预检 | 预检与**实际执行**使用同一环境与同一解析结果（执行时复校）；生成型工具不误判为配置错 |
| 5 | 交付模式 | 独立任务**不可能**在未集成的情况下被报告为「组验收成功」（非成员被拒，文档不暗示可行） |
| 6 | 端到端 | 从真实 Agent 启动到最终验收，至少完整走通一次并留记录（含 `candidate_sha`/`validated_sha`、证据 ID） |

---

## 10. 修正记录（对原报告与本文 v1）

| 原表述 | 问题 | v2 处理 |
|---|---|---|
| 「独立 task 并行 → 全部 REVIEW_READY → group 一次验收」 | 非成员不能被 `group accept`，且无绑定命令 | 删；改为两种模式（§4-1），并列为验收判据 5 |
| 「多个 Agent 输出写事件表会让查询退化几千条」 | 未做性能测试的断言 | 改为用途/体量/保留策略三条理由（§7-3） |
| 「事件 ID 不连续破坏游标」 | 不成立 | 删除；改为「按已扫描范围推进」 |
| 「路径重叠 → 回到 ① 重切」 | 与「不是硬闸」矛盾 | 改为风险提示 + 排波次（§4-2） |
| 「不满足并行条件就合并成一个 Spec」 | 通常应是分波/串行 | 改（§4-2） |
| 「`stalled_seconds` / 看见无输出=卡死」 | 无输出不能证明卡死 | 改 `quiet_seconds` + `process_state`（§3-2） |
| 「每 5–15 秒必有 tool 行」 | 推理/长命令/缓冲会合法静默 | 改为「有新增完整记录才输出」（§3-3） |
| 「首行非 JSON 永久降级 raw；raw 原样输出」 | 逐条判断才对；raw 仍须脱敏 | 改（§3-3） |
| 「默认 `bash -lc`；解析 `bash -c` 内层首词」 | 跨平台不可靠、解析不可靠 | 改直接 argv + shell 只验自身（§4-3） |
| 「skill 侧新增 `preflight.py`」 | 与 runtime 规则重复、必然漂移 | 删（§7-4） |
| 「`--json` 是空转选项/缺陷」 | 是兼容选项；不应删公开参数 | 改（§6） |
| 「`--json` 在 cli-contract 有 19 处」 | 计数错误（21-39 行 5 处，全文 29 处） | 已更正 |
| 「`capabilities.commands` 本轮就做」 | 参数清单不能证明行为 | 后置（§6、§8-7） |
| 「槽位利用率 ≥0.66 / 首行 ≤60s / blocked 计数 / 126-127 进 block_code」 | 均为误导性指标 | 删除，换成 §9 六条 |

---

## 11. 附：关键代码锚点

```text
zoe-runtime/src/cli.py:144-145            output()：默认即 JSON（--json 的兼容语义）
zoe-runtime/src/cli.py:152-402            _build_parser：24 个子命令，仅 1 处 help=
zoe-runtime/src/cli.py:220                route stats --window（全仓唯一带 help 的参数）
zoe-runtime/src/cli.py:294-303            watch 参数（--project 未生效、--jsonl 未被读）
zoe-runtime/src/cli.py:368-373            task logs 参数（无 --follow，快照语义）
zoe-runtime/src/cli.py:648-651            task events（无 --follow）
zoe-runtime/src/cli.py:654-678            _task_logs：全量 read_bytes + tail
zoe-runtime/src/cli.py:699-735            _watch_once：cursor/epoch/heartbeat，events(None)
zoe-runtime/src/cli.py:743-771            _watch_follow：轮询 + timeout 到期退出
zoe-runtime/src/cli.py:1108-1112          doctor 是唯一真正读 args.json 的分支
zoe-runtime/src/_store.py:205-229         任务事件 payload（无 project_id）
zoe-runtime/src/_store.py:371-391         events 查询（支持按 task_id 过滤）
zoe-runtime/src/_backend.py:157-177       0.3s 监控循环（已 stat 日志大小）→ 观测挂载点
zoe-runtime/src/_backend.py:240-283       _build_env：PATH 继承、worker 凭据白名单
zoe-runtime/src/_pipeline.py:464          policy_revision = digest(config)（阈值不能进配置）
zoe-runtime/src/_pipeline.py:1065-1071    并发硬闸 SLOT_BUSY
zoe-runtime/src/_pipeline.py:1372         阶段枚举（6 值）
zoe-runtime/src/_pipeline.py:1542         check 以 argv 直接执行
zoe-runtime/src/_pipeline.py:2262         last_progress_at 仅阶段切换时写
zoe-runtime/src/_pipeline.py:2281         per-task worktree
zoe-runtime/src/_config.py:16,138-142     MAX_ACTIVE_TASKS=8，默认 1
zoe-runtime/src/_config.py:150-157        checks 只校验 argv 形态，不校验可解析
zoe-runtime/src/core.py:191               doctor 仅探测 git/gh
zoe-runtime/src/_groups.py:488-497        expected_paths 越界 → POLICY_DENIED（硬）
zoe-runtime/src/_groups.py:599-631        成员间 expected_paths 重叠 → 仅 warning
zoe-runtime/src/_group_runner.py:640      组准入比对 policy_revision
zoe-runtime/src/_group_runner.py:721-726  v1.3 组内串行
zoe-runtime/src/_integration.py:173-177   成员校验：task.group_id 必须等于组
zoe-runtime/src/_integration.py:188-213   成员集成前的 policy_revision 校验
zoe-runtime/src/_agents/codebuddy.py:121  启动即 --output-format stream-json
zoe-runtime/src/_agents/codebuddy.py:157-199  parse_output（仅终态，不能当流式解析器）
zoe-runtime/src/_agents/base.py:477-493   json_objects（可复用于行分类）
zoe-workflows/references/cli-contract.md:173-178  组成员在 create 时绑定，无事后绑定
zoe-workflows/references/cli-contract.md:68       watch [--project P]（过滤未生效）
```

---

## 12. 落地状态（v1.5.0，2026-10-30）

| 设计项（§） | 实现位置 | 行为要点 | 测试 |
|---|---|---|---|
| 事件过滤 + 游标（§3-1） | `src/_store.py`：事件写入带 `project_id`；新增 `events_filtered()`；`src/cli.py`：`watch --project/--group/--task`、`task events --follow` | 三条件取交集；归属错配报 `PROJECT_MISMATCH`/`INPUT_INCOMPLETE`；游标按**已扫描**推进；`unattributed` 计数；无过滤时走原 `events()` 路径 | `tests/test_v150_observation.py::TestEventFiltering`（5）、`TestEventOwnership`（4）、`TestFilterValidation` |
| 运行观测（§3-2） | `src/_progress.py`（新）、`src/_backend.py` 监控循环、`src/cli.py` `task status` | `progress.json`：`observed_at`/`last_output_at`/`quiet_seconds`/`process_state`/`log_generation`；双阈值节流（10s **且** 8KB）；`finally` 写 `exited`；`observations_stale` 独立成信号 | `TestRunObservation`（5）、`test_doctor_ready_tracks_only_unresolved_tools` |
| 日志增量流（§3-3） | `src/_logstream.py`（新）、`src/cli.py` `_logs_follow` | 游标 `run:gen:offset`；只发完整行、半行留缓冲；轮转/截断各自检测；UTF-8 跨块；超长行标记；`--jsonl` 每行都是对象、`raw` 也脱敏；`--max-bytes` 给续读游标；run 结束即补读退出；快照响应带 `snapshot: true` + `cursor` | `TestLogFollower`（7）、`TestLogProjection`（6）、`TestLogsFollowCommand` |
| 检查预检（§4-3） | `src/_config.py`：`resolve_check()` / `checks_preflight()` / doctor 字段；`src/_pipeline.py`：执行前复校 | 状态 `ok/shell/deferred/unresolved/invalid`；只有 `unresolved` 进 `ready`；`shell` 内部命令**不解析**；执行时 `unresolved` 直接产出 `error_class=environment` 的 FAIL，不起进程 | `TestChecksPreflight`（7） |
| CLI 可发现性（§6） | `src/cli.py`：`_COMMAND_HELP`/`_COMMAND_EPILOG`/`_apply_command_help`；`capabilities.observation` | 24 个子命令 + 嵌套命令全部有一行描述；关键参数带默认值；`--json` 标注为兼容选项而非格式开关；能力面用**语义版本**声明行为（不是命令清单） | 契约测试：`tests/contract/test_skill_cli_contract.py`、`tests/test_contract_artifacts.py` |
| 两种交付模式（§4-1） | `SKILL.md` 第 4 步 + 「用任务组交付」 | 任务组 / 独立任务并行两表；明写「组内串行」「成员不能自验收」「无事后绑定命令」 | 文档；契约测试校验命令存在性 |
| 并行波次（§4-2） | `SKILL.md` 第 4 步、`references/decomposition-patterns.md` | 四条硬前提（依赖、独立 AC、**运行期副作用**、集成本体）；不满足 → 分波/串行；路径重叠改为风险提示 + `group plan` 预演 | 文档 |
| 两线监控（§3-3/§5） | `SKILL.md` 第 6 步 | 状态线（`watch`）+ 动作线（`task logs --follow`）；空返回=心跳；`observations_stale` 与 `quiet_seconds` 的正确读法 | 文档 |
| 兼容边界 | `runtime-requirements.json`（`min_version` 1.5.0 + 4 个新能力）、`src/__init__.py`（1.5.0） | 老运行器在包装器预检即被拒，而不是让宿主跑到 `--follow` 才发现不存在 | `tests/test_requirements.py`、`tests/test_distribution.py` |

**落地时做的三个取舍**（与 v2 文本的差异，写下来避免以后被当成 bug）：

1. **观测阈值用环境变量**（`ZOE_PROGRESS_MIN_INTERVAL` / `ZOE_PROGRESS_MIN_BYTES` /
   `ZOE_OBSERVATION_STALE_SECONDS`），没有新增项目配置字段——避免改提示阈值改变
   `policy_revision` 而让在途任务撞 `POLICY_CHANGED`。
2. **`checks_preflight_ok` 并入 `ready`**，但只有 `unresolved` 参与；`deferred`（安装后才有的
   工具）与 `shell`（内部命令不可静态验证）不阻断，否则会误伤正常的首次接入。
3. **`progress` 是 `task status` 的加法字段**，不写状态库、不发事件：事件表是状态迁移审计，
   而 `watch` 每轮都查它，动作流走文件（`agent.log`）在宿主侧合并。

**验证方式**：`cd zoe-runtime && PYTHONPATH=$(pwd) .venv/bin/python -m pytest -q`
→ `778 passed, 6 skipped, 319 subtests passed`；`.venv/bin/ruff check .` → 全绿；
`cd zoe-workflows && python3 build.py --check` → 通过。
