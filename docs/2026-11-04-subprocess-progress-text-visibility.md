# 子进程执行进展的可读化（评估 + 实现方案 v2）

| 项 | 内容 |
|---|---|
| 日期 | 2026-11-04 |
| 输入 | ①「只能拿到进度数字，拿不到子进程在做什么的文字」；② 对 v1 方案的评审（10 条验收门槛 + 6 处设计修正） |
| 被评估对象 | `zoe-runtime@1.5.1`（`_logstream` / `task logs` / `_progress` / `_backend` / `cli`）；`zoe-workflows`（`scripts/zoe-monitor.*`、`SKILL.md`、`runtime-requirements.json`） |
| 与上一份文档的关系 | 同轮《并行批次派发的摩擦收敛》S4 只保证了"监控只有一条事实来源"；本文补那条来源里缺的**文字线**，不改变 S4 的判定 |
| 方法 | 评审提出的每处修正先回到源码取证（默认值、读取路径、投影行为、cursor 语义），能复现的写成反例；不能复现的标注"未实测" |
| 本文位置 | `zoe-workflows/docs/`（不进入发布包） |

## 修订记录

| 版本 | 变化 |
|---|---|
| v1 | 四层根因 + S8-A～S8-E 初版；主张 A 必做、B 同批、C 不做 |
| **v2** | 按评审修正 8 处，其中 3 处是**会让实现"测试过但线上坏"的缺陷**：<br>① **`--tail-bytes` 的默认值陷阱**：parser 默认 `65536`，v1 用 `args.tail_bytes > 0` 判断"是否回看"⇒ 不带参数的 `--follow` 也会回看 64KB。改为 `default=None` + 显式性判断（§1.3 / S8-C）<br>② **快照仍全量读文件**：v1 保留 `raw = path.read_bytes()` 再切片，500 MiB 日志下每轮多任务读满全文件。改为 `stat` + `seek/read` 有界窗口（§1.2 / S8-D）<br>③ **先解码再切行**：v1 用 `text.split("\n", 1)` 推导字节游标，多字节字符与半行场景都不可靠。改为**字节级**定界、再解码（§1.2 / S8-D）<br>④ **行边界方向**：v1 的 `_line_start` 向前回溯，最坏回溯不可控；改为**向后对齐**（跳过不足一行的头部）+ 边界已对齐时保留当前行（S8-C）<br>⑤ **事件截断取错端**：v1 的 `events[:MAX]` 丢掉最近的记录；改为 `events[-MAX:]`，并把三种截断拆成三个字段（S8-D）<br>⑥ **`--with-log` 会反复回放同一条**：v1 每轮取尾部 N 条 ⇒ 同一条进展被重复打印，制造假进展。改为每个 `(task, run)` 的**展示游标**，并新增 `--after` 让读取非阻塞（S8-B2 / S8-D）<br>⑦ **补一致性不变量**：快照与 follow 对同一字节区间必须产出同一事件序列；v1 未定义，且**空行行为两边不一致**（§1.4）<br>⑧ **S8-E 判据加严**：出现一条 `kind=text` 不能证明覆盖完整，改为三阶段探测 + 覆盖率指标（S8-E） |
| **v2.1（定稿）** | **决策落定：新增 CLI 选项 `task logs --after <cursor>`**（不新增子命令）。S8-D-2 从"可选"转为 **P0 必做**，并给出对外契约（参数、优先级、校验、错误码、响应字段、与 `task events --after` 的消歧）见 §2.1；`--with-log` 的非阻塞实现改为唯一路径，删去"阻塞式 follow"备选 |

---

## 0. 结论

### 0.1 评审决策的采纳

| 决策项 | 评审结论 | 本文处理 |
|---|---|---|
| B（S8-C / S8-D）是否并入本轮 | 并入 | 采纳；同时把 v1 的三处实现缺陷（全量读、解码后切行、默认值陷阱）列为**前置条件**，不修不得开工 |
| S8-E 是否实施 | 先探测按证据决定 | 采纳，且判据从"出现一条 text"改为"逐类覆盖率"；数据不足记 `NOT_VERIFIED` |
| 任务范围 | P0：A/B1/C/D；P1：B2；条件：E | 采纳，见 0.2 |
| 不新增 S8-F/G | 不扩功能 | 采纳；S8-D 新增的 `--after` 属于"统一窗口读取"的组成部分，单列为 S8-D-2，不算新功能项 |
| 是否新增 CLI 表面 | v2 留待确认 | **已决：新增 1 个选项**（`task logs --after <cursor>`），**不新增子命令**；对外契约见 §2.1 |

### 0.2 最终实施范围

| 模块 | 范围 | 优先级 |
|---|---|---|
| S8-A | `SKILL.md` + `cli-contract.md`：用**最终生效**的回看命令写协议（含"不带参数仍从 EOF"） | P0 |
| S8-B1 | `zoe-monitor.*` 的 `[tick]` 带 `phase` 与 `run` 标识 | P0 |
| S8-C | `--follow` 支持显式 tail 窗口；**默认语义不变** | P0 |
| S8-D-1 | 快照：有界读取 + 字节级完整行 + cursor 对齐 + 三截断分账 | P0 |
| S8-D-2 | **新增 CLI 选项** `task logs --after <cursor>`：有界增量读（对外契约 §D-2-a），也是 `--with-log` 的唯一非阻塞路径 | P0（已定稿，B2 的前置） |
| S8-B2 | `--with-log`：展示游标去重、失败隔离、不参与终态判定、跨平台一致 | P1（同批） |
| S8-E | 真实日志三阶段探测，只补被证明遗漏的形状 | 条件实施 |

### 0.3 一句话目标

> 通过统一 CLI 可靠观察「当前阶段 / 最近可读动作 / 新增日志」，同时**不把日志内容当成完成证据**，也不改变 `progress.json`、状态、事件、验证证据各自的职责边界。

---

## 1. 事实核对

### 1.1 文字确实在日志里

| 事实 | 证据 |
|---|---|
| stderr 与 stdout 合并进同一日志 | `LocalProcess._do_launch()` 传 `stdout=self._logfile`；POSIX `spawn()` 里 `stderr=subprocess.STDOUT`（Windows 实现同语义） |
| 该 CLI 逐行输出 | codebuddy 适配器固定 `-p --output-format stream-json`；源码注释记录实测"`stream-json` 逐行输出，运行期间可观察；`json` 会憋到退出（60s 内 0 字节）" |
| 日志路径 | `runs/<run_id>/agent.log`（检查用 `check-<id>.log`，`--log` 可选） |

结论：没有"落盘丢文字"的问题，缺陷全在**读取侧**（窗口、边界、投影、调用编排）。

### 1.2 快照模式的三个缺陷（评审全部命中，已核到代码行）

`_task_logs()` 现状：

```python
raw = path.read_bytes()                       # ① 全量读：O(文件大小)，与 tail_bytes 无关
tail = raw[-args.tail_bytes:]
...
"text": redact_secrets(tail.decode("utf-8", "replace")),   # ② 先解码，再用字符串做事
"truncated": len(raw) > len(tail),
"cursor": _logstream.format_cursor(run_id, 1, len(raw)),   # ③ 指向 EOF，可能落在半行
```

| # | 缺陷 | 后果 | v2 修正 |
|---|---|---|---|
| ① | `read_bytes()` 全量读 | 500 MiB 日志 + 3 个目标并行监控 ⇒ 每轮读 1.5 GiB 才能返回 64 KiB | `stat().st_size` + `seek/read` 窗口（S8-D-1） |
| ② | 先解码再切分 | 窗口起点落在多字节字符中间时产生替换字符；字符串下标与字节 offset 不可换算 | 字节级定界 → 再逐行解码（S8-D-1） |
| ③ | cursor = `len(raw)` | 文件正在写时 cursor 落在半行；续读首行是残片（`project_line` 解析失败降级 `raw`） | `complete_offset()` 取最后一条完整记录的末尾（S8-D-1） |

补充事实：`path.read_bytes()` 也没有大小上限，`--tail-bytes` 的校验（`1..1048576`）只约束返回值，不约束读入量。

### 1.3 `--follow` 的三个事实（含评审指出的默认值陷阱）

```python
# parser
a.add_argument("--tail-bytes", type=int, default=65536, ...)   # ← 默认值是 65536
# _logs_follow
if offset is None:
    offset = path.stat().st_size      # 无 cursor ⇒ 从 EOF 开始；--tail-bytes 被完全忽略
```

| 事实 | 含义 |
|---|---|
| `--follow` 无 cursor 从 EOF 起 | 中途接入看不到历史（v1 已记录） |
| `--tail-bytes` 在 follow 下**不生效** | 宿主的 `--tail-bytes 65536` 静默无效（选项存在、语义不存在） |
| **默认值是 `65536` 而非 `None`** | 若按 v1 的 `window = args.tail_bytes` 实现，**所有不带参数的 `--follow` 都会回看 64 KiB** —— 这不是"显式参数从无效变有效"，而是默认行为变更。评审的判断成立 |

因此 S8-C 的前置改动是 parser：`default=None`，并在快照分支内部回落 `DEFAULT_TAIL_BYTES = 65536`（快照行为完全不变）。校验 `1..1048576` 移到"解析后的有效值"上。

### 1.4 投影层的空行行为（一致性不变量的真实绊脚点）

`LogFollower._take_lines()` 把每个 `\n` 之前的字节都当作一行（不跳过空行），`_logs_follow` 对每行调 `project_line()`；而 `project_line("")` 返回 `[{"kind":"raw","text":""}]`。

因此：**follow 会为空行产出空 `raw` 事件**。v1 的快照伪代码 `if line.strip()` 又跳过空行 —— 两个接口在同一区间上的事件数必然不同。这正是不变量要先解决的空洞：不是"算法可能不同"，而是"规则现在就不同"。

v2 的处理：抽出 `project_complete_lines()` 一并供两处调用，**统一跳过空行**。这是行为变更（follow 不再输出空 `raw`），需回归测试 + 发布说明。

### 1.5 投影只认一种形状；未知字段被丢弃（也是脱敏面）

| 输入形状 | 现状输出 |
|---|---|
| `message.content[]` 的 `text` / `tool_use` / `tool_result` | `kind=text` / `tool` / `tool_result` |
| `type=result` / `type=system` | `kind=result` / `init` |
| 扁平 `{"type":"assistant","text":"…"}`、`delta.*`、`choices[].delta.content` | **`kind=record`，文字丢弃** |
| 非 JSON 行 | `kind=raw`（脱敏后） |

两点必须写清：

1. **未知字段不会被原样打印**：`project_record()` 对未识别形状只保留 `type`，其余字段直接丢弃 ⇒ 不存在"借 `record` 绕过长度/脱敏限制"的通道（`_redact_tree` 仍对已输出字段逐字符串脱敏）。
2. **形状是否覆盖只能靠真实日志判定**：现存单测里唯一涉及扁平形状的用例走的是 `parse_output`，不覆盖投影 ⇒ 现有测试无法回答"该 CLI 是否被覆盖"（S8-E 的存在理由）。

### 1.6 `progress.json` 的边界（以及一个可复用的字段）

模块声明只回答「有没有新输出」与「何时观测到」，拒绝回答「是否健康」；双节流（默认 10s ∧ 8 KiB）；不写状态库、不发事件、阈值走宿主环境变量（避免改动 `policy_digest` 触发 `POLICY_CHANGED`）。

顺带一个可用事实：`progress.json` 里有 `log_generation`。快照现在的 cursor 硬编码 generation=1，日志轮转后即失真；v2 让快照优先读 `progress.json.log_generation`，读不到才用 1。

### 1.7 监控脚本现状

`[tick] round=… cur=… alive=… need_human=… human=…`：**没有 `phase`、没有 run 标识、从不读日志**。而事件载荷里本来就有 `state`/`phase`/`block_code`/`run_id`（`_store.save()` 统一写入）⇒ "阶段"这条信息在手边，只是没摘出来。

---

## 2. 方案

### S8-A 文档：把"读进展"写成可执行协议（P0，0.4）

**落点**：`SKILL.md` 第 6 步动作线；`references/cli-contract.md` 的 `task logs` 条目（新参数在 S8-C/D 就位后再写进 ```text 块——契约测试要求文档里的命令/选项真实存在）。

**契约（先写清选项矩阵，再给例子）**：

| 调用 | 行为 |
|---|---|
| `task logs T` | 快照：最近 64 KiB 窗口内的完整记录（默认值不变） |
| `task logs T --tail-bytes N` | 快照：最近 N 字节窗口 |
| `task logs T --after C` | 快照增量：`[C, C+tail_bytes)` 的完整记录，`has_more` 表示还有。**`C` 是日志游标 `run:gen:offset`，不是 `task events --after` 的整数事件 id**（两者同名不同物，文档必须点明） |
| `task logs T --follow` | 从**当前 EOF** 开始跟随（默认语义，不变） |
| `task logs T --follow --tail-bytes N` | 回看最近 N 字节内的完整记录后继续跟随 |
| `task logs T --follow --cursor C` | 从 cursor 继续；**cursor 优先，`--tail-bytes` 被忽略**（文档必须写） |

**改法（替换第 6 步动作线段落，含嵌套代码块，用四反引号围栏）**：

````text
- **要看 Agent 在做什么，用动作线**（与状态线并行，不替代它）。先记三条事实：

  1. `--follow` 不带 `--tail-bytes` 时**从当前末尾**开始：中途接入看不到之前的进展；
  2. `--projection auto` 只有 `kind=text`（说了什么）与 `kind=tool`（动了什么）
     算可读进展；`kind=record` = "认出了信封但没认出内容"，`kind=raw` = "这行
     不是结构化记录"。两者都**不是**"没有输出"；
  3. 日志行按字界定界：投影只吃**完整行**。尾部半行只留在 `text` 里供排障。

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
  静默只说明"这段时间没有完整记录产生"，不是失败，也不是卡死。
````

**判错**：文档写"`--follow` 能看到之前的进展"（未带 `--tail-bytes`）；把 `kind=record` 解释成"没有输出"；给 `task logs` 写 `--project` / `--jsonl`。

### S8-B1 监控：`[tick]` 带阶段与 run（P0，0.1）

```bash
row=$("$ZOE_BIN" task status "$t" --json 2>/dev/null \
    | jq -r '"\(.state // "")\t\(.block_code // "")\t\(.phase // "")\t\(.current_run_id // "")"')
```

`[tick]` 追加 `phases=<task>:<phase>,…`。**必须同时写进文档**：阶段长时间不变是正常的（`implement` 可以跑 40 分钟），"阶段没变 ≠ 卡住"——否则只是把"字节数没涨"的误读换成"阶段没动"的误读。

### S8-C `--follow` 支持显式窗口（P0，0.4）

**三个前置修正**（缺一不可）：

1. parser 改 `default=None`，快照侧回落 `DEFAULT_TAIL_BYTES`；校验针对解析后的有效值；
2. 行边界改为**向后对齐**：跳过不足一行的头部，窗口不超过 N 字节（评审建议）；
3. `--cursor` 显式给出时忽略 `--tail-bytes`，并在 help 与文档里写明。

**共享实现（放 `_logstream.py`，S8-D 复用）**：

```python
DEFAULT_TAIL_BYTES = 65536
MAX_TAIL_BYTES = 1024 * 1024

def window_start(path, size: int, window: int) -> int:
    """返回窗口内第一条**完整记录**的绝对字节起点。

    评审口径（v2）：从不超过最近 ``window`` 字节的位置开始，跳过不足一行的头部。
    与"向前回溯到上一个换行"相比，这里最多读取 ``window`` 字节，回溯长度天然有界。
    """
    if size <= 0:
        return 0
    if window <= 0:
        return size                      # 空窗口
    start = max(0, size - window)
    if start == 0:
        return 0
    with open(path, "rb") as fh:
        fh.seek(start - 1)
        if fh.read(1) == b"\n":
            return start                 # 已位于行边界：保留当前行，不得跳到下一行
        fh.seek(start)
        probe = fh.read(min(window, size - start))
    index = probe.find(b"\n")
    return size if index < 0 else start + index + 1


def complete_offset(data: bytes, base: int) -> int:
    """``data``（自 ``base`` 起）中最后一条完整记录的结束位置。"""
    index = data.rfind(b"\n")
    return base + index + 1 if index >= 0 else base
```

`_logs_follow` 的 offset 解析改为：

```python
    if offset is None:
        size = path.stat().st_size
        # 显式给 --tail-bytes 才回看；缺省（None）维持"从现在开始"的原语义。
        window = getattr(args, "tail_bytes", None)
        offset = window_start(path, size, int(window)) if window else size
```

**验收要点**：`--tail-bytes` 不大于窗口时不得回退到文件头；窗口内没有换行时返回 EOF（空结果，而不是读全文件）。

### S8-D 快照：有界读取 + 字节级完整行 + 一致性（P0，0.8）

#### D-1 读取与定界

```python
def read_window(path, start: int, length: int) -> bytes:
    """有界读取：不加载整个日志。"""
    if length <= 0:
        return b""
    with open(path, "rb") as fh:
        fh.seek(start)
        return fh.read(length)


def project_complete_lines(data: bytes, base: int, projection: str) -> tuple[list[dict], int]:
    """按字节定界 → 逐行解码 → 投影；返回 ``(events, complete_end)``。

    只有完整行参与投影：尾部半行留在 ``text`` 里供排障，不生成事件。
    空行统一跳过（follow 侧同样调用本函数，见 §1.4 的行为变更）。
    """
    events: list[dict] = []
    end = base
    for raw_line in data.split(b"\n")[:-1]:          # 最后一段没有 \n ⇒ 不完整
        end += len(raw_line) + 1
        text = raw_line.decode("utf-8", "replace")
        if text.strip():
            events.extend(project_line(text, projection))
    return events, end
```

`_task_logs` 改为：

```python
    size = path.stat().st_size
    window = args.tail_bytes if args.tail_bytes is not None else DEFAULT_TAIL_BYTES
    require(1 <= window <= MAX_TAIL_BYTES, "INPUT_INCOMPLETE", "tail-bytes must be 1..1048576")

    after = parse_cursor(getattr(args, "after", None))            # S8-D-2，可缺省
    if after is not None and after[0] != run_id:
        raise Error("PROJECT_MISMATCH", "cursor belongs to another run",
                    details={"cursor_run": after[0], "run_id": run_id})
    if after is not None:
        start = after[2] if after[2] <= size else 0               # 回绕/截断 ⇒ 重新定位
        if start != after[2]:
            reset = True
    else:
        start, reset = window_start(path, size, window), False

    data = read_window(path, start, min(window, size - start))
    events, complete_end = project_complete_lines(data, start, args.projection)
    generation = _log_generation(store, t, run_id)                 # progress.json，读不到用 1
    cursor = _logstream.format_cursor(run_id, generation, complete_end)
```

#### D-2 `--after`：非阻塞增量（`--with-log` 的基础）

| 字段 | 含义 |
|---|---|
| `--after <cursor>` | 左边界由 cursor 决定；窗口上限仍是 `tail_bytes`（默认 64 KiB） |
| `has_more` | `complete_end < size` 时为真：宿主带新 cursor 继续 |
| `cursor` / `next_cursor` | 均为"本次窗口最后一条完整记录之后"的绝对位置；`cursor` 保留旧名以兼容 |
| `rotated` | `after.offset > size`（日志被截断/替换）时为真，同时给 `reset_cursor`（= 空窗口的新 cursor） |

`--after` 的偏移若不是行边界，**向后对齐**（与 `window_start` 同规则），不回溯。

#### D-2-a 对外契约：`task logs --after`（v2.1 定稿）

**参数定义**

| 项 | 值 |
|---|---|
| 选项 | `--after <cursor>` |
| 值形状 | `run:<generation>:<offset>`，与 `--follow` 输出的 `cursor` / `next_cursor` **完全同构**（可直接回填） |
| 默认 | 无（缺省 = 按 `--tail-bytes` 的最近窗口） |
| 作用模式 | **仅快照模式**（不带 `--follow`） |
| 与 `--follow` 同用 | **用法错误**：`INPUT_INCOMPLETE` + `details.field="after"`，提示"快照用 `--after`，跟信用 `--cursor`"。禁止静默忽略——否则用户以为在看历史，实际在看实时 |
| 与 `--tail-bytes` | `--after` 定左边界，`--tail-bytes` 定**窗口上限**（默认 65536）；两者叠加时窗口再大也不会越过 `tail_bytes`。**偏差（§8.2，已接受见 §8.4）**：当窗口内一条完整记录都放不下时，实现会延伸到该记录结束（硬上限 256 KiB），否则小窗口在大记录上永远不推进 |
| 与 `--run` | cursor 内的 `run` 必须与 `--run`（缺省 `current_run_id`）一致，否则 `PROJECT_MISMATCH` |
| 与 `--log` | **游标与日志名绑定**：换 `--log`（如 `agent` → `check-build`）必须丢弃旧游标。cursor 只编码 `run/generation/offset`，无法自证来自哪个日志文件 —— 这条只能靠调用方遵守，文档与脚本注释都要写明 |
| help 文案 | `--after CURSOR  从该游标继续读快照（形状 run:gen:offset，与 --follow 的 cursor 同构；不能与 --follow 同用）` |

**校验与错误码**

| 情形 | 返回 |
|---|---|
| cursor 形状非法（段数/非整数） | `INPUT_INCOMPLETE`，`details.field="after"`，`reason` 给期望形状 |
| cursor 的 run ≠ 本次读取的 run | `PROJECT_MISMATCH`，`details={"cursor_run":…,"run_id":…}` |
| `offset > 文件大小`（日志被截断/替换） | **不报错**：`rotated: true` + `reset_cursor` + 空 `events`（截断是正常现象，不该让调用方以为出错） |
| `tail-bytes` 越界 | `INPUT_INCOMPLETE`（`1..1048576`） |
| `--after` 与 `--follow` 同用 | `INPUT_INCOMPLETE`（见上表） |

**响应字段（旧字段全部保留，新增为增量）**

| 字段 | 类型 | 说明 |
|---|---|---|
| `log` / `run_id` / `text` | 旧 | 不变 |
| `bytes` | 旧 | 文件总大小（仍为全量真值，不因窗口变小） |
| `truncated` | 旧 | **字节窗口**截断（左侧还有更早记录） |
| `cursor` / `next_cursor` | 旧/新 | 本次窗口最后一条完整记录之后的绝对位置；两者同值，`cursor` 为兼容保留 |
| `tail_start_offset` | 新 | 本次窗口的真实字节起点（不随 `events` 裁剪变化） |
| `events` | 新 | 投影后的事件（最多 `MAX_SNAPSHOT_EVENTS` 条，**保留最近**） |
| `events_truncated` | 新 | 事件数量截断 |
| `has_more` | 新 | 仅 `--after` 时给：`complete_end < size`，调用方带新 cursor 继续。**偏差（§8.2，已接受见 §8.4）**：实现另加 `complete_end > start`，否则"这一页没拿到任何完整记录"会一直答 `true` 而游标不动（原地死循环） |
| `rotated` / `reset_cursor` | 新 | 日志回绕/替换时的重置指引 |
| `projection` | 新 | 实际使用的投影模式 |

**为什么是选项而不是新子命令**

1. 职责归属：这是"读日志"的一种窗口方式，不是新能力域；拆成 `task activity` 会与 `task logs` / `progress.json` 形成**第二事实源**；
2. 命令面：`cli-contract.md` 的每个命令都要在 parser 里可解析并被文档覆盖，新增子命令会让 help、契约测试、Skill 文档三处同时分叉；
3. 与评审"不新增 S8-F/G"一致：`--after` 是 S8-D "统一窗口读取"的对外出口，不是新功能项。

**落位与门禁**

- `cli-contract.md` 的 ```text 块里**必须等 parser 就位后**才能出现 `--after`（契约测试会解析该块并校验选项存在，提前写会红）；
- `SKILL.md` 的示例同步（S8-A 已按最终形态写好）；
- 新增单测覆盖：形状非法 / run 不匹配 / 回绕 / `--follow` 同用 / `has_more` 续读。

#### D-3 三种截断分账（评审第 2 条修正）

| 字段 | 含义 | 来源 |
|---|---|---|
| `truncated`（保留旧名） | **字节窗口**截断：左侧还有更早的记录 | `start > 0` |
| `events_truncated` | **事件数量**截断：窗口内完整记录超过上限 | `len(events) > MAX_SNAPSHOT_EVENTS` |
| 每条事件上的 `clipped`（新增可选字段） | **单条内容**截断：文本命中投影层 400 字上限 | `_clip` 内标记 |

```python
        "events": events[-MAX_SNAPSHOT_EVENTS:],      # 取最近，不取最早
        "events_truncated": len(events) > MAX_SNAPSHOT_EVENTS,
        "tail_start_offset": start,                   # 始终是真实字节起点，不随事件裁剪变化
```

`tail_start_offset` 的语义独立于 `events` 长度：即使只保留最后 200 条，它仍指窗口的字节起点。

#### D-4 一致性不变量（评审第 3 条要求，必须进契约测试）

> 同一 run、同一字节区间 `[a, b)`（`a`/`b` 均为完整记录边界）、同一 projection、同一脱敏配置下：
> `snapshot(a,b).events == follow(a→b).events`，逐条相等（JSON 序列化后逐字节比较）。

三个前提必须写进测试名与文档：

1. 单条记录不超过 `MAX_LINE_BYTES`（64 KiB）。超长行 follow 会切成"截断片段 + 后续片段"，快照按物理行处理 ⇒ 该前提下两者不可比，测试显式声明例外；
2. 区间端点落在完整记录边界（半行不参与）；
3. `projection` 相同（`auto` vs `events` 的输出本来就不同，分别比较）。

### S8-B2 `--with-log`：去重、失败隔离、不参与判定（P1，0.5）

**为什么必须去重**：v1 的"每轮取尾部 N 条"在 30 秒输出一次、5 秒轮询一次的场景下会把同一条进展打印 6 次——那是**假的进展感**，而上层 Agent 会据此认为任务在推进。

**实现（`zoe-monitor.sh`，POSIX 可移植，不依赖 bash4 关联数组）**：

```text
--with-log              每个仍在跑的目标，每轮追加新增的可读进展（默认关）
--log-bytes N           单轮读取窗口，默认 8192（上限同 CLI：1048576）
--log-lines N           每轮每目标最多输出行数，默认 3
```

```bash
LOG_STATE=$(mktemp -d)          # 进程内展示游标：退出即丢弃，不写任务状态库
trap 'rm -rf "$LOG_STATE"' EXIT

emit_log() {                    # $1=task
  local curf="$LOG_STATE/$1.cursor" cur=""
  [ -f "$curf" ] && cur=$(cat "$curf")
  local out
  if out=$("$ZOE_BIN" task logs "$1" --log agent --json \
             ${cur:+--after "$cur"} --tail-bytes "$LOG_BYTES" 2>/dev/null); then
    # 只有解析成功才推进游标；读取失败绝不当成"没有新日志"
    printf '%s' "$out" | jq -e . >/dev/null 2>&1 || return 0
    printf '%s' "$out" | jq -r --arg t "$1" --argjson n "$LOG_LINES" '
        .events[]? | select(.kind=="text" or .kind=="tool")
        | (if .kind=="text" then "[log] \($t) 说：\(.text)"
           else "[log] \($t) 动：\(.name) \(.target // "")  (过程观察，非成功证据)" end)' \
      | tail -n "$LOG_LINES"
    printf '%s' "$out" | jq -r '.next_cursor // empty' >"$curf"
  else
    LOG_ERRORS=$((LOG_ERRORS + 1))
    [ "$LOG_ERRORS" -ge 3 ] && { WITH_LOG=0; log "[log-off] 日志读取连续失败，已关闭 --with-log"; }
    log "[log-error] $1 读取失败（不影响监控与退出码）"
  fi
}
```

规则（必须写进脚本注释与文档）：

1. **只展示新增**：首次运行无游标 ⇒ 展示窗口尾部一次；此后只输出新事件；无新事件时**不输出**任何 `[log]` 行（不补"（无输出）"）；
2. **run 切换 / 日志截断 ⇒ 重新定位**：`rotated` 为真或 cursor 的 `run_id` 与 `current_run_id` 不一致时，丢弃旧游标、按窗口重新初始化；
3. **失败隔离**：读取失败只记 `[log-error]`，不计入 `--max-errors`（那是 `watch` 的预算）、不改变退出码、连续 3 次自动关闭 `--with-log`；
4. **不参与终态判定**：`alive` / `need_human` / 退出码仍只看 `task status`；
5. **成本上界**：每轮每目标 1 次 CLI 调用 + ≤ `LOG_BYTES` 字节读取；目标多时应增大 `--interval`，而不是缩小窗口。

`.ps1` 同语义：相同参数名、相同 `[log]` 前缀、`ConvertFrom-Json` 解析、UTF-8 输出；**不得只跑 bash 测试就推断两者一致**（Windows 需独立用例，见 §5 门槛 9）。

### S8-E 投影覆盖：三阶段探测（条件实施，0–0.3）

**阶段 1 — 取样本（不用 5 秒 follow）**

```bash
# 用已有日志的快照取样：follow 5 秒可能一条完整记录都没有，无法证明任何结论
zoe task logs <TASK> --log agent --tail-bytes 262144 --json | jq -r '.text' > raw-sample.jsonl
```

脱敏后保留 `type` / `subtype` / `message` / `delta` / `item` 结构，**不入库、不进 fixture 的业务内容**。

**阶段 2 — 逐类覆盖率**（评审的判据修正）

| 记录类别 | 判据 |
|---|---|
| 含文本的 `assistant` 记录 | 必须产出 `kind=text` |
| 工具调用 | 必须产出 `kind=tool`（name + target） |
| 空信封（`content: []`） | `auto` 下应为 `record`，**不得**当作文本 |
| 控制类（`result` / `system`） | `result` / `init` |
| 非 JSON 行 | `raw`（脱敏后） |

指标（只在 fixture 测试里算，不进生产状态）：

\[ C_{\text{text}} = \frac{N_{\text{projected-text}}}{N_{\text{raw-text-bearing}}} \]

验收目标：对**已确认支持**的形状，`C_text = 100%`（记录覆盖，不含 400 字截断）。**出现一条 `kind=text` 就收工是不合格的判据**。

**阶段 3 — 只补被证明遗漏的分支**

- 若覆盖已完整 ⇒ 不实施，文档记 `COVERED`；
- 若有遗漏 ⇒ 只加该形状的分支，并**按适配器分文件**（`_logstream` 提供公共事件模型，codebuddy 的投影适配放适配器侧或显式映射表），不加"多供应商散字段猜测器"（评审第 3 条，与编排层/执行器适配层分离原则一致）；
- 数据不足 ⇒ 记 `NOT_VERIFIED`，不得写成"已兼容"。

---

## 3. 明确不做

| 项 | 理由 |
|---|---|
| 文本进 `progress.json` / `task status` / 事件表 | 破坏"低频观测事实""状态快照""迁移审计"三种既有职责；写放大、敏感内容入盘、`task status` 变半个日志接口 |
| 通用多供应商字段猜测（`choices[].delta.content` 一把梭） | 会把"某个 API 的形状"当成"该执行器的协议"；S8-E 只补实测缺口，且按适配器归属 |
| 逐 token 转发 / 流式 UI | 日志已可增量读，没有新信息 |
| 用日志静默判"卡死" | `progress.note` 原文：no output does not prove a hang |
| 把展示游标写进任务状态库或 `progress.json` | 它只服务"这一轮打印过了没有"，进程内临时文件足够；写库会制造第二事实源 |
| 让 `--with-log` 影响退出码 / 终态 | 观测不得改写状态机的结论 |
| 为快照再加一个"摘要/结论"字段 | 语义归纳不是投影层的职责；要结论就 `task summary submit` 或派只读任务 |

---

## 4. 顺序、版本与回滚

| 序 | 动作 | 说明 |
|---|---|---|
| 1 | `_logstream`：`window_start` / `complete_offset` / `read_window` / `project_complete_lines` + 单测 | 纯新增，先落，S8-C/D 共用 |
| 2 | parser：`--tail-bytes default=None` + **新增 `--after`**（含 help、与 `--follow` 互斥校验） | 与 1 同批；快照侧回落默认值，行为不变；`--after` 契约见 §D-2-a |
| 3 | `_task_logs` 重写（有界读 / 字节定界 / 三截断 / cursor / `--after` 增量） | P0 |
| 4 | `_logs_follow` offset 解析（显式窗口） | P0；**行为变更**，需发布说明 |
| 5 | `runtime-requirements.json` 的 `min_version` 提升到含 2–4 的版本 | Skill 侧门禁；版本号由发布决定，本文记为 `<NEXT>` |
| 6 | `SKILL.md` / `cli-contract.md` 按 S8-A 定稿（此时命令已真实存在） | P0 |
| 7 | `zoe-monitor.*`：B1（tick）+ B2（`--with-log`） | P1；B2 依赖 2–4。**必须与 S4 的 `stop_reason` / `--max-seconds` 合并为同一次脚本改动**（见批派发文档 §4.1 阶段三） |
| 8 | S8-E 探测 → 按证据决定 | 条件 |

**版本依赖（评审第 3 条）**：

1. 先发布 runtime（2–4），再启用 Skill 的 `--with-log`；
2. 旧 runtime 不应导致监控整体失败：脚本对 `task logs --after` 的调用若以"参数不被接受"（argparse exit 2）失败，**自动关闭 `--with-log` 并打印一行 `[log-off]`**，其余监控照常；
3. `min_version` 是硬门禁（整包拒绝），脚本内的降级是软兜底——两者不互相替代，文档要分开写；
4. 回滚：`--with-log` 是显式开关，回滚只需不传；`--tail-bytes` 的默认语义不变，回滚风险集中在"显式传参"的一侧。

---

## 5. 验收（评审 10 条门槛 + v2.1 新增 1 条）

| # | 门槛 | 判定方式 |
|---|---|---|
| 1 | 不传 `--tail-bytes` 时 `--follow` 仍从 EOF 开始 | 断言 `_logs_follow` 的起始 offset == `stat().st_size`；用带历史日志的夹具验证"输出中不含历史记录" |
| 2 | 显式 tail 窗口时首条输出是完整记录 | 向夹具末尾写入"半行 + 完整行"，断言首个事件可 `json.loads` 且不是 `raw` |
| 3 | 快照与 follow 对同一区间一致 | 不变量测试：`snapshot(a,b).events == follow(a→b).events`（转义例外：单行 > 64 KiB） |
| 4 | 尾部只有半行时 cursor 不越过未完成记录 | `complete_offset` 断言：`cursor <= 最后一条完整记录末尾`，续读能补齐该行 |
| 5 | 大文件读取有内存与 I/O 上界 | 造 200 MiB 日志（稀疏写），断言快照耗时/读取字节 ≤ `tail_bytes + 1`（用 `os.stat` 之外的计数器或 monkeypatch `read`） |
| 6 | `--with-log` 不重复、不改退出码 | 同一份日志连续两轮：第二轮无 `[log]` 行；`--max-rounds 1` 时退出码仍为 0/2/10/11 |
| 7 | run 切换 / 日志截断 / 读取失败有测试 | 截断夹具 ⇒ `rotated` + 重新定位；读取失败 ⇒ `[log-error]` 且游标不动、连续 3 次关闭 |
| 8 | 真实 CodeBuddy fixture 验证覆盖 | S8-E 阶段 2 的分类表；不足则记 `NOT_VERIFIED` |
| 9 | Bash 与 PowerShell 参数/核心输出一致 | 两份脚本对同一夹具输出同一组 `[log]` 前缀行（时间戳/顺序无关维度排除） |
| 10 | 既有契约测试与 `build.py --check` 通过 | `test_skill_cli_contract.py`（文档命令/选项必须真实存在）、`test_contract_artifacts.py`、`test_doc_contracts.py`、`build.py --check` |
| 11 | **新选项的对外契约自洽**（v2.1 新增） | `--after` 与 `--follow` 同用 ⇒ `INPUT_INCOMPLETE`；cursor run 不匹配 ⇒ `PROJECT_MISMATCH`；`offset > size` ⇒ `rotated` 且不报错；`--help` 文案与 §D-2-a 逐字一致 |

**新增契约测试（建议与门槛 3/4 合并落地）**：

```text
tests/test_v150_observation.py
  + test_snapshot_and_follow_agree_on_same_range
  + test_partial_last_line_is_not_projected
  + test_cursor_never_crosses_incomplete_record
  + test_window_start_keeps_current_line_when_already_aligned
  + test_window_start_skips_partial_head_within_window
  + test_snapshot_read_is_bounded (大文件)
  + test_blank_lines_emit_nothing_in_both_modes
  + test_after_rejects_follow_combination
  + test_after_cursor_run_mismatch_raises_project_mismatch
  + test_after_offset_beyond_size_reports_rotated
  + test_after_pages_until_has_more_is_false
tests/contract/test_skill_cli_contract.py
  + --after / --tail-bytes 在 SKILL 文档中出现时确实被 parser 接受
  + --after 与 --follow 的 help 文案含"不能同时使用"
```

**负向文案断言**：不出现「`--follow` 能看到之前的进展」（无 `--tail-bytes` 时）；不出现「`kind=record` = 没有输出」；不出现「`task logs --project` / `--jsonl`」；不出现「日志静默说明卡住」。

---

## 6. 风险与边界

### 6.1 日志可见性 ≠ 执行证明（评审第 4 条）

| 信息来源 | 能证明 | 不能证明 |
|---|---|---|
| `task status` | 当前记录的任务状态 | 业务目标是否达成 |
| `progress.json` | 观测到的输出变化 | Agent 是否有效推进 |
| `task logs` | Agent 报告了什么、调用了什么工具 | 工具是否成功、结果是否正确 |
| `task report` / 验证证据 / CI | 特定检查在该 SHA 上的结果 | 未覆盖条件也正确 |

因此 `[log] worker-a 动：Edit src/config.py` 只是**过程观察**：不等于文件写成功，更不等于验收通过。`--with-log` 输出必须带这句限定（脚本注释 + 文档 + 报告模板一致）。

### 6.2 脱敏与截断

- 所有输出字段走 `_redact_tree`（逐字符串），但它是**正则级 best-effort**；不得声称"已脱敏到可外发"。
- 未识别形状的字段**被丢弃**（只留 `type`），不存在"未知字段绕过长度限制"的通道；若将来改成保留字段，必须同时保留脱敏与截断。
- 三种截断分账后，宿主不得把 `events_truncated` 当成"日志丢了"（丢的是窗口内更早的事件，`tail_start_offset` 不变）。

### 6.3 一致性的适用边界

不变量在"单条记录 ≤ 64 KiB"下成立。超长行时 follow 会切成"截断片段 + 后续片段"，快照按物理行处理；测试显式声明该例外，文档不得声称"任何情况下都一致"。

### 6.4 行为变更清单（发布说明必须列）

1. `--follow --tail-bytes N` 从"无效"变为"回看 N 字节"；
2. 空行不再产出空 `raw` 事件（快照与 follow 统一跳过）；
3. 快照的 `cursor` 从"文件末尾"变为"最后一条完整记录之后"（可能比 `bytes` 小）；
4. 快照新增 `events` / `events_truncated` / `tail_start_offset` / `has_more` / `rotated`（纯增量）；
5. **新增选项** `task logs --after <cursor>`（纯增量；与 `--follow` 互斥，同用报 `INPUT_INCOMPLETE`）；
6. `--tail-bytes` 的默认值从 `65536` 变为"未指定"（快照返回不变，但 `--help` 文案与 `args` 取值变化，对外行为以 §D-2-a 为准）。

---

## 7. 附：关键锚点（`zoe-runtime@1.5.1`，2026-11-04 快照）

```text
src/cli.py:596                     --tail-bytes default=65536（v2 改 None，快照侧回落）
src/cli.py:928                     require(1 <= args.tail_bytes <= 1MiB)
src/cli.py:931-932                 raw = path.read_bytes()（全量读）；tail = raw[-N:]
src/cli.py:941                     cursor = run:1:<len(raw)>（可能落半行）
src/cli.py:_logs_follow()          无 cursor ⇒ offset=EOF；--tail-bytes 被忽略
src/_logstream.py:_take_lines()    按 b"\n" 切；不跳空行；超长行标 truncated 后继续
src/_logstream.py:project_record() 只认 message.content[]；未知形状丢字段、留 type
src/_logstream.py:project_line("") ⇒ [{"kind":"raw","text":""}]（空行行为，§1.4）
src/_logstream.py:tail_window()    已定义但无人调用的路径辅助（命名需避开新函数）
src/_backend.py:_do_launch()        stdout=self._logfile；POSIX/Windows 均 stderr→STDOUT
src/_agents/codebuddy.py           -p --output-format stream-json（注释记录 json 会憋到退出）
src/_progress.py:_payload()        log_generation / bytes / quiet_seconds / process_state
src/_store.py:save()               事件固定带 state/phase/block_code/run_id
zoe-workflows/scripts/zoe-monitor.sh  [tick] 仅 round/cur/alive/need_human；不读日志
zoe-workflows/runtime-requirements.json  min_version 1.5.1（S8-C/D 发布后需同步提升）
```

---

## 8. 实施记录（2026-11-04，`zoe-runtime@1.5.2` / `zoe-workflows`）

### 8.1 逐项状态

| 项 | 状态 | 落点 |
|---|---|---|
| S8-A 文档协议 | **完成** | `SKILL.md` 第 6 步「动作线」+ `references/cli-contract.md`「日志」整节（选项矩阵、响应字段、`--after` 校验表、一致性不变量、负向文案） |
| S8-B1 `[tick]` 带 phase/run | **完成** | `zoe-monitor.sh` / `.ps1`：`phases=<task>:<phase>` / `runs=<task>:<run>`；同名 `.ps1` 参数 `-WithLog` 等 |
| S8-C `--follow` 显式窗口 | **完成** | parser `default=None`；`_logstream.window_start()` 向后对齐；`--cursor` 优先；快照侧回落 `DEFAULT_TAIL_BYTES` |
| S8-D-1 有界读 + 字节定界 + 三截断 | **完成** | `read_window()` / `project_complete_lines()` / `complete_offset()`；`truncated`（窗口）/ `events_truncated`（条数）/ 事件上 `clipped: true`（内容） |
| S8-D-2 `task logs --after` | **完成** | `_task_logs()`；契约按 §D-2-a：形状/校验/`PROJECT_MISMATCH`/`rotated`+`reset_cursor`/`has_more` |
| S8-B2 `--with-log` | **完成** | 展示游标（`mktemp -d`，进程内）、失败隔离、连续 3 次关闭、run 切换与 `rotated` 都**丢弃**旧游标重新定位、旧 runtime 用 stderr `unrecognized arguments` 识别后只关该功能 |
| S8-E 投影覆盖探测 | **NOT_VERIFIED** | 本机 `~/.zoe` 下无真实 codebuddy run 日志，阶段 1 取不到样本 ⇒ 按 §S8-E 记 `NOT_VERIFIED`，**未**新增任何散字段猜测分支（只加了空行统一与 `clipped`） |
| S4（同批脚本改动） | **完成** | `--max-seconds`（单调 `SECONDS`）、`--stop-file`、退出时 `[stop] reason=ALL_TERMINAL\|BUDGET_EXHAUSTED\|HUMAN_REQUIRED\|WATCH_ERROR\|DEPENDENCY_ERROR`；退出码不变 |
| 版本门禁 | **完成** | runtime `1.5.2`；`runtime-requirements.json` `min_version=1.5.2` + `logs_incremental_read`；`capabilities().observation` 增加 `logs_snapshot/logs_after/logs_window/logs_truncation` |

### 8.2 实现中发现、需要在文档里说清的两处（**评审已接受**）

1. **窗口上限与"必须能推进"的冲突**：`--after` 用 `--tail-bytes` 作窗口上限时，若下一条记录
   比窗口长，`complete_end` 无法越过它 ⇒ 每页都是空、`has_more` 恒真（死循环）。实现为
   `one_record_span()`：窗口内没有一条完整记录时延伸到下一条记录结束（硬上限 `MAX_READ_BYTES`
   = 256 KiB），并把 `has_more` 定义为"**拿到了至少一条完整记录**且后面还有内容"。
   这比 §D-2-a 的两条口径更严：契约文字已同步（cli-contract「窗口上限是 `tail_bytes`，但…」）。
2. **空行规则的调用点**：`project_line("")` 返回 `[]`（不是只在两个调用点各跳一次），这样
   任何未来调用方都继承同一规则，一致性不变量不依赖"记得跳过"。

### 8.3 复核修正（2026-11-04，review 后已全部落地）

复核口径是"文档说的 → 代码是否真的这么做"，逐条对照 §2 与 §5 的门槛。发现 8 处不一致，
均已修正并补测（不是只改注释）：

| # | 位置 | 修正 |
|---|---|---|
| 1 | `_logstream.project_complete_lines` 文档串 | 曾声称"快照与 follow 都调用本函数"——**不实**（follow 走 `project_line`）。改为准确描述：规则共享在 `project_line`，一致性靠它而不是靠"记得调用同一个函数" |
| 2 | `zoe-monitor.*` 的 `[tick]` | `phases=`/`runs=` 曾用**空格**分隔，与 §S8-B1 的 `,…` 不符（宿主按逗号切会解析错）。统一为逗号，并加断言锁定形状 |
| 3 | `zoe-monitor.*` 的 `rotated` 分支 | 曾把 `reset_cursor`（offset 0）写回展示游标 ⇒ 会从**新文件开头**播。按 §S8-B2 规则 2 改为**丢弃**旧游标，下一轮按窗口重新初始化 |
| 4 | 两个监控脚本的 `emit_log` 注释 | §D-2-a 要求"游标与 `--log` 绑定"写进**脚本注释**，原本只在文档里。已补第 4 条硬要求 |
| 5 | `test_after_help_states_the_follow_exclusion` | 门槛 11 要求 help 文案"逐字一致"，原断言只查子串。改为完整相等 |
| 6 | `test_follow_without_a_window_still_starts_at_eof` | 门槛 1 要求断言起始 offset == `stat().st_size`，原本只验"不含历史"。已补 |
| 7 | `test_with_log_does_not_mask_usage_or_watch_errors`（新增） | 门槛 6 的退出码 0/2/10/11 只测了 0 与 10。补 `--log-bytes 0`（→2）与 init 后 `watch` 失败（→11） |
| 8 | 一致性不变量用例的文档串 | 门槛 3 要求三个前提写进测试，原只在模块级说明。已写进该用例 |

### 8.4 决策记录

| 日期 | 决策 | 影响 |
|---|---|---|
| 2026-11-04 | **接受 §8.2 的两处偏差**（`has_more` 多一个 `complete_end > start`；`--after` 窗口可延伸到一条记录结束、上限 256 KiB） | 契约以 `cli-contract.md` 为准；§D-2-a 原口径保留并标注偏差。回退到原口径必须同时给出"大记录时宿主如何推进"的替代方案，否则会引入原地死循环 |
| 2026-11-04 | 接受 8.3 的 8 处修正（不改对外契约，只把实现/测试对齐文档） | 无对外行为变更；`[tick]` 格式与 `rotated` 处理两处属监控脚本的可见输出变化，已在脚本文档串写明 |

### 8.5 未验证项（不得写成已兼容）

| 项 | 原因 |
|---|---|
| 门槛 9（bash 与 PowerShell 一致） | 本机无 `pwsh`；`.ps1` 已按同语义重写并有静态门禁（退出码/`[stop] reason`/`[log]` 前缀/参数名），但**Windows 独立用例未跑** |
| S8-E `C_text` 覆盖率 | 无真实 fixture（见 8.1） |
| 真实 codebuddy `stream-json` 形状覆盖 | 同上；投影层未改，`record`/`raw` 的语义边界按 §1.5 保持不变 |
