# 本地运行器（接入与诊断）

## 目录

- 实际实现与部署 · 执行范围与隔离 · `doctor` 输出 · 单次 run 的墙钟上限
- 运行观测 · 当前边界 · 候选上的 `ENVIRONMENT_ERROR`（三步诊断）
- 执行配置与模型授权 · 首次接入顺序

## 实际实现与部署

本包为 Python 3.11+ 标准库实现，运行时不需第三方依赖，可通过 `pip install zoe-runtime`
安装为 `zoe` 命令；也可用 `python -m src` 调用。配置由 YAML 收敛为 JSON。
执行后端只有 `local-process`：需要本机 Git、本机已安装并认证的编码 CLI，以及可写的任务目录；
**不涉及 Docker**——容器后端已退出产品支持范围，旧配置会被显式拒绝
（`CAPABILITY_UNSUPPORTED`，`error.details.migration` 给出改法），历史容器任务只读保留。
GitHub 发布需要 gh。
平台层覆盖 macOS（POSIX）与 Windows，两平台各自验证，不跨平台推断；Windows 目前无真实
端到端记录，按 `IMPLEMENTED` 对待。

```bash
pip install zoe-runtime
zoe --version
zoe doctor                                # 宿主机诊断，不创建状态目录
zoe doctor --project example --json       # 项目就绪度检查

# 或通过 skill 包装器（等价转发）
bash <skill-dir>/scripts/zoe.sh --version        # macOS / Linux
<skill-dir>\scripts\zoe.cmd --version            # Windows（cmd）
pwsh <skill-dir>/scripts/zoe.ps1 --version       # Windows（PowerShell，转发给 .cmd）
```

skill 包**不含运行器**，包装器只负责定位、兼容预检与转发，顺序为
`ZOE_BIN` → `ZOE_SRC` → PATH 上的 `zoe`：

- `ZOE_BIN`：受信任绝对路径的可执行文件。
- `ZOE_SRC`：包含 `src/__main__.py` 的仓库根目录绝对路径（开发期显式绑定；`src` 是包名）。
- 两者都必须是绝对路径并现场校验，不合法即返回 `RUNTIME_NOT_FOUND`（exit 126）。
- 没有显式绑定且 PATH 无 `zoe` 时直接失败并给出修复指引（`RUNTIME_NOT_FOUND`，exit 126）。
  不存在「skill 同级 `src/`」这类隐式回退：那会让包装器加载到非预期的代码。
- 定位成功后，先用**同一个**运行器执行
  `capabilities --check-requirements runtime-requirements.json`；不满足区间即
  `RUNTIME_INCOMPATIBLE`（exit 5），请求不会被转发。`--version` 与 `--which` 免检，
  它们是排障通道。

也可设置 ZOE_HOME。使用 project-profile.example.json 的实际字段（schema v2：agent_profiles），不把旧 YAML 直接传入。
project register 写入私有项目配置，不认证镜像能力。

能力态按 `(adapter_id, backend)` 判定，三态：IMPLEMENTED / UNVERIFIED / VERIFIED。
`zoe capabilities --json` 与 `zoe agent list --project P --json` 是唯一事实来源；准入如何
判定（默认标注 `unverified`、`require_real_e2e: true` 才拒绝）见
[cli-contract.md](cli-contract.md)「能力与准入」。

让某个 backend 变成 VERIFIED 的唯一方式是 `compatibility_evidence` 指向一条精确版本的
记录（见运行器仓库 `docs/compatibility/README.md`），或 v1 配置的
`compatibility_verified: true`（迁移为 legacy 声明，标 source）。`doctor` 的 `ready` 只表示
环境可执行，`trusted` 才表示有真实 e2e 记录。

并发由 `max_active_tasks`（1..8，默认 1）控制，单任务唯一写者不变量不变；活跃 Run 是**全局**
计数（同一 `ZOE_HOME` 下所有项目），限额取自派发项目自身。配置改变后旧任务执行被阻塞；
保留旧成果并重新评估（task rebind 显式接纳新策略），不得为了继续执行恢复已撤销权限。

`zoe state migrate --to 3` 是停机迁移：要求无活跃执行槽与占位 Run，先做一致性备份，再事务迁移并
integrity_check；旧版二进制看到 v3 会拒绝写入（`MIGRATION_REQUIRED`）。

## 执行范围与隔离

默认 `local-process`：Agent 以本机账户运行在任务 worktree 中，进程树由平台层管理。
**worktree 是文件组织，不是系统沙箱**：Agent 仍可读取工作区之外的目录与本机凭据；
`allowed_paths` + 事后 diff 提供的是**问责**（越界即拒绝交付），不是预防。本版没有镜像级
隔离可承诺：没有只读根文件系统、没有 capability 限制、没有默认 `network=none`。

每个适配器声明自己的命令形态与输出协议（最终 JSON 或事件流），控制器只按适配器解析，
不猜字段。冻结 Spec 以 stdin 送入，不进入 argv；prompt 上限 64 KiB。typed options 只有
model / max_turns / permission_profile / approved_tools；output-format、cwd、resume、附加
目录、插件/MCP 安装等为控制器保留参数，profile 无法覆盖。权限行为随版本变化，必须在目标
环境实测；不得把 `-p` 当作完整无人值守授权。

工作进程的 cwd 是任务 worktree；Git 写操作（commit/push/PR）始终由控制器执行（Agent 在
worktree 内能执行 git，但越界提交会被 `SCOPE_VIOLATION`/`EXTRA_COMMIT` 检出并拒绝交付）。
凭据按适配器/供应商前缀白名单注入（如 CODEBUDDY_/ANTHROPIC_/OPENAI_），profile 不能借用
其他供应商的凭据；环境变量按名注入，值不落盘。网络沿用本机配置，不做出口限制，也不把任何
配置声明等同于技术上已限制出口。

## doctor 输出

`ready` 是**六个条件的合取**：`git` ∧ `process_identity` ∧ `platform_lock` ∧
`platform_tree` ∧ `checks_preflight_ok` ∧ `placeholders_ok`；声明 `require_real_e2e: true`
的项目再追加 `trusted`（该 backend 有真实 e2e 记录 = `checks.adapter_approved`）。它不表示
已经跑过实际业务任务，也不表示适配器已通过端到端验证。`adapter_probe_passed` 只在显式
probe 时有意义。`resolution`（path/source/version/notes）报告本项目实际会启动哪个二进制、
依据哪个来源（explicit / process-path / known-location / login-shell）；`start` 启动的
`argv[0]` 就是这个绝对路径。

`checks.adapter_approved` 是**可信度标签，不是入场券**：默认策略下它为 `false` 也不阻断
派发（只要求响应、run 记录、事件与报告带 `unverified` / `trust_level`）。把它当成
`ready` 的必需项是容器后端时代的旧口径，已经不成立。

`ready=false` 要读子项再分诊，不要把不同故障面都读成"环境未就绪"：

| 子项为假 | 故障面 | 动作 |
|---|---|---|
| `git` | 宿主机缺工具 | 装工具 |
| `checks_preflight_ok` | 项目 checks 配错（`unresolved` / `invalid`） | 改 `checks[*].argv` |
| `placeholders_ok` | 配置没填完 | 填 `REPLACE_WITH_*` / `<FILL:*>` / `/absolute/path/to/*` |
| `platform_lock` / `platform_tree` / `process_identity` | 平台层不可用 | 停止派发，先修平台层 |
| `trusted`（仅严格项目） | 无真实 e2e 记录 | 补 `compatibility_evidence`，或改用已获准且已验证的候选 |

严格项目缺 e2e 记录时**不要**把"去掉 `require_real_e2e`"当排障动作：那是用户改变项目政策，
需要明确决定并重新 `register` + `attest`。

`checks_preflight` 逐条给出检查命令的 `argv[0]` 能否解析。每个状态对应一种动作，只有
`unresolved` / `invalid` 计入 `ready`：

| status | 含义 | 计入 `ready` | 动作 |
|---|---|---|---|
| `ok` | 现在就能解析到绝对路径 | 否 | 无 |
| `shell` | `argv[0]` 是 shell；内部命令**不做静态解析** | 否 | 仅用于确需管道/条件时；声明"内部命令不可验证" |
| `deferred` | 安装/构建后才产生（`node_modules/.bin/*`、`bin/*`、`target/*`…） | 否 | **仅表示推迟确认**：不算配置错，也不代表本次一定会跑通 |
| `unresolved` | 裸名不在 PATH，或相对路径不存在且不像生成物 | **是** | 改 `argv` 或修 PATH |
| `invalid` | `argv` 为空/形态非法 | **是** | 补 `argv`（注册期本该就拒） |

**两处 cwd、两处 PATH 都不同**，这是最容易造出"假绿"的地方：

| 阶段 | `cwd` | PATH 来源 |
|---|---|---|
| `doctor` 的 `checks_preflight` | 项目 `repo` | `doctor` 进程自身的 PATH（`resolve_check(..., search_path=None)`） |
| 执行前复校（`run_checks` → `resolve_check`） | **任务 worktree** | supervisor 继承的 `os.environ["PATH"]` |

两条推论：① PATH 可能不同（GUI 宿主常缺 `/usr/local/bin`、`~/.local/bin`、版本管理器 shim）；
② **cwd 必须是任务 worktree**——任何把 cwd 挪回项目仓库的写法（典型是在 shell 形式里先
切换到仓库根再执行）都会让"原仓库是绿的、候选是坏的"变成一次绿色通过。
`bash -c` 也**不是** PATH 或 Windows 的解法：它既不改变 PATH 来源，也不保证 `bash` 存在。

写法排序：

1. 首选直接 argv（`["go","test","./..."]`、`["pnpm","exec","vitest","run"]`），由 runtime 决定 cwd；
2. 工具不在 PATH 时，**装到宿主 PATH 或写可解析的绝对路径**，而不是换 shell；
3. 确需管道/条件才用 shell 形式，并接受"内部命令不可验证"；
4. `deferred` 的工具由任务自己准备，但**不要**据此推断"Agent 会装依赖"——那条链没有任何保证。

`doctor` 的这部分输出应被读作**"当前环境预检"**；执行阶段以实际 cwd、实际解析到的工具与
退出码为准。**负向验收（最高价值）**：在一个夹具里让**原仓库测试通过、候选 worktree 测试
失败**，最终验证必须是 `FAIL`——这一条同时抓住"cwd 指错"和"预检当执行用"两类错误。

## 单次 run 的墙钟上限（`timeout_seconds`）

| 项 | 值 |
|---|---|
| 作用域 | **项目级**，不是任务级、不是 profile 级 |
| 默认 | `3600`（秒）；**缺字段**时用默认值 |
| 合法区间 | `60..86400` 的整数秒；写成字符串、小数或 `true` 会在注册/预检期被拒（`INPUT_INCOMPLETE`，`field=timeout_seconds`） |
| 生效点 | 本机后端在 run 监视循环里按墙钟判定，超时以 `RUN_TIMEOUT` 结束该 run |
| 可观测 | `doctor` 的 `checks.run_timeout_seconds`（生效值）、`checks.run_timeout_declared`（写的原值）、顶层同名字段 |
| 副作用 | 属于项目配置，改动会改变 `policy_digest`：在途任务随后 `start/resume` 会撞 `POLICY_CHANGED`，需 `rebind` |

因此：**不存在"给这个任务单独延长超时"的开关**。要延长只能改项目配置并接受上述代价；
更便宜的做法是把任务切到"能在默认上限内到达可验收点"（拆分依据见
[decomposition-patterns.md](decomposition-patterns.md)）。超时之后怎么恢复见
[recovery-policy.md](recovery-policy.md) 的 `RUN_TIMEOUT` 一节。

## 运行观测

每次执行会在 `runs/<run_id>/progress.json` 留下观测事实，`task status` 以 `progress` 段返回：
`observed_at`（监控最后一次完成观测）、`last_output_at`（最近一次看到日志增长，可能为 null）、
`quiet_seconds`、`process_state`（`alive`/`exited`/`unknown`）、`log_generation`、`bytes`、
`observed_age_seconds` 与 `observations_stale`。

读法：

- **无输出 ≠ 卡死，有输出 ≠ 有进展。** 这两个结论都要靠 `state`/`phase`/Run 状态，
  不要把 `quiet_seconds` 大当成失败，也不要因为 `bytes` 在涨就说"做得很顺"。
- `observations_stale=true` 说明**监控自己失联**（观测进程停了），此时进度数字不可信，
  应重新 `task status --refresh` 或 `reconcile`，而不是判任务失败。
- 阈值（`ZOE_PROGRESS_MIN_INTERVAL`、`ZOE_PROGRESS_MIN_BYTES`、
  `ZOE_OBSERVATION_STALE_SECONDS`）是**宿主观测设置**，故意不放进项目配置：项目配置的任何
  改动都会改变 `policy_revision`，只调一个提示阈值不该让在途任务撞 `POLICY_CHANGED`。

`process_identity` 与 `platform_tree` 必须是**真的探测**：前者走系统调用（Linux `/proc`、
macOS `proc_pidinfo`）而不依赖外部 `ps`；后者起一个短命子进程，要求"组内有进程"与"组已清空"
两种判定都正确。它返回 false 时 `ready` 必为 false：不要在观测失败的情况下派发，那只会让每个
run 以 `PROCESS_UNKNOWN` 收场。

本仓库环境没有记录任何平台 × CLI 的真实 `real_e2e`，真实执行前置验证未完成。

### 监控脚本的运行前提

`scripts/zoe-monitor.sh` / `scripts/zoe-monitor.ps1` 只做观察，它们的运行前提与语义陷阱：

- 只认 `ZOE_BIN`（默认 `zoe`），**不认 `ZOE_SRC`**：源码绑定环境会 `exit 2`；要么
  `pipx install -e`，要么给一个 shim 并让 `ZOE_BIN` 指向它。
- 包装器的 `--which` 输出的是 **JSON 对象**，不是裸路径；`ZOE_BIN=$(… --which)` 是错误用法。
  已安装环境用 `ZOE_BIN=$(command -v zoe)`。
- `.sh` 依赖 `jq`，缺则 `exit 2`；`.ps1` 用 `ConvertFrom-Json`，不依赖 `jq`。**缺依赖不是
  任务故障**：应回退到 `watch --follow` + `status --refresh` 协议，而不是把运行中的 Agent
  报成失败。
- **退出码 `0` 有两种含义**：`[done] all targets final` 与预算到期。后者完全可能仍有任务
  在跑，必须再做一次状态核对。机器可读的结束原因单独给一行
  `[stop] reason=ALL_TERMINAL|BUDGET_EXHAUSTED|HUMAN_REQUIRED|WATCH_ERROR|DEPENDENCY_ERROR`，
  `--stop-file F`（PowerShell `-StopFile`）把它连同 `next_cursor` / `rounds` /
  `elapsed_seconds` 写成 JSON。**宿主引用的"结束原因"只允许是这一行**，不要靠末行文案猜。
- **预算是实际耗时**：`--max-seconds N` 按墙钟比较（与 `--max-rounds` 取先到者）。不要用
  `interval × rounds` 估算时长 —— 每轮还有 CLI 查询与重试耗时，估算只会让人以为还有时间。
- `--with-log`（`-WithLog`）每轮追加每个仍在跑的目标的**新增**可读进展（展示游标去重、
  run 切换或日志回绕即重新定位）。它依赖 `task logs --after`：运行时不支持时脚本自动关闭
  并打印 `[log-off]`，其余监控照常；读取失败只记 `[log-error]`，不计入 `--max-errors`、
  不改变退出码。**`[log]` 是过程观察，不是成功证据。**
- `[tick]` 带 `phases=<task>:<phase>,…` 与 `runs=<task>:<run>,…`，用于证明"仍在监控"。
  **阶段长时间不变是正常的**（`implement` 可以跑 40 分钟）：阶段没变不等于卡住。
- 游标与事件文件默认写在**当前工作目录**（`./zoe-cursor.txt`、`./zoe-events.jsonl`）。同一
  目录监控两个项目或两组目标会共用一份游标，导致静默跳过事件——按项目/目标集合给
  `--cursor-file` / `--events`（或 `-CursorFile` / `-Events`）。

## 当前边界

- 工作区接续已实现；strategy=native 显式拒绝。session_id 仅作诊断记录。
- codex 的 CLI 事实为 FACT_PENDING：适配器已登记但无冻结命令形态，能力态保持
  IMPLEMENTED，不能据此声称“已支持 codex”。
- 扩展适配器是代码变更，不是运行时可安装插件；不从仓库动态 import。
- 非零 Agent 退出或验证失败进入 BLOCKED，下一次 resume 才修复，不自动无限循环。
- 没有常驻调度器；CI 通过 status --refresh 查询，没有安装定时任务。
- 暂停停止受管进程树；父进程已死但子树存活时判 `PROCESS_UNKNOWN`，不自动释放配额，
  `task recover TASK [--run RUN] [--confirm-stop]` 是显式的人工收口路径（`--run` 缺省取
  `current_run_id`，响应 `run_source` 说明来源；不会替你判断"该收哪个 run"）。
- 编排记录（`orchestration *`）、可读摘要（`task summary`、`report.md`）与项目上下文包
  （`project context`）已实现；摘要晚于事件流会标 `stale`，不以摘要覆盖控制器状态。
- 预算计数由控制器持有，宿主写入返回 `POLICY_DENIED`；但修复轮次/重试上限尚未在 `start` 强制。
- 单用户受信控制面：本地用户/宿主负责真实人工授权来源，accept 字段不是多用户身份验证系统。
- 运行日志保留供排障，暂不自动清理和日志轮转。管理员需管理磁盘空间。
- 不支持子模块/LFS 特殊过滤器或依赖 Git 元数据的验证，遇到此类仓库先评估。

## 候选上的 `ENVIRONMENT_ERROR`：三步诊断

`route plan` / `create` 报出 `ENVIRONMENT_ERROR` 时，先取证再下结论 —— 同一个错误码有
三个来源，处置完全不同：

1. **先看是什么**：`route plan --json`（或 `create` 的 `details`）里 `candidates[]` 的
   `code` / `detail` / `layers`。

   | `detail` | 含义 | 不是 |
   |---|---|---|
   | `probe budget exhausted` | 单次 `plan_route` 的 `time_budget` 用完了（逐候选 `doctor --probe`） | 不是"环境坏了" |
   | `doctor reports not ready` | 六项合取里有一项为假（见上文 `ready=false` 分诊表） | 不是"这个模型不能用" |
   | `agent CLI not resolved on this host` | 该 profile 的 `env_names` 下找不到二进制 | 不是"没装这个适配器" |

2. **再分静态/动态**：`route plan --json --no-probe`。它成功**只说明"不探测时静态规则
   通过"**，不能证明 CLI 可执行、依赖完整、模型可用，也不能单独证明是预算问题。

3. **再单独验该候选**：`zoe doctor --project P --agent-profile <候选> --json`，读
   `checks` / `resolution` / `resolution_notes` / `policy_problems`，并**自己计时**
   （`time zoe doctor …`；doctor 目前不输出探测耗时）。

只有当多次观察都指向"探测慢"时，才谈得上对探测做优化（例如复用一次探测）。
`--no-probe` 通过本身不是结论。

三处纪律：

- **显式指定时候选只有一个**：此时的 `ENVIRONMENT_ERROR` 只说明"这一个候选不可用"，
  不能读成"整份白名单都不可用"；
- **不得因此自行换 profile**：候选被排除是环境或授权结论，换执行配置只能由用户决定；
- 若要固定默认档，改的是**项目配置**（`routing.mode` / `default_agent_profile`），
  改完必须重新 `attest`，在途任务 `rebind`。

## 执行配置与模型授权

`agent_profiles` 是"配过什么"，`routing.allowed_profiles` 是"允许 Zoe 派发什么"。后者同时约束
显式指定与自动选择——不是"自动派发白名单"：显式指定照样要过它，否则新加一个昂贵 profile 就能
靠 `--agent-profile` 直接执行。

| 项目配置 | 授权语义 |
|---|---|
| 没有 `routing` 段 | "历史配置即授权"：`agent_profiles` 每一项都算已授权。这不是严格白名单，汇报时不要混用两种说法 |
| 有 `routing` 段 | 严格白名单：`allowed_profiles` 必须显式声明、非空、包含 `default_agent_profile`，且只引用已定义的 profile |
| `"routing": null` | **拒绝**（`INPUT_INCOMPLETE`）：键存在但值不是对象不等于"没有该段"，否则它会同时跳过白名单与人工确认 |

声明了 `routing` 段之后，第一次派发前还要有一次**人工确认**，记录在
`$ZOE_HOME/projects/<id>.attest.json`：

```text
zoe project attest --project P --profiles cb-primary --dry-run
zoe project attest --project P --profiles cb-primary --expect-policy-hash <dry-run 的 policy_hash>
```

确认记录绑定整份配置摘要（`policy_hash`），因此换模型、换端点、换权限档、往白名单加 profile
都会让它失效，需要重新确认；`rebind` 不写确认记录。没有确认记录时 create/start/reassign 返回
`ALLOWLIST_UNCONFIRMED`，`details.reason` 区分 `missing`、`policy_changed_since_attestation`、
`candidate_not_confirmed` 与 `record_invalid`（记录存在但缺 `policy_hash` 或
`confirmed_profiles` 不合规——坏记录按未确认处理，不会因为字段缺失而放行）。

**预览与写入之间的一致性**（runtime ≥ 1.5.1 才有）：`--dry-run` 展示的
`policy_hash` / `confirmed_profiles` 与正式写入之间存在真实窗口——dry-run 显示 `H1`、用户
同意、写入前另一进程改了模型，写入时算出 `H2`。带上 `--expect-policy-hash H1`
（与可选的 `--expect-profiles a,b`）时，runtime 在**写入用的同一把 control 锁内**重新读配置、
重算摘要并比对：

- 一致 → 写入；
- 不一致 → 返回 `ATTEST_PRECONDITION_FAILED`，`details` 带 `field`、`expected` / `observed`
  摘要（与 `*_revision` 短摘要）、集合差异与 `next`，**不写新记录**。

不带 `--expect-*` 时行为与旧版一致：只能**事后**从写入响应的 `policy_hash` 发现不一致
（发现后必须重新展示并重新决定；记录无法删除，下一次确认会覆盖它）。写入前再读一次只能
缩短窗口，不能消除——消除靠上面这条锁内比对。两种情况下都不得声称"确认是原子的"：它证明
"这份配置被确认过一次"，**不**证明"当初是谁写的白名单"，也不防同机写权限的伪造。

`model` 与 `allow_cli_default_model` 二选一：

| `model` | `allow_cli_default_model` | 结果 |
|---|---|---|
| 非空、无前后空白 | 缺省 / `false` | 显式模型 |
| 缺失 | `true` | 允许跟随 CLI 默认，`model_unresolved=true` |
| 非空 | `true` | `INPUT_INCOMPLETE`：该标志会被静默忽略，不接受静默忽略 |
| 缺失 | 缺省 / `false` | `INPUT_INCOMPLETE` |

模型身份未知（`model_unresolved`）与"工具后来报告了模型"是两件事：报告值只记进
`reported_model`，不能倒推为启动前已固定。

配置里出现 `REPLACE_WITH_*` / `<FILL:*>` / `/absolute/path/to/*` 时，注册与派发都会被拒绝，
`details.fields[]` 指出具体字段；`doctor` 的 `placeholders_ok=false` 并计入 `ready`。

## 首次接入顺序

1. **写项目配置**：复制 [project-profile.example.json](project-profile.example.json)，只改
   `project_id` / `repo` / `checks[*].argv` / `allowed_paths` 四处。

   三个示例文件里的值都是**示例，不是推荐值**，尤其注意两处（JSON 不能写注释，所以记在这里）：

   | 示例 | 出处 | 为什么不能照抄 |
   |---|---|---|
   | `max_active_tasks: 1` | `project-profile.multi-model.example.json` | 保守示例；真实并发度由你的槽位与成本决定。另外**活跃计数是全局的**（跨项目），配 1 不等于"本项目独占 1" |
   | `cost_class: premium` | 早期示例的评审档 | `premium` 会让 `pin_model` 默认 `true`，而 pin 只接受 `reported_match`（逐字一致）与 `alias_confirmed`（上报值在 profile 的 `model_aliases` 里）。请求名与供应商名不同（实测 codebuddy：`BC-DeepSeek-V4-Flash` ↔ `deepseek-v4.1-flash`）又没声明别名时，会判 `reported_mismatch`，**每个任务** `MODEL_MISMATCH` + 隔离 worktree。**正确做法是照真实费用档登记 `premium`，再用一次已获授权的 probe 取到上报名并写进 `model_aliases`**；不要为了过关把它登记成 `standard`——那改的是用户声明的真实成本，后续任务会在错误的成本假设下派发 |

   `project register` 会补齐缺省字段（`routing.max_assignments` / `cost_ceiling` / `spend_guard` /
   `use_performance`、`profile.image` 等）并回写文件，所以注册后再看文件比手写时更长，这是正常的。
   `spend_guard` 默认为全 `null`，即不启用——不要顺手填上限：cost 常为 `unavailable`，一填就会
   `SPEND_UNVERIFIABLE` 拒跑。
2. **注册前预检**：`project register --config project.json --dry-run`。它不创建 `state.db`、
   不写 `projects/<id>.json`、不取项目锁；看 `details.errors[]` 与 `warnings[]`——路径不存在、
   无 git 跟踪文件、覆盖整个仓库都只是**提示**，不阻断注册。
3. **注册**：去掉 `--dry-run` 再跑一次。`--config -` 从 stdin 读，此时相对路径按**当前工作
   目录**解析（其余模式按配置文件所在目录）。
4. **准备任务**：`task prepare --project P --spec spec.json`。项目未注册时用 `--repo PATH`：
   按 git 仓库根匹配已注册项目，匹配不到就给出注册草案；多个注册项指同一仓库时报
   `PROJECT_AMBIGUOUS`，不猜。
5. **创建与启动**：`task create --request-file <create.json>` → `task start`。`prepared: true`
   只是本次快照的结论，create/start 会复核；条件变化时报明确诊断，不另存准备状态。

6. **标定模型身份（新 profile 建议做一次）**：`task create` 带 `"purpose": "probe"`（结果
   不进质量统计）→ `start` → `task report TASK` 读 `requested_model` / `reported_model` /
   `reported_models[]` / `model_identity` / `identity_basis`（`scope=request_echo` 是请求名
   回显，不参与判定）。probe 是**真实模型调用**：计费、受 `cost_ceiling` / `spend_guard`
   约束、过模型身份闸门，所以要先按上一节拿到授权，不能以"只是探测"为由替用户发起。
   撞上 `MODEL_MISMATCH` 也能拿到证据（`block_details` 已带 `reported` / `reported_models` /
   `request_echoes` / `declared_aliases`）；`model_aliases` 只在作用域清楚、命名关系有依据、
   且用户确认后才登记，`mixed` 不得整组写入。汇报写"按声明等价"，不写"已证明使用该模型"。

同一项目**只注册一次**：后续任务是 `prepare` → `create` → `start`，不再回到第 1 步。

在目标环境完成前置验证后，先用 disposable 仓库和 `local_artifact` 模式跑通
create→start→status→pause/resume→验证→人工 accept，再开通 publish 权限验证 PR。不先授予
生产、合并或部署权限。镜像验证、模型账号与出口策略需要目标环境提供，本包不能代替这些部署
条件；`zoe demo` 仅作教学演示，不构成执行路径。
