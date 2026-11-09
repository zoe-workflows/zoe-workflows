# 监控手册（按需读取）

`SKILL.md` 第 6 步只保留**每个回合都要用**的判定：启动命令、状态判定表、退出码分流、
续期单、终态核对、四档汇报、三条纪律。本文承接**异常分支与低频语义**——它们一旦误读，
会把"预算到期"读成"完成"、把"没有输出"读成"卡死"，所以写得比主线更细，但不需要每回合读。

## 何时读本文

| 触发 | 读哪节 |
|---|---|
| 要给人看 Agent 在做什么（`--with-log`） | §1 |
| 本回合必须让出，要写续期单 | §2 |
| 每 5 轮进度拍、`changed=N` 看不懂 | §3 |
| 要一版完整摘要或增量摘要 | §4 |
| 退出码 0/10/11 出现但不确定怎么收 | §5 §6 |
| 游标莫名跳过/重复、怀疑脚本行为 | §7 §8 |
| `task logs` 返回为空，怀疑读取有 bug | §9 |
| 会话关闭后还想查 | §10 |
| 宿主没有 bash / jq / pwsh | §11 |

## 1 `--with-log`：给"人看的进展"

`--with-log`（默认关）让每个仍在跑的目标每轮追加"新增的"可读进展：
`[log] T1 说：…` / `[log] T1 动：Edit src/app.py  (过程观察，非成功证据)`。它每轮每目标
只读 `--log-bytes`（默认 8192，上限同 CLI 1048576）字节、最多输出 `--log-lines`
（默认 3）行，用**展示游标**去重（同一条进展不会被重复打印，也不会为"无新增"补一行）；
run 切换或日志回绕就丢弃旧游标重新定位。它**不参与终态判定**：`alive` / `need_human` /
退出码仍只读 `task status`。读取失败只记 `[log-error]`，不计入 `--max-errors`，连续 3 次
自动关闭并打印 `[log-off]`；runtime 太旧（不认 `--after`）时同样自动关闭，其余监控照常。
（PowerShell 同义参数：`-WithLog` / `-LogBytes` / `-LogLines`，判断与输出前缀一致。）
**`[log]` 是过程观察，不是成功证据**：`[log] T1 动：Edit src/config.py` 只说明它动过这个
文件，不代表写成功，更不代表验收通过。

## 2 续期协约的完整算法

`zoe-monitor.sh` 是**有界**的：预算一到就以 `BUDGET_EXHAUSTED` 退出。skill 不承诺
"跨回合持续"，它承诺的是**每次让出都留下可机械执行的续期单**——否则"续接"就变成下一个
回合重新发现一遍。`owner` 三选一（`next-turn-agent` / `host-cron` / `human`）见
`SKILL.md` 6.4；本节是它的算法部分。

1. **反推预算，不要拍上限**：调用前向宿主取本回合剩余秒数，传 `--deadline-in N`。脚本按
   `effective = min(--max-seconds, N - guard)` 反推，并打印
   `[budget] requested=… deadline_in=… effective=…s source=…`；`effective < 45s` 时
   **直接不启动**（一次 status 都跑不完，启动只会留下"运行过"的假象）。
   拿不到宿主预算时用 `--max-seconds 600` 这个保守值，并在汇报里写明"这是假设值，不是测得值"。
2. **续期请求必须可机械执行**：游标 + 完整命令 + 待办队列（动作/对象/依据）。脚本退出时
   已打印 `[renewal] owner=… cursor=… cursor_file=… command="…"`，汇报里**原样贴出**，
   不要改写成"稍后继续监控"。
3. **不要用 `--max-seconds 0`（不限）交回回合**：回合由宿主结束，不由脚本结束；不限预算的
   监控会在最需要收尾的时候被杀掉，连 `[stop]` 都写不出来。

**明确不承诺的事**：会话关闭后没有人会"自动继续监控"——除非 `owner=host-cron` 且调度
任务**已真的创建成功**。没有创建成功时必须写"会话结束后无人监控，恢复入口是 <命令>"，
不能写成"我会继续盯着"。

以上两项（`--deadline-in` / `[renewal]`）目前只在 **POSIX** 实现里；`zoe-monitor.ps1`
尚未同步，Windows 宿主用 `--max-seconds` 保守值并手写续期单。

## 3 `[tick]`、`--tick-content` 与 digest 的关系

**`[tick]` 的 `changed=N`** 是本轮相对上轮的状态指纹变化数（新增任务也算变化），零额外
CLI 调用。要内容时加 `--tick-content`：它在 `[tick]` 之后追加
`[tick-log] changed=N last=…`（`last` 是最后一条可读进展，仍是过程观察，不是成功证据）。
默认关，因为它与 `--with-log` 是同一份日志读取；只给 `--tick-content` 不给 `--with-log`
时只有计数、没有内容（启动时会提示）。该参数目前只在 **POSIX** 实现里。

## 4 digest：一次快照

要一版"给人看的摘要"用 digest，不要手拼 N 条命令。`zoe-monitor.sh` 是连续观察（游标、
退出条件、预算），`zoe-digest.sh` 是一次快照（每任务：状态·阶段·耗时·静默·字节 + 最近
一条文本 + 最近一个动作）：

```bash
# 人读版：默认写 .zoe/P-digest.md，同时打印到 stdout
bash <skill-dir>/scripts/zoe-digest.sh --project P --targets "T1 T2 T3"
# 紧凑版：只读状态，不读日志（任务多或 CLI 慢时用）
bash <skill-dir>/scripts/zoe-digest.sh --project P --no-content
# 机器版：含 hot_paths（同一路径被几个候选触及），用于排波次
bash <skill-dir>/scripts/zoe-digest.sh --project P --json
# 冒烟：只看调用次数，不落文件
bash <skill-dir>/scripts/zoe-digest.sh --project P --targets "T1" --no-out --debug-calls
# 增量：只输出与上次相比变化的任务（无变化时 Markdown 输出 0 行）
bash <skill-dir>/scripts/zoe-digest.sh --project P --since .zoe/P-since.json
```

`--since` 维护一份按任务存指纹的状态文件（状态/阶段/阻断码/`run_id`/候选与已验证 SHA），
只输出**变了**的任务，让"每回合读一版"的成本恒定；无变化时 Markdown 模式是 **0 行**
（`--json` 模式给 `changed: []`——JSON 没有 0 行这个形态）。`--since` 与 `--out` 互斥：
一个是增量片段、一个是完整快照，混用会让同一个文件时而完整、时而只有几行。

边界与 monitor 一致：只读、不推进、不判断终态。成本分两条路（`--debug-calls` 会打印实际
次数，别把回退路径说成 1）：

- runtime ≥ 1.6：脚本内部走 `task digest` 的原生聚合，**1 次**调用；
- 旧 runtime：自动回退到逐任务读取，`1 + 2N` 次（N 个目标；`--no-content` 时 `1 + N`）。

原生可用时也可以直接调 `zoe task digest --project P --json`（字段与脚本 `--json` 同构，
含 `hot_paths` 与 `note`），把渲染留给自己。目标超过 20 个先用 `--no-content`。
输出里的 `说：` / `动：` 同样只是过程观察；`REVIEW_READY`、`empty_candidate`、
`SCOPE_VIOLATION` 都是**原样转述字段**，digest 不重新解释。
退出码：`0` 生成成功（个别目标读不到只告警）、`2` 用法/依赖错误或项目内没有活跃任务、
`11` 全部目标状态不可读。

## 5 `[stop] reason` 与 `--stop-file`

**`[stop] reason=…` 是唯一允许被引用的"结束原因"**（与退出码并存，不改变退出码）：
`ALL_TERMINAL` 可以进入汇报，但仍需 `task report` 的验收结论；`BUDGET_EXHAUSTED`
**不是完成**，带 `next_cursor` 续跑；`HUMAN_REQUIRED` 逐个人工处理项；
`WATCH_ERROR` / `DEPENDENCY_ERROR` 说明监控本身不可用，不是任务失败。预算用
`--max-seconds`（单调时钟，与 `--max-rounds` 先到者生效）；能拿到宿主预算时改用
`--deadline-in N`，脚本按 `min(N-guard, max-seconds)` 反推并打印 `[budget]` 行。
`--stop-file F` 把
`{monitor_stop_reason, all_terminal, next_cursor, rounds, elapsed_seconds, empty_candidates}`
写成 JSON（PowerShell 同义参数：`-MaxSeconds` / `-StopFile`；`--deadline-in` /
`[renewal]` 目前仅 POSIX 实现）。`BUDGET_EXHAUSTED` / `HUMAN_REQUIRED` / `WATCH_ERROR`
退出时还会打印 `[renewal] owner=… cursor=… command="…"`：**这是续期单，不是建议**。

脚本要点（`scripts/zoe-monitor.sh`）：游标先读后写（重启不跳过停机期间事件）；事件
先落盘再推进游标；`alive==0` 且有人需介入时 `exit 10` 而不是空转；`watch` 连续失败
到上限 `exit 11` 而不是把"读不到"当"还在跑"；每轮一行 `[tick]` 证明"仍在监控"。
`[tick]` 现在带 `phases=<task>:<phase>,…` 与 `runs=<task>:<run>,…`：**阶段长时间不变是
正常的**（`implement` 可以跑 40 分钟），"阶段没变 ≠ 卡住"——否则只是把"字节数没涨"的
误读换成"阶段没动"的误读。行末还有 `quiet=<task>:<秒>`：本批**静默最久**的仍在跑目标。
它是展示列，不参与 `alive` / `need_human` / 退出码；`quiet=none` 表示本轮没读到任何
quiet 值（旧运行器或 `progress` 缺失），**不是**"没有静默"。

## 6 空候选 `empty_diff=true`

表示这次没有任何可交付改动：监控在 `REVIEW_READY` 时比对 `candidate_sha` 与 `base_sha`
（或直接读运行时的 `empty_candidate`），相等就打印
`[needs-human] T empty_diff=true（candidate_sha == base_sha）无改动可验收`，并把任务写进
`empty_candidates`。它仍算"等人工验收"（退出码不变），但**汇报里不能写"已完成"**：
零改动的证据里那些 PASS 只说明基线本来就能过。`accept` 会通过（`subject_sha` 与
`validated_sha` 都等于 `base_sha`），那是运行时的空洞，不是授权——处置见
[delivery-policy.md](delivery-policy.md) 的「空候选」。

## 7 游标语义边界

`next_cursor` 是"已扫描"位置，不是"已匹配"位置；项目过滤下它会越过其他项目的事件，
所以只承诺"游标单调前进"，不承诺"同一区间不会被重复扫描"。

- 续接游标：**有界查询**用末尾 meta 行的 `next_cursor`（形如 `<epoch>:<event_id>`）；
  **`--follow` 也回传游标**——首行 `{"kind":"meta","event":"follow_start","cursor":…}`，
  末行 `{"kind":"meta","event":"follow_end","next_cursor":…}` 可直接用于下一轮 `--after`
  （`cursor_expired` 分支同样带 `next_cursor`）。事件行本身不带游标语义，不要把事件
  `id` 拼成游标。`cursor_expired` 只表示 epoch 变了（状态库迁移/恢复），不当成任务失败。

## 8 多任务事件流过滤

`--project` / `--group` / `--task` 三个过滤取交集，且会校验归属（`--task` 不属于该
project 会直接报 `PROJECT_MISMATCH`，**不会**静默返回空）。旧事件靠任务行/组行回查归属，
无法归属的计入 `unattributed`。

## 9 动作线：`task logs` 判读

**要看 Agent 在做什么，用动作线**（与状态线并行，不替代它）。先记三条事实（见
`SKILL.md` 6.6）：`--follow` 不带 `--tail-bytes` 时从当前末尾开始；只有 `kind=text` 与
`kind=tool` 算可读进展；日志行按字节定界，投影只吃完整行。

```bash
# 看"最近发生了什么"（快照 + 投影，非阻塞）
bash <skill-dir>/scripts/zoe.sh task logs TASK --tail-bytes 65536 --json
# 从断点继续看新增（非阻塞，用上一次的 cursor）
bash <skill-dir>/scripts/zoe.sh task logs TASK --after "<cursor>" --json
# 从现在开始持续跟（默认语义：不看历史）
bash <skill-dir>/scripts/zoe.sh task logs TASK --follow --timeout 60 --projection auto
# 回看一小段后再跟
bash <skill-dir>/scripts/zoe.sh task logs TASK --follow --tail-bytes 65536 --projection auto
```

**`task logs` 没有 `--project`**（那是 `watch` 的），也**没有 `--jsonl`**（`--follow`
本身就是一行一个 JSON）。`--cursor` 与 `--tail-bytes` 同时出现时 cursor 优先。
静默只说明"这段时间没有完整记录产生"，不是失败，也不是卡死。不指定 `--run` 时首次会
打印实际 run_id 并固定它——换 run 必须显式给 `--run` 或 `--cursor`；换 `--log`
（如 `agent` → `check-build`）必须丢弃旧游标：游标只编码 `run/generation/offset`，
无法自证来自哪个日志文件，这条只能靠调用方遵守。

**`text`/`events` 同时为空时先读 `empty_reason` 再下结论，不要报"日志读取有 bug"**
（`empty_reason` 是 v1.5.3 起的字段；旧版本没有它时按下表自己判）：

| `empty_reason` | 判据 | 含义 | 动作 |
|---|---|---|---|
| `rotated` | `rotated: true` | 游标 offset 超过了文件大小（日志被截断/替换） | 用 `reset_cursor` 重新定位；这是正常现象，不是没输出 |
| `no_newline_in_window` | `tail_start_offset == bytes` | 尾部窗口整段落在同一记录里（单条 > 窗口） | 加大 `--tail-bytes`（上限 1048576）或 `--after run:generation:0` |
| `no_complete_line` | `text` 非空、`events` 为空 | 窗口里只有半行/空行 | 真的没有新的**完整**记录，继续等 |
| `no_new_records` | 带 `--after` | 游标之后没有新记录（已追平） | 心跳，正常，继续轮询 |
| `null` | 有内容 | — | — |

`bytes` 是**文件总大小**，不是本次读到的字节数；`text` 是窗口原文，不是投影结果。
这也是为什么"`bytes` 很大却 `text` 为空"不等于读取失败：先看 `rotated`。

## 10 会话之外：`zoe-watchd.sh`

`zoe-monitor.sh` 是前台有界循环，回合结束即消失。`zoe-watchd.sh` 是脱离会话的**只读**
守护，把观测事实持续落到 `live.jsonl`（只在变化时追加一行）与 `live.md`（覆盖快照）：

```bash
bash <skill-dir>/scripts/zoe-watchd.sh start  --project P --interval 15 --max-seconds 3600
bash <skill-dir>/scripts/zoe-watchd.sh status --project P --json
bash <skill-dir>/scripts/zoe-watchd.sh stop   --project P
```

三条边界：① **只读**——脚本内部拦截 `start/resume/accept/pause/cancel/group *`，调用即
`exit 70`；它一旦能派发就成了第二个写者，破坏"同一任务同一时刻一个写者"；② **不替代
合并**——它只说"谁的状态变了"，审 diff、跑 checks、解冲突仍要判断力；③ **能停**——
`stop` 先写 `stop.request`，超时才 TERM→KILL；pid 锁陈旧（进程不在了但锁还在）会在下一次
`start` 自动接管。守护发现 `QUOTA_EXHAUSTED` 时在 `live.md` 写 `## quota_blocked` 并给出
`project quota clear`——**不会**给 `resume` 建议。
**它只记录、不推进**：无人时真正做事需要宿主定时任务（平台能力），skill 只能把请求体
准备好，不能假装自己会在会话结束后醒来。

## 11 宿主侧等价协议

Windows 无 `pwsh`、或脚本本身不可用时：`watch --project P --jsonl --after <cursor>
--max-events 200` 取事件并记录 `next_cursor` + `task status --refresh` 取权威状态，按
`SKILL.md` 6.3 的表分流。**同一套语义，换实现不换判断。** 禁止把
`sleep N && task status` 当主循环（没有游标、没有"需人工介入即停"、没有 `[tick]` liveness），
它只在 `watch` 不可用时兜底，且兜底时仍要自维护游标与同样的结束条件。
