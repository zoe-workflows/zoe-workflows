# 批量派发重试、空候选与验证落空（评估 + 方案）

| 项 | 内容 |
|---|---|
| 日期 | 2026-11-05 |
| 输入 | ① 本清单 6 条（批量 start 重试 / 空 diff / spec 文件边界 / 合并前验证 / 批量输出 / 越界）+ 1 条「`task logs` 返回空」；② T9 批次（T9a–T9d）实际执行记录 |
| 被评估对象 | `zoe-workflows`（`SKILL.md`、`references/*`、`scripts/*`、`build.py`）；`zoe-runtime@1.5.2`（`src/_store.py`、`src/_pipeline.py`、`src/_contracts.py`、`src/_backend.py`、`src/_logstream.py`、`src/cli.py`）；被编排项目 `zoe-go` 的项目配置 |
| 方法 | 每条先回到源码取证，再回放本机真实记录（`state.db`、`~/.local/share/zoe/tasks/*`、`zoe-go` 合并图）复现症状；凡未实测的推断均标注 |
| 本文位置 | `zoe-workflows/docs/`（不在 `build.py` 的 `WHITELIST` 内，不进入发布包） |
| 核验说明 | 源码以**符号名 + 行号**为准（`1.5.2` 快照，2026-11-05）；证据命令一律只读 |

## 0. 结论

### 0.1 七条的判定

| # | 原问题 | 判定 | 原方案是否采纳 | 落点 |
|---|---|---|---|---|
| 1 | 批量 start 无自动重试 | **症状成立，根因不同** | **部分否决**：「一律换新 `request_id` 重试」会毁掉幂等、并对 `TASK_BUSY` 用错药 | S1 / R1 |
| 2 | 空 diff 无预警 | **成立，且比"缺提示"更严重**：零改动可一路走到 `REVIEW_READY` 并持有"验证通过"的证据 | 采纳，补 runtime 侧信号 | S2 / R2 |
| 3 | spec 缺文件边界 | **成立，但根因是"spec 是纯 Markdown"**：`## 允许路径` 从来没生效过，不是"模板少一节" | 采纳，且要改结构化 spec | S3 / R3 |
| 4 | 合并前无独立验证 | **成立，但第一根因不在 skill**：项目 checks 用 `cd <主仓库绝对路径>` 绕出 worktree，verify 验的是主仓库 | 采纳，须先修配置 | S4 / R4 |
| 5 | 批量 start 输出不可靠 | **成立**（运行时没有 batch 命令，宿主只能手写循环 + 手抄结果） | 采纳 | S1 |
| 6 | worker 越界 | **同 #3**（`allowed_paths` 为空 ⇒ `task_scope=None` ⇒ 继承整个项目） | 采纳 | S3 |
| 7 | `task logs` 返回空是 projection bug | **不成立**：实测为 `rotated` 分支，`text=""`+`events=[]` 是**契约内行为** | 部分采纳（文档 + 一行字段） | S5 / R5 |

### 0.2 本轮最关键的发现（优先级高于清单里的任何一条）

`zoe-go` 项目声明的三个 check 全部长这样：

```json
{"id": "test", "argv": ["bash", "-c", "cd /Users/liuzhupeng/workspace/skillspace/zoe-go && /Users/liuzhupeng/.local/go/bin/go test ./..."]}
```

而控制器执行 check 时把 `cwd` 设成**任务 worktree**（`_backend.py:574-576`）。argv 里的 `cd` 把这层隔离抹掉了：**check 跑在主仓库，结论却写进 worktree 候选的证据。**

实测反证（2026-11-05，只读）：

| 事实 | 证据 |
|---|---|
| T9b worktree（`ee624b46`）单独跑 `go test ./internal/app -run TestA21` | **FAIL**（`decision 必须是 accepted 或 rejected，得到 ""`） |
| T9b 的冻结证据 `check_results` | `{"id":"test","status":"PASS","exit_code":0}` |
| T9a / T9c worktree 同一命令 | PASS（说明不是环境问题） |
| 合并后才出现的修复提交 | `eb88409 fix: update TestA21 for new AcceptTask decision+subject_sha contract`（改的是测试文件 8+/3-） |

结论：**本轮 T9 全部任务的 `test` 证据都不代表其改动被测试过。** 空候选能通过、越界能通过、测试挂了要等合并才发现，都是这一条的后果。修它之前，S2/S3/S4 的任何检查都建立在假证据上。

### 0.3 一个贯穿 5 条的根因：任务身份靠人配对

运行时校验的是 `request_id` 哈希与 `task_id`，**不校验"这个文件本来属于哪个任务"**；人工写脚本时，`task start <TASK> --request-file <FILE>` 的主体来自 argv、幂等键来自文件，两者可以静默错配。本机记录里有三处实证：

| 现象 | 记录 |
|---|---|
| 一个名为 T9a 的 start 请求实际打给了 T9d | `operations` 行 `t9a-start-20261105` → `task-d17eef0cf4224e14`（T9d） |
| 随后真正的 T9a 只能用新 id | `t9a-start-v2-20261105` → `task-e87a962af84d411e` |
| 同类手工后缀在本项目反复出现 | `t8a-start-20261104`(T8f) / `t8a-start-v2`(T8e) / `t8a-start-v3`(T8a) / `t8c-retry-start` / `t9c-start-v2` |
| merge 标签与内容错位 | `c44d496 "Merge T9a CI status polling"` 的第二父提交是 `ee624b4`（**T9b**）；`ad29c4e "Merge T9a + T9b"` 才合入 `64647ce`（T9a） |

这条解释了「T9a 和 T9b 产出同一个 commit」的**观感**：并不是同一个 commit（`64647ce` / `ee624b4` 是两个不同提交、改的是两个不同文件），而是**合并标签被写错**，读历史的人会把它们读成同一件事。

---

## 1. 事实核对

### 1.1 幂等键 = `request_id`；主体（task）与载荷进哈希

`_store.py:275-288`：

```python
key = safe_id(request.get("request_id"))
return key, digest([action, task, request])
```

- `key` 是**全局唯一**的 `request_id`（跨任务共享命名空间，库表 `operations(id TEXT PRIMARY KEY)`）；
- `hash` 覆盖 `action + task + 整个 request`。

因此同一个 `request_id`，只换 `task` 也会 `REQUEST_CONFLICT`（`_store.py:293-296`）。这正是 T9a 那个请求文件被第二次使用时发生的事。

`REQUEST_CONFLICT` **不带 `details`**：`require()` 只有三参（`_util.py:109-111`），该码也不在 `_HINTS` 表内。宿主拿不到"这个 id 被哪个 task / 哪个 action 占了"，只能靠人回忆。

### 1.2 失败码分两类：烧掉 `request_id` / 不烧

这是决定"能不能自动重试"的唯一事实：

```text
_pipeline.py:1135-1147  start()  → 先 operation_prior；prior 非空或 intent 就 _replay，不派发
_pipeline.py:1165-1171  _start_locked() → lifecycle_locks(writer EX) → store.operation() 写 intent
_pipeline.py:955-979    lifecycle_locks() 拿不到 writer → TASK_BUSY（此时还没写 intent）
_pipeline.py:1473-1479  except → store.finish(key, {"status": "failed", ...})
_store.py:298           operation() 对任何非 intent 状态都返回 prior ⇒ 失败记录会被当成"结果"重放
```

| 失败 | 是否已写 intent 行 | 同 `request_id` 再提交会怎样 | 正确动作 |
|---|---|---|---|
| `TASK_BUSY`（写者锁被占） | **否** | 等价于第一次提交（可重试） | **原 id 原载荷重放**；1 秒内还会自愈成 `dispatch_pending`（`_pipeline.py:1154-1161`） |
| `SLOT_BUSY`（`max_active_tasks` 满） | **是**（intent 先写，槽位判定在后：`_pipeline.py:1251-1257`） | 直接返回那条失败记录，**永不重派** | 等槽位后**换新 id** |
| `STATE_CONFLICT` / `ENVIRONMENT_ERROR` / `POLICY_*` / `AUTH_*` | 是 | 同上 | 先修前置条件，再换新 id |
| `REQUEST_CONFLICT` | 否 | 永远冲突 | **不重试**，查 id 为何被占 |
| 传输失败 / 响应丢失 | 未知 | 幂等返回原结果 | 同 id 原载荷重放，或先 `task status --refresh` |

两条必须写进文档的推论：

1. `SKILL.md:366-367`「同一任务重试复用原值」**只对"结果未知"成立**，对已经落成的失败记录是错的——同 id 重试拿回的是上次的失败，不是新一次尝试；
2. 自动重试必须**按码分流**。设成"失败就换新 id 重试一次"会把 `TASK_BUSY` 的并发安全（同 id 重放返回 `dispatch_pending`）换成一份新请求，反而制造第二条派发路径。

### 1.3 空候选：全链路没有一处判 `candidate_sha != base_sha`

`_pipeline.py:2856-2873`（verify 收口）：

```python
every_check = [check["id"] for check in c["checks"]]
judge_validation(results, declared if declared is not None else every_check)
git(w, "add", "--all")
staged = git(w, "diff", "--cached", "--name-only")
if staged:                      # 零改动 ⇒ 不提交
    git(w, "commit", "-m", "feat: " + id)
sha = git(w, "rev-parse", "HEAD")          # 于是 sha == base_sha
validated = {**t, "candidate_sha": sha, "validated_sha": sha}
```

- 全仓 grep `base_sha == candidate` / `candidate_sha != base_sha` / `empty_diff` / `no_changes`：**0 命中**；唯一相关文案是展示层的 `_diff_stat()` → `"no changes"`（`_reports.py:177-188`）；
- 零改动时仍会 `_evidence.build(...)`（2874-2890）→ `phase="acceptance"` → `REVIEW_READY`（2931-2940）；
- 因为 `candidate_sha == validated_sha == base_sha`，`accept` 的 `subject_sha == validated_sha`（`_pipeline.py:3077-3081`）也**能通过**。

现场实例（`zoe task list --project zoe-go`）：

```text
task-d17eef0cf4224e14 | T9d  | REVIEW_READY | base 574563c7 | cand 574563c7 | valid 574563c7
task-b62dcda3e3e04567 | T8f  | REVIEW_READY | base d1b0dc4b | cand d1b0dc4b | valid d1b0dc4b
```

T9d 的 worktree 实测 `git log`：HEAD 就是 base（`574563c Merge T8e acceptance tests A13-A24`），相对 base 的改动文件**空**。

### 1.4 spec 是纯 Markdown ⇒ 三个机制全部关闭

`_contracts.py:201-207`：

```python
try:
    document = json.loads(text)
except json.JSONDecodeError:
    require("AC-" in text, "INPUT_INCOMPLETE", "Spec requires acceptance IDs")
    return 1, None            # ← document = None
```

T9a–T9d 的冻结 spec（`~/.local/share/zoe/tasks/*/spec-1.json`）实测：

```json
{"text": "# Spec：T9a CI 状态查询 ... ## 允许路径\n\n- internal/app/publish_flow.go\n",
 "contract_version": 1, "document": null, "verification_semantics": 2}
```

三处后果：

| 机制 | 读什么 | `document=None` 时 |
|---|---|---|
| 任务范围 | `_contracts.spec_scope(document)` → `document["allowed_paths"]`（`_contracts.py:90-114`） | `None` ⇒ `_resolve_task_scope` 返回 `scope_source="project"`（`_pipeline.py:363-381`）⇒ **整个项目可写** |
| 越界检查 | `_backend.scope()` 比较 `task_scope or config.allowed_paths`（`_backend.py:641-649`） | 只与项目级 `allowed_paths` 比 ⇒ 越界判定形同虚设 |
| 验收绑定 | `verification_scope(document, checks)` ⇒ `frozen_scope()`（`_pipeline.py:1700-1724`） | `declared=None` ⇒ 跑全部 checks（这一项**不受影响**） |

即：spec Markdown 里写的 `## 允许路径 - internal/app/publish_flow.go` **从未被任何代码读过**，只是一个注释。worker prompt 里的 `允许范围：{{allowed_paths}}` 填的是项目级范围。

这正是 #3 与 #6 的真根因，也解释了为什么"把 `allowed_paths` 写细"这件事在本轮根本没进入运行时：**它根本没到达运行时。**

### 1.5 checks 逃出 worktree（第一根因，见 §0.2）

- 执行目录是 worktree：`_backend.py:574-576` `plat.spawn(argv, cwd=t["workspace"], ...)`；
- 但 argv 自己 `cd` 到了主仓库（`zoe-go` 项目配置的 `checks[*].argv`）；
- 证据绑定用的是 **worktree** 的指纹：`run_checks` 里每行 `"fingerprint": marker`，`marker = before`（`_pipeline.py:2841-2843`），而 `before = fingerprint(t)` 由 worktree 计算。

于是证据里出现"三个 check 同指纹 PASS"，而其中至少一个（T9b 的 `test`）在 worktree 里是 FAIL。**指纹证明的是"worktree 没被校验过程改动"，不是"这些 check 验的是这个 worktree"。**

补充：`check-build.log` 为 0 字节、`ok zoe/internal/app 41.434s`（非 cached）也符合"跑在主仓库且当时主仓库刚合入 T8e 新测试"的解释；若跑在 worktree，`internal/app` 会带 T9b 的改动而失败。

### 1.6 `task logs` 空输出：是 `rotated`，不是 projection

复现（同一任务、同一 run、只读）：

```text
zoe task logs TASK --json                       → bytes 518018, text 59816 字节, events 38
zoe task logs TASK --json --tail-bytes 8192     → text 7058 字节, events 6
zoe task logs TASK --json --projection events   → text 59816 字节, events 24
zoe task logs TASK --json --after run-…:1:9999999
     → bytes 518018, text "", events [], rotated true,
       reset_cursor run-…:1:0, tail_start_offset 0, truncated false
```

三行合起来就是用户报告的那三个值。分支在 `cli.py:1037-1049`：

```python
if after[2] > size:          # 游标 offset 超出文件大小
    rotated = True
    start = 0
...
if rotated:
    data = b""               # ⇒ text="" 且 events=[]
```

该行为是**已写进契约**的（`references/cli-contract.md:567,579`：不报错，给 `rotated` + `reset_cursor`）。所以：

- 不是 projection 解析 bug，也不是"读取路径不对"（元数据 `bytes` 说明文件读到了）；
- `zoe-monitor.sh:256-259` 已经处理 `rotated`（丢弃展示游标），**宿主手工读 `task logs` 时没人处理它**；
- 真正的坑是**可读性**：`tail_start_offset=0` + `bytes=518018` + `text=""` 在字面上自相矛盾，只有 `rotated:true` 一个字段能解释。

另一个**未复现但存在**的空窗口分支（`_logstream.py:238-252`）：尾部窗口内一个换行都没有时 `window_start` 返回 `size` ⇒ 同样是 `text=""`+`events=[]`，且**没有** `rotated`。本机这份日志 `max_line_len=26084 < 65536`，所以没触发；单条 `Write` 大文件时会触发。

### 1.7 没有 batch 命令

`src/` 下 grep `batch`：只有 `_platform/windows.py:354-371` 的 `wrap_batch`（把 `.bat` 交给 cmd，与任务批处理无关）与一处注释。`cli.py` 帮助表里也没有 batch 形态；多任务派发的现成入口只有 `group`（组内串行，不是吞吐）。

因此"批量 start"在当前能力下**只能靠宿主写循环**，而每个 start 都需要 `--request-file`（`cli.py:628-632`），请求体至少要有 `schema_version` / `request_id` / `authorization_ref`（`_config.py:1143-1155`）/ `expected_version`（`_pipeline.py:1198-1202`）。手写 4 份、再把 task 与文件配对，就是 §0.3 那三处错配的来源。

---

## 2. 采纳项与改法

顺序不是按清单编号，而是按"先让证据变真，再让流程变稳"。

### S0（前置，P0）修正项目 checks，让它真的跑在 worktree 里

**落点**：被编排项目配置（本机是 `zoe-go` 的 `checks`），不是 skill 代码；skill 侧补一条准入校验。

**改法**：

```json
"checks": [
  {"id": "build", "argv": ["go", "build", "./..."]},
  {"id": "vet",   "argv": ["go", "vet", "./..."]},
  {"id": "test",  "argv": ["go", "test", "./..."]}
]
```

- 不写 `cd`：cwd 已经是 worktree；
- `go` 走 supervisor 的 PATH（`run_checks` 只拦 `unresolved`，`_pipeline.py:1803-1810`）；若 PATH 里没有，用**绝对路径但不带 cd**：`["/Users/…/go/bin/go", "test", "./..."]`；
- 依赖项目根的相对路径（`./...`、`go.mod` 相对目录）本来就以 cwd 为基准，改完语义正确。

**准入校验**：静态扫一遍项目 `checks[*].argv`，出现下列任一形态就阻断并在报告里点名：

```text
- argv 里出现 `cd <绝对路径>` / `git -C <绝对路径>` / `--cwd=/<绝对路径>`
- 形如 ["bash","-c","…"] / ["sh","-c","…"] 且内含上述写法
```

理由：这类 argv 让"独立验证"变成"验另一个目录"，是最难自查的一类错误（指纹、exit code、日志全都看起来正常）。**判错**：把这条写成"建议"，或只写"记得用相对路径"。

> **实施说明（2026-11-05）**：这条做在 runtime 的 `task prepare` 里（诊断码
> `CHECK_ESCAPES_WORKSPACE`，阻断 `prepared`），而不是在 skill 里用 grep 扫配置。理由：
> `prepare` 本来就是"一次看全"的唯一闸门，放在那里对所有项目自动生效，也不会因为宿主
> 换了实现语言而漏检。`cd "$VAR"` 这类不含绝对路径的写法不会命中（判据是"钉到绝对路径"，
> 不是"出现 cd"）。

> 注意：本项目 `cb-pro`/`cb-flash` 的 profile 描述里记着"model_identity 恒为 unobserved"等历史妥协，改 checks 会改 `policy_digest` ⇒ 在途任务 `POLICY_CHANGED`，必须 `register` → `attest` → 在途任务 `rebind`。这属于**用户改变项目政策**，要人来批。

### S1（P0）`scripts/zoe-batch-start.sh`：生成器 + 按码分流的重试

**落点**：新增 `scripts/zoe-batch-start.sh`（POSIX，依赖 `jq` 与 `uuidgen`/`python3`）；`SKILL.md` 第 5 步引用；`build.py` 的 `REQUIRED_FILES` 补登。

**为什么是脚本而不是文档**：同一套命令（status → 拼请求 → start → 记结果）在本机批次里被手工重复了 ≥3 次（`operations` 表里 30 个 `*-start-*` 行，含 5 个 `-v2/-v3/-retry` 手工后缀），满足既有"脚本纪律"（2026-11-04 文档 §4.3）的准入条件。

**契约**：

```text
bash <skill-dir>/scripts/zoe-batch-start.sh --project P --plan plan.json \
     [--out .zoe/P/batch] [--json] [--max-parallel N]

plan.json:
{"items": [
  {"task_id": "task-…", "label": "T9a", "strategy": "auto"},
  {"task_id": "task-…", "label": "T9b"}
]}
```

**每个 item 的固定顺序（缺一步就报错，不"尽力而为"）**：

1. `zoe task status <T> --json --refresh` → 读 `row_version` / `state` / `block_code` / `config.authorization_ref`；
2. 前置闸（不过就 `skipped` 并写原因，**不 start**）：
   - `state ∉ {READY, PAUSED, BLOCKED}` → `skipped:not_resumable`；
   - `block_code == INPUT_REQUIRED` → `skipped:answer_first`；
   - `block_code == PROCESS_UNKNOWN` → `skipped:reconcile_first`；
3. **生成**请求文件（不手抄）：`request_id = "<T>-start-<YYYYMMDD>-<rand8>"`（随机后缀是硬要求，见下方"为什么不是 UUID 复用"）、`expected_version` 取**本次** refresh 的 `row_version`、`authorization_ref` 取任务冻结配置值 → 写 `<out>/<T>.start-<row_version>.json`，同时把 `task_id` 写进文件名**和**旁路 `manifest.jsonl`，让"文件属于哪个任务"可事后核对；
4. `zoe task start <T> --request-file <file>`，捕获 stdout + exit code（**逐条落盘**，不依赖 shell 变量累积）；
5. 按 §1.2 的表分流（见下）；
6. `task status <T> --json --refresh` 复核 `state` 已离开 `READY`，否则记 `unconfirmed`（对应"批量 start 后逐个确认"）。

**分流表（这是本项的核心，不是"一律重试"）**：

| 返回 | 动作 |
|---|---|
| 成功 / `dispatch_pending` | 记 `dispatched`；`dispatch_pending` 额外记"未确认已起进程"，由监控接管 |
| `TASK_BUSY` | **原 id 原 file 重放** ≤3 次（间隔 2s）；仍失败 → `busy`，提示"可能有第二个写者，先 `task status --refresh` + `task recover` 对账" |
| `SLOT_BUSY` | 不立即重试：等 `slots.free > 0`（读 `orchestration resume --json` 或下一轮 status），然后**换新 id**（旧 id 已被记为 failed，重放只会返回失败） |
| `REQUEST_CONFLICT` | **绝不重试**。输出"该 `request_id` 已被另一 `task/action/载荷` 占用"，并打印本批已生成的 `manifest.jsonl` 中同 id 行；提示换新 id 或修正配对 |
| `STATE_CONFLICT` | 重新 `status --refresh` 后**换新 id** 重建请求（等价于 `zoe-resume.sh preview` 的语义），不自动续跑 |
| `ENVIRONMENT_ERROR` / `POLICY_*` / `AUTH_*` | 不重试，原样打印 `code`/`message`/`details`，退出码 10 |
| 传输失败 / 无响应 | 同 id 同 file 重放（幂等）；仍无响应用 `task status --refresh` 判定，不新建请求 |

**输出（同时解决 #5）**：

```text
--out/results.jsonl   每个任务一行：{"label","task_id","request_id","outcome","error_code","state","row_version","attempts"}
stdout                同一行内容（NDJSON），末尾一行汇总：
[batch] ok=3 busy=1 skipped=0 failed=0 out=…/results.jsonl
```

- 单行 JSON = 不会被后续输出"截断成最后一条"（原来只有最后一个任务的 stdout 可见，是因为宿主读的是整段 stdout 的最后一段）；
- 退出码：`0` 全部 dispatched / `10` 有需人处理项 / `2` 用法或依赖错误。

**为什么不用 UUID `request_id` 优先**：`--emit` 的 `create.json` 用 UUID 是为了"新任务重新生成"（`SKILL.md:366-367`）。批量 start 里可读 id（`<task>-start-<date>-<rand>`）能让人从 `operations` 表一眼看出错配（本轮那三行错配正是靠可读 id 才被发现）。**判错**：让脚本"从 `create.json` 里读 `request_id` 复用"——`action` 变了吗都没变不重要，`action`/`task` 进哈希，跨 action 复用必冲突。

**判错**：脚本在 `REQUEST_CONFLICT` 上自动换 id 继续（会把"文件配错任务"这个真问题掩盖成"跑过去了"）。

### S2（P0）空候选：三处信号，一处门禁

**落点**：`scripts/zoe-monitor.sh` / `.ps1`、`references/delivery-policy.md`、runtime `_pipeline.py`（P1）。

**S2-A（P0，脚本）**：`zoe-monitor.sh` 读 status 时多取两个字段（`base_sha` / `candidate_sha`），`REVIEW_READY` 分支加一行判定：

```bash
# 与 REVIEW_READY 的 [needs-human] 同处；不改退出码（仍是 10）
if [ -n "$cand" ] && [ -n "$base" ] && [ "$cand" = "$base" ]; then
  log "[needs-human] $t REVIEW_READY 但 empty_diff=true（candidate_sha == base_sha）无改动可验收"
fi
```

三条约束：

1. **两个空 SHA 不能判等**（`candidate_sha` 为空表示"还没验证过"）——与 `SKILL.md:614-616` 的既有约束一致；
2. `--stop-file` 增 `"empty_candidates": ["T9d"]`（纯增量，不改既有键）；
3. 不改 `alive` / `need_human` / 退出码语义：它仍然进 `need_human`，只是把"等验收"细分成"等验收/无内容可验收"。

**S2-B（P0，文档）**：`delivery-policy.md` 增一条硬规则：

```text
空候选不得验收：candidate_sha == base_sha 时，本次没有任何可交付改动。
accept 会通过（subject_sha == validated_sha 都等于 base_sha），这是运行时的空洞，
不是授权。除非 spec 明确写了"本次只做验证/无代码改动"，否则处置是：
重新派发（补 spec 或换 profile），不是 accept。
```

**S2-C（P1，Runtime）**：verify 收口处（`_pipeline.py:2871` 之后）加**观测**，不改状态机：

```python
empty = sha == t["base_sha"]
validated = {**t, "candidate_sha": sha, "validated_sha": sha, "empty_candidate": empty}
```

并 `store.save(..., "empty_candidate", payload={"base_sha":…, "candidate_sha":…})` 发事件；`_evidence.build` 增 `empty_candidate` 字段；`task report` 顶部显式一行 `candidate: EMPTY (== base_sha)`（现在只有 diffstat 的 `no changes`）。

**不做**：在 verify 里直接把空候选变成 `BLOCKED`。有的任务（纯文档校对、只跑 qualification、只补证据）真的零改动；硬拒会让它无路可走，而"是否允许"是验收判断，不是控制器判断。**判错**：把 `candidate_sha == base_sha` 写成"重复提交"或"worker 没干活"（也可能是 spec 要求的就是零改动）。

### S3（P0）spec 必须结构化：`allowed_paths` 到文件级

**落点**：`references/spec-template.md`（强制章节）、`references/spec.example.json`（示例改文件级）、`SKILL.md` 第 3 步、runtime `_prepare.py`（P1 诊断）。

**S3-A（文档，P0）**：模板加一节，并且**明确写"只有结构化字段生效"**：

````text
## 文件边界

本节的清单必须与结构化 spec 的 `allowed_paths` 逐条一致；Markdown 只是给人看的副本，
**运行时只读 spec.json 的 `allowed_paths`**（纯 Markdown 的 spec 会被解析成
`contract_version=1, document=null`，`allowed_paths` 完全不生效）。

- 必须修改：internal/app/publish_flow.go
- 允许新增：internal/app/publish_flow_test.go
- 禁止修改：其他任何文件（含 go.mod、注册表、入口文件、其他包）

并行批次里本节的路径必须是**文件级**；只写包名/目录等于没写（见 S3-C）。
````

同时 `spec.example.json` 的 `allowed_paths` 示例从目录级改为文件级，并给出一份并行批次的最小可复制样例。

**S3-B（文档，P0）**：`SKILL.md` 第 3 步「形成 Spec」把两条从"要写"改成"不写就拒绝 create"：

```text
- spec 必须是结构化 JSON（至少 title / allowed_paths / acceptance_criteria）；
  纯 Markdown spec 虽然能 create，但 allowed_paths 与 AC 绑定全部失效，等于放弃边界与判据；
- allowed_paths 只能收紧，且并行批次里必须到文件级。
```

**S3-C（Runtime，P1）**：`task prepare` 的 `allowed_paths.warnings[]` 增一条**警告级**条目
（不放 `diagnostics[]`：那里是"阻断/需批准"的通道，粒度提示不属于其中任何一类）：

```text
field: allowed_paths[<i>]
code: SCOPE_DIRECTORY_LEVEL
message: "'<path>' is a directory; a Worker may rewrite any file under it
          (file-level entries are what keep a parallel batch's boundaries meaningful)"
```

判据：`(repo / entry)` 存在且是目录（`_prepare` 已经有 repo 路径，能 stat）。**为什么只警告**：改整个包是合法需求，"必须文件级"只在并行批次成立，那是编排判断，不该由运行时替人决定。只对 **spec 声明的范围**报：项目级 `allowed_paths` 本来就粗，重复告警会淹没真信号。Skill 侧则把它当**阻断**处理：

```text
并行批次（同一波次 ≥2 个任务）中，prepare 出现 SCOPE_DIRECTORY_LEVEL ⇒ 不 create。
串行任务可以保留目录级，但要在 spec 里写明"本任务拥有该包"。
```

**判错**：让运行时在所有场景拒绝目录级范围（会逼人写假清单）；或只改模板不改示例（示例是最常被复制的东西，`spec.example.json` 现在正是目录级 `<FILL:…目录…>`）。

### S4（P1）合并前必须有集成验证，且优先用「任务组」

**落点**：`SKILL.md` 第 9 步 + 第 4 步、`references/delivery-policy.md`、`references/group-delivery.md`。

**S4-A（定义）**：`local_artifact` + `ci_required=false` 的项目**没有合并门禁**——`delivery-policy.md:17-21` 写的是"合并前的全量 checks 由 CI/PR 门禁执行"，本机没有 CI，`zoe-go` 就是这种项目。这是文档与现实的缺口，不是执行人的疏忽。

**S4-B（文档，必做步骤）**：`delivery-policy.md` 增「合并门禁（无 CI 时）」：

```text
无 CI 的 local_artifact 项目，合并门禁由编排会话执行，且不能省略：

1. 一次只合一个候选，合完立刻跑全量 checks（不是全部合完再跑一次）；
2. 跑在**集成分支**上，不是各任务 worktree，也不是"worker 自测过了"；
3. 记录 integration_sha + 每个 check 的 exit code + 日志路径；
4. 任一 FAIL ⇒ 停在集成分支，不进 main；修复走新任务，不改测试来迁就实现
   （除非契约变更由人确认）；
5. 报告里写「项目级验证已执行」或「未执行」，不许写"应该没问题"。
```

**S4-C（更优路径，文档）**：需要"多片 + 一次集成验收"时，**用任务组**而不是独立任务并行。组机制已经在 integration_sha 上跑组 checks 并要求 `group accept`（`_integration.run_checks(store, group, worktree, subject_sha, ...)`、`_integration.py:731-737` 校验 `subject_sha == integration_sha`），这正是 #4 缺的那一层。`SKILL.md:388` 已经写了"独立任务并行 … 集成/合并另行安排"，本轮违反了"有明确的集成本体与独立判者"这条硬前提（第 4 条），却没有人拦。

**S4-D（判据补充）**：独立任务并行的四条硬前提里，第 4 条改成可核对的形态：

```text
4. 有明确的集成本体（谁合、按什么顺序、在哪个分支）**与一次合并后检查**；
   说不出"合并后由谁跑哪条命令"的，就不要用独立任务并行，改用任务组或串行。
```

**判错**：把"worker 自测通过"当成合并依据；或把"合并后 CI 会跑"写成合并门禁（本项目没有 CI）；或合并后再改测试让 CI 变绿就宣布完成。

### S5（P1 文档 / P2 Runtime）`task logs` 空窗口的三种解释

**落点**：`SKILL.md` 第 6 步（`task logs` 用法后面）、`references/cli-contract.md`、runtime `cli.py` + `_logstream.py`（P2 字段）。

**S5-A（文档）**：紧接 `SKILL.md:586-591` 的用法块，加一张"空结果的判读表"：

```text
text/events 同时为空时，先读这三个字段再下结论，**不要**报"日志读取有 bug"：

| 判据 | 含义 | 动作 |
|---|---|---|
| `rotated: true` | 游标 offset > 文件大小（日志被截断/替换） | 用 `reset_cursor` 重新定位；这是正常现象，不是没输出 |
| `tail_start_offset == bytes` | 尾部窗口内没有换行（单条记录大于窗口） | 加大 `--tail-bytes`（上限 1048576）或 `--after run:gen:0` |
| 以上都不是，且 `text` 非空 | 窗口内只有半行/空行 | 真的没有新的**完整**记录 |
```

并明确：`bytes` 是文件总大小，不是本次读到的字节数（`CHANGELOG.md:39`）；`text` 是窗口原文，不是"投影结果"。

**S5-B（Runtime，P2，纯增量）**：快照响应增一个 `empty_reason`
（`null` / `"rotated"` / `"no_newline_in_window"` / `"no_complete_line"` / `"no_new_records"`）：

```python
# cli.py：紧跟 rotated 与 events 的计算之后
empty_reason = None
if not data:
    if rotated:
        empty_reason = "rotated"
    elif after is not None:
        # 增量读已追平：这是心跳，不是"读取失败"，也不是"没有记录"
        empty_reason = "no_new_records"
    else:
        empty_reason = "no_newline_in_window"
elif not events:
    empty_reason = "no_complete_line"
payload["empty_reason"] = empty_reason
```

比本节初稿多一个 `no_new_records`：`--after` 追平与"窗口落在单条记录里"是两件事，前者要
继续轮询、后者要加大窗口，合成一个值会让其中一边拿到错误的动作。

**S5-B 追加（Playwright 无关，监控侧同语义）**：`zoe-monitor.sh` / `.ps1` 读 `task status`
时要一次取全 `state/block_code/phase/run/ base_sha/candidate_sha/empty_candidate`。分隔符
**必须是非空白字符**（`\037`）：IFS 里只有空白字符时 `read` 会把连续分隔符当一个，缺
`block_code` 的任务会让后续字段整体左移——表现是"状态看起来正常"，比报错难查。

理由：现在要靠"`tail_start_offset=0` 与 `bytes=518018` 同时成立"这种反推才能分辨，而契约又明确要求"不报错"。加一个字段不改变任何既有语义，也不改退出码。**判错**：让 `rotated` 报错（截断是正常现象，报错会让调用方以为文件坏了）。

### S6（P2）`REQUEST_CONFLICT` 带 `details`

**落点**：`_store.py:293-296`、`311-319`、`334-336`。

现在这个码是**唯一无法自查**的失败：宿主不知道 id 被谁占了。改成显式 `Error`（`require` 只有三参，需要一个专用分支）：

```python
raise Error("REQUEST_CONFLICT", "Request ID reused with different payload",
            details={"request_id": key,
                     "existing": {"task_id": prior.get("task_id"),
                                  "action": prior.get("action"),
                                  "status": prior.get("status")}})
```

有了它，S1 的脚本才能自动给出"这个 id 属于 T9d 的 start"这种可执行提示，而不是让人去 `sqlite3` 里翻。纯增量字段，不改错误码语义。

---

## 3. 明确不做

| 项 | 理由 |
|---|---|
| 失败就换 `request_id` 重试一次（原方案 #1 的字面实现） | 对 `TASK_BUSY` 用错药（应原 id 重放）；对已落成 failed 的 op 必须换 id；对的码才做对的事（§1.2） |
| 在 `REQUEST_CONFLICT` 上自动换 id | 该码的成因是"文件与任务配错"或"跨 action 复用 id"，自动换 id 会把配置错误洗成成功 |
| 让 verify 把空候选直接判 `BLOCKED` | 零改动任务合法（只补证据、只做验证）；"是否允许"是验收判断 |
| 在 skill 里禁止目录级 `allowed_paths` | 整包改动是合法需求；只在并行批次里要求文件级 |
| 新增 `zoe-merge-check.sh` | 组机制已有 integration checks；无 CI 项目按 S4-B 的手工步骤执行，重复劳动证据不足 |
| 新增 `zoe-logs.sh` 包装 | `rotated` 判读是两行 `jq`，没有第二个调用方 |
| 用 `shared_resources` 声明同一文件来排队 | 运行时只做规范化，不产生串行化（2026-11-04 文档 §1.3） |
| 把 `task logs` 空结果当 bug 改 projection | 实测是 `rotated`；改 projection 会让真 bug 更难发现 |

---

## 4. 优先级（按"证据可信度"重排）

| 优先级 | 项 | 影响 | 依赖 |
|---|---|---|---|
| **P0** | S0 修 checks（逃出 worktree） | 不修则所有 verify 证据为假：空 diff、越界、测试挂都可能"通过" | 需用户改项目政策 + 重新 attest/rebind |
| **P0** | S3 spec 结构化 + 文件级边界 | #3 / #6 的真根因；不修则 `SCOPE_VIOLATION` 永不触发 | 无 |
| **P0** | S2 空候选信号（monitor + delivery-policy） | 避免无效合并；空候选能一路 accept | 无（脚本改动小） |
| **P1** | S1 `zoe-batch-start.sh` | #1 / #5；把手工配对换成生成器 + 按码分流 | 与 S0/S6 独立 |
| **P1** | S4 合并门禁（文档 + 优先用组） | #4 的第二层：无 CI 时的唯一拦截点 | S0（否则门禁也是假的） |
| **P1** | S3-C `SCOPE_DIRECTORY_LEVEL` 诊断 | 把"边界过粗"从人工记忆变成可见提示 | 需先确认 `_prepare` 能 stat repo |
| **P2** | S5 空窗口判读（文档 + `empty_reason`） | #7；降低"空 = 坏了"的误判 | 无 |
| **P2** | S6 `REQUEST_CONFLICT` details | #1 的可诊断性；脚本提示质量 | 无 |

与清单原优先级的差异：**#3/#6 从 P1 升到 P0**（它是越界与空候选的共同上游），**#4 拆成 S0(配置) + S4(流程)**，**#1 从"自动重试"改为"生成器 + 分流"**。

---

## 5. 验收：反例优先

| # | 反例 | 通过标准 | 覆盖 |
|---|---|---|---|
| 1 | 项目 checks 写成 `bash -c "cd <主仓库> && go test ./..."` | `prepare`/准入拒绝并指出"check 跑在 worktree 之外"；改回相对 argv 后，worktree 里改坏一个测试 ⇒ 该任务 `CHECK_FAILED` | S0 |
| 2 | spec 是纯 Markdown，写了 `## 允许路径` | `prepare` 报 `allowed_paths` 缺失/为空（`scope_source=project`），文档明确"Markdown 边界不生效" | S3 |
| 3 | spec `allowed_paths` 只有 `internal/app`，worker 改了 `internal/app/operations.go` | 要么 `SCOPE_DIRECTORY_LEVEL` 在 `prepare` 出现，要么 `task_scope` 生效后越界报 `SCOPE_VIOLATION`（二者必有一） | S3-C |
| 4 | worker 零改动跑到 `REVIEW_READY` | monitor 打 `empty_diff=true` + `empty_candidates`，汇报不得写"已完成"，accept 前必须说明零改动原因 | S2 |
| 5 | 同一 `request_id` 用到两个不同 task | 第二次报 `REQUEST_CONFLICT`，`details.existing.task_id` 指出被占用的任务；脚本不重试、输出可执行提示 | S1 / S6 |
| 6 | `TASK_BUSY`（另一写者持锁） | 脚本原 id 原载荷重放，不改 id、不产生第二个 run | S1 |
| 7 | `SLOT_BUSY`（槽位满） | 等槽位后**换新 id**；不出现"重放返回上次失败"被当成完成 | S1 |
| 8 | 四个任务批量 start，中间两个失败 | `results.jsonl` 有四行，逐条可读；stdout 末尾汇总；不存在"只有最后一个可见" | S1 |
| 9 | `task logs --after <过期游标>` | 输出 `rotated: true` + `empty_reason: "rotated"`；报告写"日志被替换"，不写"读取失败" | S5 |
| 10 | 尾部 64 KiB 是单条超长记录 | `empty_reason: "no_newline_in_window"`；文档给出 `--tail-bytes 1048576` / `--after run:gen:0` 两条出路 | S5 |
| 11 | 合并前不跑全量、合并后测试挂 | 流程判定为不合规：`delivery-policy` 的合并门禁要求"一次一合 + 合后即跑 + 记录 integration_sha" | S4 |
| 12 | 多片共享行为契约（如 `AcceptTask` 签名） | 计划阶段就应判为 `INTEGRATION_REQUIRED` 或改用任务组（组 checks 在 integration_sha 上执行） | S4 |

### 门禁

| 门禁 | 断言 |
|---|---|
| `zoe-workflows/build.py --check` | 新增 `scripts/zoe-batch-start.sh` 进 `REQUIRED_FILES`，可执行位与 `zoe.sh` 一致；`docs/` 不进包 |
| `zoe-runtime/tests/contract/test_skill_cli_contract.py` | `SKILL.md` 里出现的 `zoe` 命令/选项真实存在；**脚本用法放 `SKILL.md`，不要放进 `cli-contract.md` 的 ```text 块**（首 token 是 `bash`，会被判成未知子命令） |
| `zoe-runtime/tests/test_doc_contracts.py` | `SKILL.md` 仍含 `max_active_tasks` / `verification_scope` / `NOT_RUN` / `dispatch_pending` 等既有词；新增禁用短语不回归 |
| 新增 runtime 测试 | `empty_candidate` 事件与字段、`REQUEST_CONFLICT.details`、`empty_reason` 三分支（rotated / no_newline / no_complete_line）各一例 |

### 负向文案断言（写文档的人要自查）

1. 不出现「失败就换 `request_id` 重试」这种无条件表述；
2. 不出现「`REQUEST_CONFLICT` 重试即可」；
3. 不出现「Markdown 里写 `## 允许路径` 就会限制 Worker」；
4. 不出现「worker 自测通过 = 可以合并」；
5. 不出现「`task logs` 为空说明卡住 / 说明读取有 bug」；
6. 不出现「同一 `request_id` 可以跨 action 复用」。

---

## 6. 风险与边界

1. **S0 会改项目政策**：`checks` 参与 `policy_digest`，改完在途任务一律 `POLICY_CHANGED`，需 `register` → `attest` → `rebind`。必须在用户明确同意后执行，脚本不得代为完成。
2. **S0 修好之后，历史证据全部作废**：T9/T8 那些 `REVIEW_READY` 的 `test: PASS` 不能再被引用。要么对未合并的候选重新验证，要么在报告里写"证据产生于 checks 错误配置期，不可作为通过依据"。
3. **S1 的自动重试仍有窗口**：`status --refresh` 与 `start` 之间的状态可能变化（TOCTOU）。脚本降低人工错误，**不提供原子互斥**；真正的互斥只有每个任务的写者锁。
4. **S2 只是信号**：`empty_candidate` 不改变 `REVIEW_READY`、不拦 `accept`。拦人的地方是验收政策（S2-B），不是控制器。
5. **S3-C 只覆盖"目录 vs 文件"**：它判断不了"这个文件是不是另一个在途任务也要改"——那是跨任务重叠预检（`SKILL.md` 第 4 步），两者不能互相替代。
6. **S4 不能靠 skill 脚本保证**：无 CI 时的合并门禁是**会话纪律**，脚本无法证明"人真的跑了"。可核查的证据只有 `integration_sha` + check 日志，报告必须逐条列出。
7. **S5 不改判定口径**：`empty_reason` 是解释性字段，不改变"日志静默 ≠ 卡住"这条既有纪律。
8. **不新增 Zoe 子命令**：S1 是 skill 脚本；S2/S5/S6 是字段级增量；没有一条要求扩展 `task` 的命令面。

---

## 7. 附：关键锚点

```text
zoe-runtime@1.5.2
src/_store.py:275-288            _operation_key  → key=request_id, hash=digest([action,task,request])
src/_store.py:290-322            operation()     → 任何非 intent 状态都返回 prior（失败记录会被重放）
src/_store.py:293-296,311-319    REQUEST_CONFLICT（无 details）
src/_pipeline.py:1135-1162       start()         → prior/intent 走 _replay；TASK_BUSY 有界重探 1s
src/_pipeline.py:1165-1171       _start_locked   → writer 锁在写 intent 之前（TASK_BUSY 不烧 id）
src/_pipeline.py:955-979         lifecycle_locks → SLOT_BUSY/TASK_BUSY 归一成 TASK_BUSY
src/_pipeline.py:1245-1257       SLOT_BUSY 判定（在 intent 之后 ⇒ 会烧 id）
src/_pipeline.py:1473-1479       store.finish(status=failed) ⇒ request_id 被烧
src/_pipeline.py:2841-2873       verify 收口：if staged 才 commit；sha 可能 == base_sha；无可空候选判定
src/_pipeline.py:2931-2940       phase=acceptance → REVIEW_READY（无证据校验、无 SHA 差异检查）
src/_pipeline.py:3077-3081       accept 校验 subject_sha == validated_sha（空候选满足）
src/_pipeline.py:1777-1864       run_checks → backend.execute(cwd=workspace)，但 argv 可自行 cd
src/_pipeline.py:363-381         _resolve_task_scope → declared=None ⇒ "project"
src/_contracts.py:201-207        validate_spec_text → 非 JSON ⇒ (1, None)
src/_contracts.py:90-114         spec_scope → document["allowed_paths"]
src/_backend.py:574-576          spawn cwd = t["workspace"]
src/_backend.py:641-649          scope() → task_scope or config.allowed_paths
src/cli.py:1015-1069             task logs 快照（bytes 是文件大小，text 是窗口原文）
src/cli.py:1037-1049             --after offset > size ⇒ rotated=True ⇒ data=b""（text/events 空）
src/_logstream.py:227-252        window_start：窗口内无换行 ⇒ 返回 size（另一种空窗口）
src/_logstream.py:38-48          DEFAULT_TAIL_BYTES=65536 / MAX_TAIL_BYTES=1MiB / MAX_SNAPSHOT_EVENTS=200
src/_reports.py:177-188          _diff_stat → "no changes"（仅展示）
src/_config.py:1143-1155         authorize：authorization_ref 必须等于冻结配置

zoe-workflows
SKILL.md:366-367                 "同一任务重试复用原值"（仅对"结果未知"成立，见 §1.2）
SKILL.md:614-616                 两个空 SHA 不能判等
SKILL.md:388 / 394-405          独立任务并行 vs 任务组的收口；四条硬前提（第 4 条=集成本体）
references/delivery-policy.md:17-21   "合并级全量由 CI/PR 门禁执行"（无 CI 项目缺门禁）
references/cli-contract.md:567,579    rotated / reset_cursor 语义（不报错）
references/spec-template.md     无「文件边界」章节；未说明 Markdown 边界不生效
references/spec.example.json    allowed_paths 示例为目录级
scripts/zoe-monitor.sh:256-273  已处理 rotated（丢弃展示游标），不读 base/candidate SHA
scripts/zoe.sh                  只做定位/预检/转发，无重试
build.py:31-38,45+              WHITELIST / REQUIRED_FILES（新脚本须补登）

项目侧（本机 zoe-go，2026-11-05）
checks[build|vet|test].argv    bash -c "cd /Users/…/zoe-go && …"（逃出 worktree）
task-d17eef0cf4224e14 (T9d)    base == cand == 574563c7，REVIEW_READY
task-b62dcda3e3e04567 (T8f)    base == cand == d1b0dc4b，REVIEW_READY
task-179d9224b8db4cb7 (T9b)    evidence: test=PASS；worktree 实测 TestA21=FAIL
operations 表                  t9a-start-20261105 → T9d；t9a-start-v2 → T9a（id/任务错配）
zoe-go 合并图                   c44d496 "Merge T9a…" 第二父提交是 ee624b4（T9b）
```

## 8. 实施记录（2026-11-05）

本节记录本文各项落地到哪个文件、怎么验的，以及与初稿的偏差。

### 8.1 代码落点

| 项 | 文件 | 改法 |
|---|---|---|
| S0 配置 | `~/.local/share/zoe/projects/zoe-go.json` | `checks[*].argv` 去掉 `bash -c "cd <主仓库> && …"`，改成 `["<go 绝对路径>", "build\|vet\|test", "./..."]`；原文件备份为 `zoe-go.json.bak-20261105` |
| S0 准入 | `zoe-runtime/src/_prepare.py` | 新增 `_pinned_cwds()` + 诊断 `CHECK_ESCAPES_WORKSPACE`（进 `BLOCKING`，令 `prepared=false`） |
| S1 | `zoe-workflows/scripts/zoe-batch-start.sh`（新增） | 生成请求文件 + 绑 manifest + 按码分流（`TASK_BUSY` 同 id 重放、`SLOT_BUSY` 换新 id、`REQUEST_CONFLICT` 不重试）+ `results.jsonl` 逐条落盘 |
| S1 打包 | `zoe-workflows/build.py` | `REQUIRED_FILES` 与可执行位清单登记新脚本 |
| S2-A | `zoe-workflows/scripts/zoe-monitor.sh` / `.ps1` | `REVIEW_READY` 时判 `empty_candidate`（或两个非空 SHA 相等）⇒ 打印 `empty_diff=true` + 写 `empty_candidates` 到 `--stop-file` |
| S2-B | `references/delivery-policy.md` | 新增「空候选」「合并门禁（无 CI 时）」两节 |
| S2-C | `src/_pipeline.py`、`src/_evidence.py`、`src/_reports.py` | verify 计算并写入 `empty_candidate`、发 `empty_candidate` 事件、证据与报告带该字段、`revise`/`rebind`/重新指派复位 |
| S3-A/B | `references/spec-template.md`、`references/spec.example.json`、`SKILL.md` 第 3 步 | 新增「文件边界」强制章节；示例 `allowed_paths` 改文件级；写明"纯 Markdown spec ⇒ `document=null` ⇒ 边界不生效" |
| S3-C | `src/_prepare.py` | `allowed_paths.warnings[]` 增 `SCOPE_DIRECTORY_LEVEL`（只对 spec 声明范围） |
| S4 | `SKILL.md` 第 9 步 + `references/delivery-policy.md` | 合并门禁五条（一次一合、合后即跑、集成分支、记 `integration_sha`、不许改测试迁就）+ 共享契约改用任务组 |
| S5 | `src/cli.py`、`SKILL.md` 第 6 步、`references/cli-contract.md` | 快照增 `empty_reason`（四取值）；文档给判读表 |
| S6 | `src/_store.py` | `REQUEST_CONFLICT` 带 `details.existing{task_id,action,status,created_at}`（三处触发点共用 `_operation_conflict`） |
| 版本 | `src/__init__.py`、`CHANGELOG.md` | 1.5.3；`runtime-requirements.json` 的 `min_version` **仍为 1.5.2**（新字段全部可降级使用，不强制升级） |

### 8.2 验证

| 项 | 结果 |
|---|---|
| `zoe-runtime` 全量测试（含跨仓契约与文档门禁） | `1075 passed, 7 skipped` |
| 新增 `tests/test_v153_candidate_truth.py` | 22 passed：冲突占用者、零候选标注/证据不变量、`empty_reason` 四取值、两条 `prepare` 判据、监控零候选 |
| 新增 `tests/test_v153_batch_start.py` | 12 passed：按码分流与派发前闸门 |
| `zoe-workflows/build.py --check` | 通过 |
| 现场（1.5.3 已重装） | `task logs` 正常窗口 `empty_reason=null`；越界游标 → `rotated`；`--after` 追平 → `no_new_records` |
| 现场（S0） | 修配置后 `task prepare --project zoe-go --spec …` 返回 `prepared=true`、`diagnostics=[]`、`scope_source=spec`；同一 spec 下的旧配置会以 `CHECK_ESCAPES_WORKSPACE` 阻断（单测覆盖） |
| S0 有效性反证 | 在 T9b 的 worktree 里按新 argv 跑 `go test ./internal/app -run TestA21` → **FAIL**；同一命令旧配置时被 `cd` 送去了主仓库并记为 PASS |

### 8.3 与初稿的偏差

1. **S0 准入从 skill 侧改到 runtime `prepare`**：`prepare` 已是"一次看全"的唯一闸门，做在那里对所有项目生效，也不依赖宿主的实现语言。
2. **S3-C 放 `allowed_paths.warnings[]` 而非 `diagnostics[]`**：`diagnostics[]` 是"阻断/需批准"的通道，粒度提示不属于任何一类；放进警告通道也避免让"干净 prepare"的既有断言失真。
3. **S5-B 多一个 `no_new_records`**：`--after` 追平与"窗口落在单条记录里"的正确动作不同（继续轮询 vs 加大窗口），不能合并成一个值。
4. **没有新增 capability 名**：新字段全部可降级（Monitor 会退回比较两个 SHA），因此不动 `SUPPORTED_CAPABILITIES`，也不抬 `min_version`。

### 8.4 仍需人工完成（不可代为执行）

1. **`zoe project attest`**：改 `checks` 会改变 `policy_hash`，`zoe-go.attest.json` 记录的是旧
   hash ⇒ 下一次派发会报 `ALLOWLIST_UNCONFIRMED`。白名单本身没变（`cb-pro`/`cb-flash`/`cb-run`），
   但"确认"这个动作按设计只能由人做：

   ```bash
   zoe project attest --dry-run --project zoe-go --expect-policy-hash <新 hash>
   # 把 execution[] 展示给用户确认后，再去掉 --dry-run 执行
   ```

2. **在途任务的 `rebind`**：`POLICY_CHANGED` 出现在 `resume` / `revise` / `rebind` 时，逐个
   `task rebind`（旧证据失效）。`REVIEW_READY` 的 T9a/T9c 若要 `accept`，先确认它们的证据是否
   在错误配置期产生。
3. **历史证据作废**：T8/T9 各任务在 2026-11-05 之前的 `test: PASS` 不可再引用（§0.2）。未合并的
   候选要重新验证，或在报告里标注"证据产生于 checks 错误配置期"。
4. **`SCOPE_DIRECTORY_LEVEL` 的并行批次阻断**：运行时只告警，是否阻断取决于本次是否并行——
   这条由编排按 `SKILL.md` 第 3 步执行，脚本无法代替判断。
