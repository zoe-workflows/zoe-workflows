# 并发执行工程化加固方案（v2.1）

| 项 | 内容 |
|---|---|
| 日期 | 2026-11-04 |
| 输入 | 《T2 并发执行评估》7 条问题 + 11 条建议（v1）；外部评审（2026-11-04）7 条必改 + 8 条优化 |
| 被改对象 | `$ZOE_HOME/projects/zoe-go.json`；`zoe-go` 项目 checks；`zoe-workflows` 文档 |
| 改 runtime | **否**（v2 收窄：优先配置与文档修复；只在"重验路径不适用"时登记 runtime 缺陷，见 6.2） |
| 方法 | 先核实争议点 → 再逐条判定采纳/改写 → 给可判错的验收 |
| 本文位置 | `zoe-workflows/docs/`（不在 `build.py` 的 `WHITELIST` 内，不进入发布包） |
| 核验状态 | 标"已核验"的项在本机实测或读代码确认；行号/行数为 2026-11-04 快照，**以符号名为准** |

## 修订记录

| 版本 | 变化 |
|---|---|
| v1 | 首版。3 条输入问题改写判定，新增 D8–D11 |
| **v2** | 依评审修正 7 处必改：①B0 改为「冻结证据缺陷 → `rebind` 重建证据」，**旧 checks 的通过记录不得用于补验收**；②监控模板重写（起始游标 / 目标集合 / 状态词表 / 退出码 / 先消费后推进 / 延迟口径）；③组推进责任（`watch` 不推进，只有 `group start`/`resume` 推进）；④模型身份改三层证据，**不降级 `cost_class` 规避 pin**；⑤`cb-run` 白名单分两阶段；⑥`go test` 纳入；⑦一致性备份与恢复语义。另采纳 8 条优化建议，见 0.1 |
| **v2.1** | 落地后的实测修订（见第 9 节）：①`zoe-go` **实际有测试**（9 个包通过 / 4 个包无测试文件），撤回 v1/v2 的"无测试文件"表述；②实测 CLI 只在 `providerData.model` 报告 `deepseek-v4.1-flash`，而 runtime 的 `model_of` 不读该字段 ⇒ `model_identity` 恒为 `unobserved`，`pin_model` 在本环境**永久不可用**（不是"校准一次"），故 Pro 档改为 `standard` 并在 `description` 如实登记真实成本；③记录配置落地、attest、4 个任务重验及 1 次 `PROCESS_UNKNOWN` 事故的处置 |
| **v2.2** | 独立审查后的修正（见第 10 节）：①3.4.2 监控模板修 3 处实质缺陷（游标文件只写不读会跳过停机事件、全部目标需人介入时死循环、`zoe` 失败被 `jq` 掩盖）；②3.4.3 补 `task logs --log` 缺省 `agent` 的前提（重验 run 会 `INPUT_INCOMPLETE`）；③3.3.5 负向验证改为**临时 worktree**，避免污染任务指纹；④9.5 的 `expected_version` 改为现取（原文 `24` 与实际 `18/23` 不符）；⑤9.3 降级为"代码推断 + CLI 实测"，注明 L2 未在 runtime 观测；⑥3.2.6 补 `task_type` 只认 `route` 块 / `spec.document`；⑦补 `runtime-contract.md` 的示例值说明；⑧新增 9.4"未验证"清单 |

---

## 0. 结论

三个缺口的判定不变，但**修复路径变了**：v1 让 B0 抢在 B2 前"补验收"，这等于用被污染的检查结果做验收，与 v1 自己的 P0 判定冲突。v2 把 B0 改成「先冻结证据缺陷，再用 runtime 的 `rebind` 重验路径重建证据」。

| 缺口 | 实质 | 严重度 |
|---|---|---|
| 验证对象错误 | check 里 `cd` 回主仓库，3 个并发任务构建的是 main，不是各自 worktree | **P0（假绿）** |
| 历史验收无有效证据 | 4 个任务 `REVIEW_READY`；其 checks 结果**不能证明 worktree 被验证过** | **P0（证据污染）** |
| 模型身份未确认 | `allow_cli_default_model: true` ⇒ `model_unresolved=true`，只能证明"配置没写模型" | P1（证据边界不清） |

对 v1 结论的修正：

> ~~并发跑通了，但模型没固定、验证验错了对象、合并没有留痕~~
> 改为：**并发跑通了，但验证对象错误导致 4 个任务的检查结果不可信；模型身份只到"配置未指定"这一层；修复的正确顺序是"冻结缺陷 → 修正配置 → 重验 → 验收"，不是"先补验收再改配置"。**

### 0.1 评审意见判定

| # | 评审意见 | 判定 | 落点 |
|---|---|---|---|
| 1 | B0 与 B2 冲突，旧检查结果不能补验收 | **采纳（加重）** | 3.1；并给出 runtime 已有的 `rebind` 重验路径 |
| 2 | 监控模板有 6 处缺陷 | **采纳（全部）** | 3.4 重写 |
| 3 | "继续 follow" 不能推进组执行 | **采纳（已核实）** | 3.5.2 |
| 4 | 混淆"模型已配置"与"身份已确认" | **采纳** | 3.2.5 三层证据 |
| 4b | 不要用 `cost_class: standard` 绕过 pin | **采纳** | 3.2.4；改为请求级 `pin_model` |
| 5 | 历史 profile 不应留在新任务候选集 | **部分采纳（顺序修正）** | 3.2.7：直接移除会让历史任务 `rebind` 失败 |
| 6 | "无测试所以不加 `go test`" 不合理 | **采纳** | 3.3.3 |
| 7 | `cp state.db` 不是一致性备份；恢复不是撤销验收 | **采纳** | 3.1.6、5.13 |
| 8 | 标题"不改 runtime"应收窄 | **采纳** | 头部表、6.2 |
| 9 | `task_type` 表示类别不表示难度 | **采纳** | 3.2.6 |
| 10 | B2 应记录候选 SHA / 指纹 / Go 路径 / GOWORK | **采纳** | 3.3.4 |
| 11 | 需在最终合并结果上做集成检查 | **采纳** | 3.5.5 |
| 12 | 吞吐验收要重叠记录与总耗时 | **采纳** | 7.1 |
| 13 | 未验收任务不应移出分母 | **采纳** | 3.1.7 |
| 14 | v1.5.0 vs "v1.3 组语义" 引用混乱 | **采纳** | 3.5.1 |
| 15 | CLI 示例需要可执行检查 | **采纳为建议** | 3.6 |

---

## 1. 事实基线（已核验）

### 1.1 环境

| 项 | 实测值 | 说明 |
|---|---|---|
| `zoe --version` | `1.5.0` | `/Users/liuzhupeng/.local/bin/zoe` |
| `codebuddy --version` | `2.111.0` | 与配置 `expected_version` 一致 |
| `go` | `go1.27.3 darwin/arm64` | 在 PATH |
| `runtime-requirements.json` | `min 1.5.0 / max <2.0.0`；能力含 `group_serial_execution` | 组串行是**本版声明能力**，不是 v1.3 残留 |
| `ZOE_HOME` | 默认 `~/.local/share/zoe` | 未被环境变量覆盖 |

### 1.2 现有项目配置

| 字段 | 当前值 | 问题 |
|---|---|---|
| `default_agent_profile` | `cb-run` | 单档 |
| `cb-run.allow_cli_default_model` | `true`，且无 `model` | `model_unresolved=true` |
| `routing` | 缺失 | `explicit` 模式，永远只用默认 profile |
| `checks[0].argv` | `["bash","-c","cd /Users/.../zoe-go && .../go build ./..."]` | 验证对象错误 + 预检只能判 `shell` |
| `max_active_tasks` | `3` | 主动计数全局，见 1.7 |
| `authorized_actions` | `create` / `execute` / `accept` | `close-external` 只需要 `execute`（已核实用任务冻结 config 授权） |

### 1.3 任务现状

| task_id | state | 关键字段 |
|---|---|---|
| `task-0234ce049bbc447e` | `REVIEW_READY` | 无 `group_id`，profile `cb-run` |
| `task-24b05cd1095149f3` | `REVIEW_READY` | 同上 |
| `task-5a433b16253b4da5` | `REVIEW_READY` | 同上 |
| `task-c442d52b9aa44ca2` | `REVIEW_READY` | 同上 |

四个任务的 `validation.json` 由**错误的 checks** 生成，按 3.1.1 判定为不可信证据。

### 1.4 改前 doctor 基线（2026-11-03 实测）

```json
{
  "ready": true,
  "resolution": {"path": "/opt/homebrew/bin/codebuddy", "source": "process-path", "version": "2.111.0"},
  "checks_preflight": [{
    "check_id": "build", "argv0": "bash", "status": "shell",
    "inner_command": "unverified",
    "hint": "shell form: only the shell itself is verified; the inner command cannot be resolved statically"
  }],
  "policy_problems": [], "placeholders_ok": true
}
```

`ready: true` 与"检查可信"是两件事：`shell` 放行，所以内层 `go build` 从未被静态验证。

### 1.5 `rebind` 的重验路径（v2 的关键依据，已核验）

策略变更后，`rebind` 不只清证据，还会判断"产物是否还在、能否就地重验"（代码注释 F1）：

| 条件 | 判定 |
|---|---|
| `workspace` 存在，`HEAD == candidate_sha`，`fingerprint` 未变 | 产物完整 |
| `delivery_mode in ("local_artifact", "group_member")` | 可本地重验 |
| `block_code != PROCESS_UNKNOWN` | 写者已收口 |
| 无活跃 run | 无并发写者 |

全部满足 ⇒ `rebind` 把任务置为 `state=READY, phase=verify`，写 `revalidation.pending=true`，清空 `validated_sha` / `validated_fingerprint` / `current_evidence_id` / `acceptance`，并返回 `recommended_action="resume"`。

随后 `task resume`（与 `task start` 同一函数）从 `phase=verify` 进入，**只重跑 checks 并重签证据，不重启 agent**。

这不满足时（工作区被改动）⇒ `BLOCKED / WORKSPACE_CHANGED`，写明 "revalidation basis lost"，不得产出一份对不上的证据。

### 1.6 组推进的进程模型（已核验）

`group start` 的行为是 **preflight → 铸租约 → spawn 后台推进器 → 立即返回**：

```text
zoe group start GID
  └─ 父进程：accepted: true, completed: false  ← 立即返回
       └─ 子进程：python -m src ... internal-group GID LEASE   ← 真正推进的人
```

- 子进程退出即**停止推进**（不是守护服务）；
- 恢复推进只有两条命令：`group start`（READY/PAUSED/BLOCKED）与 `group resume`（PAUSED/BLOCKED/RUNNING/READY，会先 `reconcile` + 重新 preflight + 换新租约）；
- `group status --refresh` 是**有界对账**，不是推进；
- `watch` 只读事件表，**不推进任何任务或组**。

结论：**"继续 follow"不能代替推进。** 观察与推进是两条命令，v1 的 3.5.4 写错了。

### 1.7 并发与统计口径（已核验）

| 事实 | 影响 |
|---|---|
| 活跃任务跨项目全局计数，限额取派发项目 | 本项目配 3 不等于独占 3 个槽位 |
| `accept` 要求 `policy_digest(任务冻结 config) == digest(当前项目 config)` | 改配置后未收口任务全部 `POLICY_CHANGED` |
| `close-external` 用**任务冻结 config** 授权，终态 `CANCELLED`，`block_code=CLOSED_EXTERNAL`，`accepted: false` | 改配置后仍可对历史任务记账 |
| `state migrate` 用 `sqlite3.Connection.backup()` 生成 `backups/state-v{N}-{ts}.db` | 这是本项目内已有的一致性备份实现 |

### 1.8 备份机制（已核验）

- `state migrate` 的备份走 SQLite Backup API（`db.backup(target)`），不是文件复制；
- `state restore --from <dir> --confirm` 只接受**备份目录**格式；
- `zoe state` 没有 `backup` 子命令，也没有"单文件快照"入口。

因此 v1 附录里的 `cp state.db` 不是一致性备份，已删。

---

## 2. 缺陷判定

| # | 缺陷 | 判定 | 来源 |
|---|---|---|---|
| D1 | 单 profile + `allow_cli_default_model` | `model_unresolved=true`，只能证明"配置未指定" | v1 |
| D2 | 监控靠 sleep + status | 能力已有，缺模板与口径 | v1 |
| D3 | 手工 merge 无验收记录 | 成立；但补验收需先解决 D5 | v1 → **v2 加重** |
| D4 | "3 个任务应该是组" | 组是串行，不能承担并发吞吐 | v1 |
| D5 | check 里 `cd` 回主仓库 | **假绿**：构建对象不是任务产物 | v1 |
| D6 | 未读多模型示例 | 示例有 2 处照抄会失败的写法 | v1 |
| D7 | `expected_version` 漂移 | **不成立**，实测一致 | v1 |
| D8 | `max_active_tasks` 语义误读 | 全局计数 | v1 |
| D9 | 组示例 `task_type: "api"` | 不在词表，照抄即拒 | v1 |
| D10 | `--follow` 不回传 `next_cursor` | 宿主需自行拼游标或改用有界查询 | v1 |
| D11 | `task logs --jsonl` 不存在 | 示例会 exit 2 | v1 |
| **D12** | **用旧 checks 结果补验收** | **v1 自身的设计错误**：`subject_sha` 相同不能证明验证过程正确 | v2 |
| **D13** | **"follow 就是监控 + 推进"** | `watch` 不推进组，v1 的 3.5.4 责任错位 | v2 |
| **D14** | **把 `model_unresolved=false` 当身份证明** | 只到"配置已指定"一层 | v2 |
| **D15** | **`cp state.db` 当备份** | WAL/活跃连接下不一致；恢复整库会波及其他项目 | v2 |

---

## 3. 方案批次

### 3.1 B0 证据缺陷冻结与重建（重写）

#### 3.1.1 为什么旧证据不能补验收

四个任务的 `validation.json` 是错误 checks 的产物：`cd` 到主仓库后构建的是 main。**这些 PASS 只证明"当时的主仓库能构建"**，与任务 worktree 无关。v1 把"合并前 build/vet 通过"写进 `accept` 的 `evidence` 字段，等于把污染物当证据存档。

`subject_sha == validated_sha` 解决不了这个问题：它只校验"要验收的提交 == 被验证的提交"，而错误在于**验证过程本身没有看这个提交**。

因此 B0 的第一动作不是 accept，是**冻结并登记缺陷**。

#### 3.1.2 冻结：先把缺陷写进记录

对每个任务记录三项，供之后对照：

| 字段 | 取值 |
|---|---|
| `candidate_sha` | `zoe task status <id> --json` 的 `candidate_sha` |
| `validated_sha` | 同上 |
| 证据判定 | `invalid: check_cwd_pointed_at_main_repo` |

冻结不是命令，是一份人工清单（建议落到 `docs/evidence-freeze-2026-11-04.md`），因为 runtime 没有"标记证据无效"的命令。**不要**为了让它看起来干净去 `accept`。

#### 3.1.3 重建路径 A（推荐）：`rebind` → `resume` → `accept`

前提是 1.5 的四条全部满足。检查顺序：

```bash
# 1) 每个任务读状态与身份
zoe task status task-0234ce049bbc447e --json \
  | jq '{state, candidate_sha, validated_sha, validated_fingerprint, delivery_mode, block_code}'
```

四条都要对上：

- `state` 为 `REVIEW_READY`（非终态，可 `rebind`）；
- `delivery_mode` 为 `local_artifact`；
- `block_code` 不是 `PROCESS_UNKNOWN`；
- 任务 worktree 的 `HEAD == candidate_sha` 且工作树指纹未变（`rebind` 会自己复核，这里只是提前排雷）。

然后（**在 B2 改完 checks 并 attest 之后**）执行：

```bash
# 2) 接纳新策略（清证据、置 READY/verify、给 pending 标记）
zoe task rebind task-0234ce049bbc447e --request-file rebind-0234.json
```

```json
{
  "schema_version": 2,
  "request_id": "<uuid4>",
  "expected_version": 8,
  "authorization_ref": "local-session-zoe-go",
  "reason": "checks 已修正为在任务 worktree 内构建，旧证据因验证对象错误作废，需要重验",
  "target_policy_hash": "<新配置的完整 digest>"
}
```

`target_policy_hash` 必须**逐字等于当前项目配置摘要**（不是 16 位 `policy_revision`），由 `project diff` 或 `register` 输出给出。不等 ⇒ `POLICY_CHANGED`。

```bash
# 3) 只重跑 checks，不重启 agent（revalidation.pending=true 时）
zoe task resume task-0234ce049bbc447e
```

```bash
# 4) 确认新证据来自新 checks
zoe task report task-0234ce049bbc447e
```

`report` 里要看：`current_evidence_id` 是新生成的；`checks[].id` 是 `build`/`vet`/`test`；`checks[].fingerprint` 与本次候选一致。

```bash
# 5) 证据通过 + 人工审查完成后才验收
zoe task accept task-0234ce049bbc447e --request-file accept-0234.json
```

`accept` 的 `evidence` 字段写**新证据**（`current_evidence_id` + 重验时间 + 审查人），不写"合并前 build 通过"。

如果 `rebind` 返回 `revalidate.pending=false`：`blockers` 非空说明卡在别的条件（活跃 run、
`PROCESS_UNKNOWN`、远端交付模式）；`block_code=WORKSPACE_CHANGED` 说明产物基准已丢（工作区
被改动，**首次** rebind 也一样）。两条都说明这条路走不通，转 3.1.4。

#### 3.1.4 重建路径 B：外部收口（不追补为成功交付）

任务已外部合并、worktree 不可复原、或用户不愿重跑时，用已有的 `close-external` 记账，而不是 `accept`：

```json
{
  "schema_version": 2,
  "request_id": "<uuid4>",
  "expected_version": 9,
  "authorization_ref": "local-session-zoe-go",
  "reason": "改动经由人工分支合并进入 main，Zoe 未验证该候选",
  "external_ref": "main",
  "merged_sha": "<合并提交 sha>",
  "actor": "liuzhupeng",
  "claim": "verified"
}
```

`claim` 二选一：

| 值 | 含义 |
|---|---|
| `verified` | 人工核对过 main 上的提交确实是该任务产物 |
| `asserted` | 仅用户口头声明，未经核对 |

结果固定为 `state=CANCELLED`、`block_code=CLOSED_EXTERNAL`、`accepted:false`、`note="closed outside Zoe; not accepted"`。**这是记账，不是验收**；报告必须写"外部合并、未获平台验收"。

#### 3.1.5 禁止项

| 禁止 | 原因 |
|---|---|
| 用旧 `build/vet` PASS 作为 `accept` 的 evidence | 污染物归档（D12） |
| 用 `task cancel` 代替 `close-external` | `cancel` 不记录外部交付事实，读者无法区分"放弃"与"外部已合并" |
| 用 `task revise` 伪造一次新运行来"洗白"证据 | `revise` 改的是 spec 目标，不是验证口径；旧证据失效但新证据仍来自错误 checks |
| 为了让 `accept` 通过而临时把 checks 改回 `bash -c` | 等于把 P0 缺陷固化 |

#### 3.1.6 备份：一致性，而不是复制文件

改动前做一次一致性备份（任一）：

```bash
# 方式 1：SQLite 自带 backup 命令（走 Backup API）
sqlite3 ~/.local/share/zoe/state.db ".backup '$HOME/zoe-backup-$(date +%Y%m%d%H%M%S).db'"
```

```bash
# 方式 2：Python backup API（无 sqlite3 CLI 时）
python3 - <<'PY'
import sqlite3, pathlib, time
src = pathlib.Path.home() / ".local/share/zoe/state.db"
dst = src.with_name(f"state.db.bak.{int(time.time())}")
with sqlite3.connect(src) as s, sqlite3.connect(dst) as d:
    s.backup(d)
print("backup:", dst)
PY
```

同时记录：项目配置摘要（完整 digest）、`state.db` 的 `user_version` 与 `epoch`、备份文件大小。

**恢复的定位**：`state restore --from <dir> --confirm` 是**灾难恢复**，不是"撤销验收"的常规手段——恢复整库会连带抹掉其他项目在同一时间段的新记录。**撤销验收没有常规命令**，只有"记录被拒绝 + 走 `revise` 重开"。

**"恢复旧配置 + `rebind`"也不是回滚**（修正 v1 的"回滚"建议）。四者是不同对象，恢复文件只影响其中一件：

| 对象 | 存在哪 | 恢复旧文件是否复原 |
|---|---|---|
| 项目配置 | `$ZOE_HOME/projects/*.json` | 是，但摘要变化后需重新校验 |
| 授权确认记录 | `state.db`（绑定旧摘要） | 否——旧记录的 `policy_hash` 对新配置无效，必须重新 `attest` |
| 任务冻结配置 | `tasks/<id>/` 与任务行 | 否——`rebind` 已改写 `config`/`selected_execution`，只保留 `last_block` |
| 任务证据 | `tasks/<id>/runs/*/validation.json` | 否——`rebind` 已清 `validated_sha` / `current_evidence_id` |

因此回滚的正确表述是"恢复到旧策略后，仍需 `attest` 并对受影响任务重新 `rebind` + `resume`"，不是"改回文件就恢复了"。

#### 3.1.7 统计口径（修正 v1）

v1 说"把这批数据排除在交付率统计之外"——这是美化。正确做法是**单列、保留在分母**：

| 桶 | 含义 |
|---|---|
| `accepted` | 有有效证据 + 人工验收 |
| `external_closed_verified` | `close-external` 且 `claim=verified` |
| `external_closed_asserted` | `close-external` 且 `claim=asserted` |
| `evidence_invalid` | 有产物但证据不可信、且尚未重验 |
| `pending_acceptance` | 停在 `REVIEW_READY` |

交付率 = `accepted / (accepted + external_closed_* + evidence_invalid + pending_acceptance)`。分母不剔人。

口径来源：runtime 的 `performance` 只单列 `tasks_pending_acceptance`；`external_closed_*` 要按
任务记录的 `external_close.claim`（`verified`/`asserted`）汇总，`evidence_invalid` 要按
`validation.json` 与任务的 `validated_fingerprint`/候选身份判定。两者都不在聚合里，报告时不能
用 `tasks_cancelled` 笼统代替。

---

### 3.2 B1 执行组合分级

#### 3.2.1 目标（收窄表述）

> 让每个新任务**显式指定模型**，并核验 **CLI 自报身份**；不承诺"证明服务端实际用了该模型"。

#### 3.2.2 配置改动

```json
"default_agent_profile": "<用户批准的默认档>",
"agent_profiles": {
  "cb-run": { "...": "原样保留：历史任务绑定它，重验前不能删" },

  "cb-pro": {
    "adapter": "codebuddy",
    "backend": "codebuddy-cli",
    "expected_version": "2.111.0",
    "permission_profile": "isolated-edit-and-run",
    "require_permission_binding": true,
    "credential_refs": [],
    "network_profile": "none",
    "compatibility_evidence": "",
    "model": "<待确认：Pro 的实际模型 ID>",
    "cost_class": "premium",
    "description": "状态机/对账/并发/发布链路。依据：尚未验证。"
  },

  "cb-flash": {
    "adapter": "codebuddy",
    "backend": "codebuddy-cli",
    "expected_version": "2.111.0",
    "permission_profile": "isolated-edit-and-run",
    "require_permission_binding": true,
    "credential_refs": [],
    "network_profile": "none",
    "compatibility_evidence": "",
    "model": "<待确认：Flash 的实际模型 ID>",
    "cost_class": "low",
    "description": "文档、测试补全、格式化、机械重构。依据：尚未验证。"
  }
},
"routing": {
  "schema_version": 1,
  "mode": "auto",
  "allowed_profiles": ["cb-pro", "cb-flash", "cb-run"],
  "rules": [
    {"task_type": "review",   "prefer": ["cb-pro"]},
    {"task_type": "feature",  "prefer": ["cb-pro"]},
    {"task_type": "bugfix",   "prefer": ["cb-pro"]},
    {"task_type": "refactor", "prefer": ["cb-pro"]},
    {"task_type": "docs",     "prefer": ["cb-flash"]},
    {"task_type": "test",     "prefer": ["cb-flash"]},
    {"task_type": "chore",    "prefer": ["cb-flash"]},
    {"task_type": "*",        "prefer": ["cb-pro"]}
  ],
  "fallback": "default_profile"
}
```

#### 3.2.3 三个硬约束

| 约束 | 违反后果 | 依据 |
|---|---|---|
| `model` 与 `allow_cli_default_model` 不能同时出现 | `INPUT_INCOMPLETE` | `_profiles.normalize_config` |
| 有 `routing` 段 ⇒ `allowed_profiles` 必须显式（1..8，去重） | `INPUT_INCOMPLETE` | `_routing.normalize_routing` |
| `default_agent_profile` 与 `rules[].prefer` 必须在白名单内 | `INPUT_INCOMPLETE` / `POLICY_DENIED` | 同上 |

#### 3.2.4 成本分类与身份要求（按实测结论修正 v2）

真实关系（已核验）：

| 机制 | 来源 | 能否分开 |
|---|---|---|
| `cost_class` | profile，用于 `cost_ceiling` 排除与 pin 的**默认值** | 是 |
| `pin_model` | 请求级 `route.requirements.pin_model`，缺省才由 `cost_class` 推出 | 是 |

v2 原本的结论是"`cb-pro` 保持 `premium`，每次派发显式写 `pin_model:false`"。**落地前的实测推翻了这个前提**：

| 实测项 | 结果 |
|---|---|
| `codebuddy -p --model BC-DeepSeek-V4-Pro` 的 JSON 输出 | 只在 `providerData.model` 报告实际模型，顶层无 `model`/`model_id`/`modelId` |
| `BaseAdapter.model_of` 读取位置 | 只读顶层 `model`/`model_id`/`modelId` 与 `message.model` |
| 推论 | `model_identity` **恒为 `unobserved`**，不是"校准一次就好" |
| 后果 | `premium` ⇒ 默认 `pin_model=true` ⇒ `pin_blocks` 恒阻断 ⇒ 每个 Pro 任务 `MODEL_MISMATCH` + worktree 隔离 |

> **v2.3 更正（见 §11.1）**：上面"推论/后果"是按当时的 `model_of` 做的代码推断，**结论错了两次**：
> ① 实际走 `stream-json` 的适配器本来就读 `message.model`，不是 `unobserved`；
> ② 真正的障碍是"请求名 ≠ 供应商名"加上 `system/init` 回显被当作运行观测，判成 `mixed`/`mismatch`。
> runtime 1.5.1 已修：`model_of` 读 `providerData.model`、回显单独记为 `request_echo`、profile 可声明
> `model_aliases` 得到 `alias_confirmed`，`pin_model` 接受它与 `reported_match`。下面这段降档记录保留
> 为**历史与恢复步骤**，不再是"当前不可用"的说明。

因此"每次请求写 `pin_model:false`"不是可持续方案：它把默认行为设成必然失败，忘记一次就隔离一次工作区。

当时落地采取的方案是**如实登记后降档**（v2.3 起可按文末步骤升回）：

```json
"cb-pro": {
  "model": "BC-DeepSeek-V4-Pro",
  "cost_class": "standard",
  "description": "…真实成本为 premium 档；此处登记为 standard 是因为 runtime 把 cost_class 同时用作 pin_model 默认值，而本环境 model_identity 恒为 unobserved…若 runtime 修复观测口径，应升回 premium 并开启 pin。"
}
```

这与评审反对的"隐藏"不同：真实成本写在 `description` 里，限制写进 6.2，缺陷写进 9.3。差异仅在"登记在哪个字段"，因为 runtime 没有独立的"身份要求开关"。

`cb-flash` 不受影响（`low` 不触发默认 pin）。

**runtime 已修复（1.5.1）**：给 Pro 的 profile 补 `model_aliases`（填实测上报名，如 `deepseek-v4.1-flash`），
把 `cost_class` 升回 `premium`、删除 `description` 里的例外说明、重新 `attest`。没实测就填别名等于把 pin
变成声明，报告只能写 `alias_confirmed`，不能写"逐字匹配"。

#### 3.2.5 三层证据（修正 v1 的"身份可证明"）

| 层次 | 字段 | 能证明什么 | 当前是否可得 |
|---|---|---|---|
| L1 配置 | `selected_execution.model` + `model_unresolved=false` | 配置指定了模型 | 可得 |
| L2 CLI 自报 | `run.model_identity` ∈ {`reported_match`, `alias_confirmed`} | 逐字一致 / 上报值全落在 profile 声明的 `model_aliases` 内 | 可得（`alias_confirmed` 需先实测再声明） |
| L3 服务端/计费 | — | 服务端实际调用了该模型 | **不可得**（runtime 无该证据源） |

报告口径：

> 模型已显式指定，CLI 自报身份匹配（L2，`identity_basis` 说明是逐字一致还是按声明等价）；服务端执行证据不可得（L3），因此不能表述为"已证明实际使用了该模型"。

`combination_verified` 要求 L2 + 有 usage 且 pin 版本一致；`alias_confirmed` 也算 L2（依据是可审计的
配置声明），但报告必须写出 `identity_basis=declared_alias`，不得省略。它是**集成事实标签**，不是 L3。

#### 3.2.6 `task_type` 是类别，不是难度

`docs`/`test`/`chore` 只表示工作类别。安全测试、并发回归、发布脚本同样可能需要强模型。因此：

- 规则表只做**默认建议**；
- 需要强模型时**显式指定** `agent_profile`（或 `requested_profile`），不靠改类别；
- 反之，`feature` 里的机械改动需要降档时也显式指定。

`allowed_profiles` 是授权的上限；显式指定仍受白名单与 `cost_ceiling` 约束。

**写法有坑（已实测）**：`task_type` 只在两个位置被读取——
`request.route.task_type` 优先，其次是 `spec.document.task_type`，否则 `unknown`。
把 `task_type` 写在 create 请求**顶层**会被静默忽略，路由退化为 `catch_all_preference`：

```bash
# 错误：顶层 task_type 被忽略
{"schema_version":2,"request_id":"…","task_type":"docs"}
# → task_type=unknown, task_type_source=default, selected=cb-pro

# 正确：写在 route 块里（项目必须是 routing.mode=auto）
{"schema_version":2,"request_id":"…","route":{"task_type":"docs"}}
# → selected=cb-flash, reason=rule_preference
```

这也说明"漏写 `task_type` 会落默认档"不是隐患而是事实（`task_type_source=default`），
所以默认档必须是有意选择的那个。

#### 3.2.7 `cb-run` 的两阶段处理（修正评审的顺序）

评审建议"从新任务可选集合移除 `cb-run`"。技术上可行，但会让**历史任务无法重验**（已核验）：

`rebind` 在 `routing` 存在时会调用 `combination_allowed`，`cb-run` 不在白名单 ⇒ `POLICY_DENIED` ⇒ 任务 `BLOCKED`。也就是说，在 4 个任务重验完成前移除它，等于关掉 3.1.3 这条路。

因此分两阶段：

| 阶段 | `allowed_profiles` | 目的 |
|---|---|---|
| 阶段 1（本次） | `["cb-pro","cb-flash","cb-run"]` | 保证历史任务可 `rebind` 重验；`default` 是 Pro，`rules` 不 prefer cb-run，新任务不会自动选它 |
| 阶段 2（收口后） | `["cb-pro","cb-flash"]` | 4 个任务全部 `accept` 或 `close-external` 后移除，并**重新 `attest`** |

若不愿意做两次 attest：保留阶段 1，并在 skill 文档写明"新任务不得显式选 `cb-run`"——**这是软约束，runtime 不强制**，必须如实登记。

#### 3.2.8 默认档的来源

"默认用 Pro"不能由"更严谨"推出。默认档必须是**用户批准的、在费用范围内的候选**。两个合法选项：

| 选项 | 配置 | 代价 |
|---|---|---|
| A. 漏写类型即用批准默认档 | `default=cb-pro`，`"*" → cb-pro` | 成本高，但不会因漏声明而降档 |
| B. 漏写类型要求补 | `default=cb-pro`，且 skill 要求 spec 必须带 `task_type` | 依赖流程纪律，runtime 不强制 |

v2 推荐 A，并把 B 作为 skill 侧的额外要求。

#### 3.2.9 验收

- `register --dry-run` 无 `errors[]`；`doctor` 的 `policy_problems` 为空、`placeholders_ok: true`；
- `attest --dry-run` 候选恰为 3 个（阶段 1）；
- 新建 `task_type: docs` 的任务路由到 `cb-flash`，`feature` 路由到 `cb-pro`，且 `model_unresolved == false`；
- 一次真实 run 后，`run.model_identity` 记录为 `reported_match` 或 `reported_mismatch`（**两者都是有效观测**），并写入 8.2 的待实测表；
- 未写 `route` 块时不再报 `INPUT_INCOMPLETE`（项目已是 `mode: auto`）。

---

### 3.3 B2 验证正确性（checks）

#### 3.3.1 缺陷

`_backend.execute` 的 `cwd=t["workspace"]` 是 worktree。现有 check 的 `cd /Users/.../zoe-go` 把目录切回主仓库：

- 构建的是 main，不是任务改动；
- 3 个并发任务共享同一份主仓库，三次"通过"同义；
- 主仓库在并发期间可能被 merge 改变，结果不可复现。

#### 3.3.2 改法

```json
"checks": [
  {"id": "build", "argv": ["go", "build", "./..."]},
  {"id": "vet",   "argv": ["go", "vet", "./..."]},
  {"id": "test",  "argv": ["go", "test", "./..."]}
]
```

| 决定 | 理由 |
|---|---|
| 去掉 `cd` | cwd 已是 worktree |
| 不用绝对路径 | `resolve_check` 按执行期 PATH 解析；换机器不需要改配置 |
| 不用 `bash -c` | 永久判为 `shell`，静态预检失效；`shell` ≠ 已验证 |

#### 3.3.3 `go test` 必须保留（修正 v1，并撤回一条错误事实）

v1 以"当前没有测试文件"为由不加 `go test`。这个依据**是错的**：落地时实测 `zoe-go` 仓库有测试，`go test ./...` 输出 9 个 `ok` 包：

```text
ok  zoe/internal/adapter/codebuddy   ok  zoe/internal/app      ok  zoe/internal/config
ok  zoe/internal/publish             ok  zoe/internal/recovery ok  zoe/internal/report
ok  zoe/internal/store               ok  zoe/internal/verify   ok  zoe/internal/workspace
?   zoe/cmd/zoe, zoe/internal/adapter, zoe/internal/probe, zoe/internal/runner   [no test files]
```

所以加 `test` 不是"占位入口"，而是**接回已有的行为证据**。v1 那句判断来自未核实的推断，已删除。

即便如此，报告仍要区分三种结果（部分包确实没有测试文件）：

保留 `test`，但必须区分三种结果：

| 输出 | 含义 | 报告写法 |
|---|---|---|
| `ok pkg 0.01s` | 有测试且通过 | 测试通过 |
| `? pkg [no test files]` + exit 0 | **没有执行任何测试** | "0 个测试被执行"，不得写"测试通过" |
| `FAIL` | 测试失败 | 失败，按 `error_class=test` 计修复预算 |

判定"是否真的跑了测试"不能只看 exit code，要读 check 日志：

```bash
zoe task logs <task_id> --log check-test --tail-bytes 65536
```

统计 `=== RUN` 行数或 `go test -json` 的 `{"Action":"run"}` 条数，写进报告。

本轮交付还应补**与变更相关的行为测试或回归场景**；只跑 build/vet 不能满足"并发交付可信度"这个目标。`-race` 不能替代并发测试。

#### 3.3.4 记录验证输入（新增）

除 cwd 外，报告要能回答"这次 checks 到底读了什么"。至少记录：

| 项 | 取值方式 |
|---|---|
| 候选 SHA | `candidate_sha` / `validated_sha` |
| 工作树指纹 | `validated_fingerprint` |
| 实际 Go 路径与版本 | `command -v go`；`go version` |
| `GOWORK` | `go env GOWORK`（非 `off` 意味着可能用了工作区文件） |
| `go.mod` 的 `replace` 指令 | `grep -c '^replace' go.mod` |

`GOWORK` 指向父目录或 `replace` 指向主仓库时，验证输入可能不是你以为的那个——这类情况要在报告里写明，不能默认"构建的就是 worktree"。

#### 3.3.5 负向验证（必须做一次）

在**一次性的临时 worktree** 里跑一次，`build` 必须 `FAIL`：

```bash
# 不要污染任务 worktree：注入错误会改变指纹，让 rebind 的 revalidate 直接失败
git -C /path/to/repo worktree add /tmp/zoe-negcheck HEAD --detach
printf 'package internal\nfunc broken( {\n' > /tmp/zoe-negcheck/internal/zz_broken_tmp.go
cd /tmp/zoe-negcheck && go build ./...   # 期望 rc=1，且报错指向 zz_broken_tmp.go
go vet ./...                             # 期望 rc=1
git -C /path/to/repo worktree remove --force /tmp/zoe-negcheck
```

关键点是**报错必须指向刚注入的那个文件**——否则说明 check 构建的不是这棵树，负向验证等于没做。

不通过这一步，"check 有效"就只是声明。**不要**在任务的 worktree 里做这一步：指纹一变，
`rebind` 会返回 `WORKSPACE_CHANGED`，你反而失去了重验路径。

#### 3.3.6 验收

- `doctor` 的 `checks_preflight` 里 `build`/`vet`/`test` 均为 `ok`，`unresolved: 0`；
- 负向验证如 3.3.5 所述失败；
- `test` 的输出与报告口径一致（0 个测试必须写明）；
- 同一改动在 worktree 手工执行与 check 结果一致。

---

### 3.4 B3 监控（重写）

#### 3.4.1 两条通道，各司其职

| 通道 | 用途 | 游标 | 边界 |
|---|---|---|---|
| 有界查询 `zoe watch ... --jsonl --after` | **默认**：游标由 runtime 给，适合循环 | 末尾 meta 行的 `next_cursor` | 轮间有间隔，感知延迟 = 轮间隔 |
| `--follow` | 即时展示（人看/短窗口） | 首行 `follow_start.cursor`、末行 `follow_end.next_cursor`（v2.3 起；`cursor_expired` 分支同样带） | 有游标，但轮内仍在流式输出，不适合做退出决策 |
| `task status --refresh` | **权威当前状态** | 无 | 每次一次查询，适合做终止判断 |

三条纪律：

1. **终止判断读 `task status`，不读事件历史。** 历史事件里的 `DONE` 不代表当前任务状态，用它判断会立即误退。
2. **游标只在一轮边界切换**，同一轮内不混用两种取法（不是"混用必然丢事件"，而是两套语义对不上）。
3. **`next_cursor` 是"已扫描"位置，不等于"已匹配"位置。** 项目过滤下它会越过其他项目的事件；因此不能承诺"同一区间不会被重复扫描"，只能说"游标单调前进"。

#### 3.4.2 模板（有界查询 + 状态机）

```bash
#!/usr/bin/env bash
set -u
set -o pipefail          # 否则 zoe 的失败会被下游 jq 的 exit 0 掩盖
P=zoe-go
TARGETS="task-0234ce049bbc447e task-24b05cd1095149f3 task-5a433b16253b4da5 task-c442d52b9aa44ca2"
EVENTS=./zoe-events.jsonl
CURSOR_FILE=./zoe-cursor.txt

# 1) 起点：优先复用上次游标（重启不跳过停机期间的事件）
cur=""
[ -s "$CURSOR_FILE" ] && cur=$(cat "$CURSOR_FILE")
if [ -z "$cur" ]; then
  cur=$(zoe watch --project "$P" --json | jq -r '.next_cursor') || { echo "watch init failed"; exit 1; }
  [ -n "$cur" ] || { echo "init response has no next_cursor"; exit 1; }
  printf '%s\n' "$cur" > "$CURSOR_FILE"
fi

human=""; finished=""; rounds=0
while :; do
  rounds=$((rounds+1))
  # 2) 权威状态（不用事件猜终态）
  alive=0; need_human=0
  for t in $TARGETS; do
    case " $finished " in *" $t "*) continue;; esac
    # INPUT_REQUIRED 是 block_code，不是 state；只看 state 永远匹不到它
    row=$(zoe task status "$t" --json 2>/dev/null | jq -r '"\(.state // "")\t\(.block_code // "")"') || row=""
    st=${row%%$'\t'*}; block=${row#*$'\t'}
    if [ -z "$st" ]; then echo "[warn] status unreadable: $t"; alive=1; continue; fi
    case "$st" in
      DONE|CANCELLED) finished="$finished $t"; echo "[final] $t $st";;
      # REVIEW_READY 是"等人工验收"：不结束循环，也不能当作还在跑
      REVIEW_READY|BLOCKED|PAUSED)
        need_human=$((need_human+1))
        label=$st; [ "$block" = INPUT_REQUIRED ] && label="$st/INPUT_REQUIRED"
        case " $human " in *" $t "*) ;; *) human="$human $t"; echo "[needs-human] $t $label";; esac;;
      *) alive=1 ;;
    esac
  done

  # 3) 退出：活着=0 时才可能结束；若剩余的目标都需人介入，明确暂停而不是空转
  if [ "$alive" -eq 0 ]; then
    if [ "$need_human" -eq 0 ]; then echo "[done] all targets final"; exit 0; fi
    echo "[pause] 其余目标都需人工介入:$human"; exit 10
  fi

  # 3b) 检查点：正常无事件时也必须有一行输出，否则"仍在监控"无法被验证
  echo "[tick] round=$rounds cur=$cur alive=$alive need_human=$need_human human=${human:-none}"

  # 4) 消费事件：先落盘，再推进游标（无事件时只有一行 heartbeat meta）
  tmp=$(mktemp)
  if ! zoe watch --project "$P" --jsonl --after "$cur" --max-events 200 > "$tmp" 2>./zoe-watch.err; then
    echo "[error] watch failed: $(cat ./zoe-watch.err)"; sleep 5; rm -f "$tmp"; continue
  fi
  nxt=$(tail -1 "$tmp" | jq -r '.next_cursor // empty') || nxt=""
  if [ -z "$nxt" ]; then
    echo "[error] meta line missing or unparsable"; sleep 5; rm -f "$tmp"; continue
  fi
  sed '$d' "$tmp" >> "$EVENTS"
  cur="$nxt"; printf '%s\n' "$cur" > "$CURSOR_FILE"
  rm -f "$tmp"

  sleep 3   # 感知延迟 ≈ 3s + 查询耗时；不要声称实时
done
```

相对 v1 的差异（v2 六项 + v2.2 三项）：

| 原问题 | 处理 |
|---|---|
| 从 `epoch:0` 起扫，历史 `DONE` 让循环立即退出 | 终止判断读 `task status`；事件只用于日志与告警 |
| 任一任务终态就 break | `finished` 逐目标记录，全部终态才退出 |
| 注释含 `INPUT_REQUIRED` 但代码没判 | 补 `BLOCKED`/`INPUT_REQUIRED`/`PAUSED` 分支，标记但不终止其他目标（**v2.3 更正**：`INPUT_REQUIRED` 是 `block_code` 不是 `state`，这个分支实际只命中 `BLOCKED`；同时漏了 `REVIEW_READY`。已落地版本读 `state` + `block_code`，见 `scripts/zoe-monitor.sh`） |
| 不检查退出码与解析失败 | `watch` 非 0、meta 行缺失都进入有限重试并报原因 |
| 先删临时文件，仍无持久记录 | 先 `>> $EVENTS` 落盘，再推进游标；游标单独持久化 |
| 每轮结束才解析，声称"实时" | 明确"感知延迟 = 轮间隔"，不声称实时 |
| **v2.2：游标文件只写不读** | 启动先读 `CURSOR_FILE`；否则重启会重新取"当前末端"，**跳过停机期间的事件** |
| **v2.2：全部目标都 `BLOCKED` 时死循环** | 引入 `need_human`；`alive==0` 且 `need_human>0` 时打印 `[pause]` 并 `exit 10` |
| **v2.2：`zoe` 失败被 `jq` 掩盖** | `set -o pipefail`；`st` 为空时按"状态不可读"处理，不静默当作进行中 |
| **v2.2：全程静默，无法验证"仍在监控"** | 每轮打印 `[tick]`（对齐 SKILL.md 的检查点节奏）；正式使用可按 5 轮一次降频 |

**无事件时的返回值已实测**：有界查询会输出一行 meta，`cursor_status=heartbeat`、`next_cursor` 不变。
所以这类循环「空返回」不是心跳——**meta 行才是心跳**，`--follow` 才是真的无输出。模板里 `sed '$d'`
正好把这行丢掉，不会污染事件日志。

#### 3.4.3 `--follow` 的定位

```bash
zoe watch --project P --follow --jsonl --timeout 60 --after "$cur"
```

- 只用于**人看**的短窗口展示，或需要"秒级看到新事件"的场景；
- 该模式**也回传游标**（v2.3）：首行 `{"kind":"meta","event":"follow_start","cursor":…}`、
  末行 `{"kind":"meta","event":"follow_end","next_cursor":…}`，可直接用于下一轮 `--after`；
  事件行本身不带游标语义（不要把事件 `id` 拼成游标）；
- **不要用它的输出做终止判断**（退出仍读 `task status`）；
- 与有界查询交接只发生在一轮边界：用上一轮结束时的游标作为下一轮 `--after`。

```bash
zoe task logs <task_id> --log check-build --follow --timeout 60 --projection auto
```

三条实测口径：

| 事实 | 后果 |
|---|---|
| `task logs` **没有 `--jsonl`**（D11） | 传了会 `unrecognized arguments`；`--follow` 本身就是一行一个 JSON |
| `--log` **缺省是 `agent`** | `rebind` 重验的 run 没有 agent 日志，会返回 `INPUT_INCOMPLETE: No log named 'agent'` |
| 首行是 `{"kind":"meta","run_id":…,"cursor":…}` | 用它固定 run 与续读起点；换 run 必须显式 `--run` 或 `--cursor` |

所以"看 Agent 在做什么"和"看 checks 输出了什么"是两条 `--log`，不要用同一条硬套。重验 run 只能看
`--log check-<id>`（如 `check-build` / `check-test`）。

#### 3.4.4 验收

- 起点不会因历史事件立即退出（人为让一个目标保持 RUNNING，验证循环不终止）；
- 一个目标 `DONE`、其余仍在跑时，循环继续（v1 会退出）；
- 一个目标 `BLOCKED` + `block_code=INPUT_REQUIRED` 时，脚本打印带 `INPUT_REQUIRED` 的
  `[needs-human]` 并继续监控其余目标；一个目标 `REVIEW_READY` 时同样只标记该目标（等人工验收）；
- `watch` 返回非 0 时脚本打印错误并重试，不把它当心跳；
- 中途 `Ctrl-C` 后，`CURSOR_FILE` 里的游标可直接用于下一轮。

---

### 3.5 B4 交付收口：组与并行的责任边界

#### 3.5.1 事实（运行时版本已对齐）

| 事实 | 依据 |
|---|---|
| 组内串行是**当前版本声明的能力** | `runtime-requirements.json` 的 `group_serial_execution`；`group --help` 文案 |
| 成员绑定只在 `task create` 时发生 | 无"事后入组"命令 |
| 成员不能自验收 | `task accept` ⇒ `STATE_CONFLICT` / `kind=group_member` |
| 已集成成员不能 `revise/reassign/rebind` | `kind=integrated_member` |
| `group start` 派生后台推进器后立即返回 | 1.6 |

不再使用"v1.3 组内串行"这种版本混用表述。

#### 3.5.2 推进责任（修正 v1 的 3.5.4）

| 动作 | 谁负责 | 命令 |
|---|---|---|
| 推进组（派发下一个成员、集成、跑组检查） | 后台推进器（`internal-group`） | `group start` / `group resume` |
| 观察 | 宿主 | `watch` / `group status --refresh` |
| 人工决策（审查、验收、修复） | 人 | `group review` / `group accept` / `group repair` |

`group start` 返回 `accepted:true` **不是**"正在持续推进"。推进器退出后必须重新进入：

```text
stop.resumable == true   → 不需要人先决策：用 stop.resume_hint 续跑（与 needs_human 互斥）
stop.needs_human == true → 先拍板（评审/验收/看 blockers）；hint 按原因给
                           group review / group accept / group repair / group status --refresh
```

因此"`group start` 之后继续 follow"是错的：follow 只能看到事件，不能让组前进。正确表述是"**start 之后 follow 观察；推进器退出后按 `exit_reason` 决定 resume 还是等人**"。

#### 3.5.3 选型

| 目标 | 机制 | 并发 | 收口 |
|---|---|---|---|
| 吞吐（各片独立、集成由人安排） | 独立 `task create` + `start` | ≤ `max_active_tasks`（全局槽位） | 各自 `accept` |
| 一次验收 + 设计一致性审查 | `group create` → `start`/`resume` | **串行** | `group accept` |

两者不可拼接：独立任务不会自动成为组成员。

#### 3.5.4 组计划的易错点

| 易错点 | 正确做法 |
|---|---|
| 照抄 `"task_type": "api"` | 词表只有 `bugfix/feature/refactor/test/docs/chore/review/unknown` |
| 漏 `budget.max_starts` | 必填，不按规模推算 |
| 省略 `review` 段 | 等于放弃设计一致性审查，只在 `warnings` 点名 |
| 指望 `start` 返回即完成 | `accepted:true` / `completed:false` |
| 认为 `max_group_repairs` 默认可修复 | 缺省 `0` = 不授权任何修复执行 |

#### 3.5.5 集成检查（新增）

各任务 `accept` 只证明"该分支单独通过"。**合并后的 main 仍需一次集成检查**：

```bash
# 集成结果上重跑同一组 checks（顺序：先 build，再 vet，再 test）
go build ./... && go vet ./... && go test ./...
```

集成检查失败时，退回的是"合并顺序/冲突处理"，不是某个成员任务的实现质量——报告要分开写，不要把集成失败算到具体任务头上。

#### 3.5.6 验收

- `group plan` 通过；`create` 后 `plan-r001.json` / `baseline.json` / `design-manifest.json` 齐备；
- `start` 返回 `accepted:true` 后，宿主 follow 观察，且**推进器退出后**用 `resume`/`start` 续跑成功；
- 全部成员 `REVIEW_READY` 后 `group accept` 成功，成员 `task accept` 仍被拒；
- 合并结果上 3.3.2 的三条 checks 全通过。

---

### 3.6 B5 文档同步

| 文件 | 改动 |
|---|---|
| `SKILL.md`「执行配置与模型授权」 | 补三层证据边界（3.2.5）；`premium ⇒ 默认 pin` 的耦合要写明；`pin_model` 是请求级开关 |
| `SKILL.md`「拆分」 | 组=串行一次验收 / 独立任务=并行各收口，二选一；无法事后入组 |
| `SKILL.md` 第 6 步 | 粘贴 3.4.2 模板；**终止判断读 `task status`**；取消"用 follow 的 `next_cursor`"的说法 |
| `SKILL.md` 第 6 步 / `cli-contract.md` | `task logs` 去掉 `--jsonl`；说明首行 `kind: meta` |
| `SKILL.md` 组章节 | 推进责任表（3.5.2）；禁止"start 后只 follow" |
| `references/decomposition-patterns.md` | 加"验证对象自检"：checks 的 cwd 是 worktree，`cd` 到主仓库即假绿；`GOWORK`/`replace` 检查 |
| `references/cli-contract.md` | `rebind` 的 `revalidate` 语义与 `recommended_action="resume"`；`close-external` 的 `claim` 二值；`accept` 的 `subject_sha`/`expected_version` |
| `references/recovery-policy.md` | 增加"证据污染"这一类：不是靠重跑 agent，而是 `rebind` → `resume` 重跑 checks |
| `references/runtime-contract.md` | 示例文件的 `max_active_tasks: 1`、`cost_class: premium` 是示例值不是推荐值（JSON 不能加注释） |

**建议**（评审第 15 条）：文档里的 CLI 示例应可执行。可加一个轻量脚本，把 `docs/` 与 `references/` 中出现的 `zoe ... --help` 命令抽出来跑一次 `--help`（只验证参数存在，不验证业务）。不作为本次硬门槛。

---

## 4. 执行顺序

```text
1. 冻结证据缺陷（4 个任务的 candidate_sha / validated_sha / 判定）
2. 一致性备份（sqlite3 .backup）+ 记录配置摘要、user_version、epoch
3. 一次性改完配置：checks（build/vet/test）+ profiles（cb-pro=premium、cb-flash）+ routing
4. register --dry-run → register → doctor（checks_preflight 全 ok）
5. project attest（阶段 1：cb-pro/cb-flash/cb-run）
6. 负向验证：故意坏的 worktree 必须 FAIL（3.3.5）
7. 对 4 个任务 rebind → resume（只重跑 checks）→ 读 report 确认新证据
8. 证据通过 + 人工审查 → 分别 accept；走不通的用 close-external（claim 二值）
9. 合并结果上跑集成检查（build/vet/test）
10. 收口后再从 allowed_profiles 移除 cb-run → 重新 attest（阶段 2）
11. 同步 SKILL.md 与 references（3.6）
```

顺序的两个硬理由：

| 顺序 | 理由 |
|---|---|
| 备份在改配置前 | `attest` 会写状态库；配置变更会波及 4 个任务的策略校验 |
| 负向验证在重验前 | 先证明"新 check 会失败"，再用它给历史任务出 PASS；否则重验只是换了个看起来对的检查 |
| 移除 cb-run 在收口后 | 提前移除会让 `rebind` 的 `combination_allowed` 拒绝历史任务 |
| 集成检查在各自 accept 后 | 单任务通过不能证明组合后的 main 正确 |

**v1 的"B0 必须先于 B1/B2 否则卡死"作废**：策略变化带来的重新验证是**合理成本**，不是要规避的麻烦。为了绕开 `POLICY_CHANGED` 而保留错误证据，等于用流程便利换取证据污染。

---

## 5. 硬约束速查

| # | 约束 | 违反表现 |
|---|---|---|
| 1 | `model` 与 `allow_cli_default_model` 互斥 | `INPUT_INCOMPLETE` |
| 2 | 有 `routing` 段必须显式 `allowed_profiles` | `INPUT_INCOMPLETE` |
| 3 | `default_agent_profile` / `rules[].prefer` 必须在白名单 | `INPUT_INCOMPLETE` / `POLICY_DENIED` |
| 4 | 未 `attest` 的 routing 配置不能 create/start | `ALLOWLIST_UNCONFIRMED`（exit 5） |
| 5 | `premium` ⇒ `pin_model` 默认 `true`；身份 ∉ {`reported_match`, `alias_confirmed`} ⇒ 阻断 | `MODEL_MISMATCH` + `BLOCKED` + worktree 隔离 |
| 6 | `pin_model` 可在请求级显式关闭，但必须在记录里说明 | 不说明 = 隐式弱化身份要求 |
| 7 | checks 的 cwd 是 worktree | `cd` 到主仓库即假绿 |
| 8 | `test` 的 exit 0 可能是"没有测试文件" | 报告必须写执行了几个测试 |
| 9 | `rebind` 只在产物完整（与已签发证据一致）、无活跃 run、`local_artifact` / 未集成 `group_member` 时可重验 | 否则 `BLOCKED / WORKSPACE_CHANGED` |
| 10 | `rebind` 后是 `READY/verify`，需 `resume` 才跑 checks | 只读返回会误以为已重验 |
| 11 | `accept` 要求 policy 摘要一致 + `subject_sha == validated_sha` | `POLICY_CHANGED` / `WORKSPACE_CHANGED` |
| 12 | `close-external` 是记账，`accepted:false` | 不得当验收 |
| 13 | 一致性备份用 SQLite Backup API；恢复是灾难恢复 | `cp state.db` 不一致；恢复会波及其他项目 |
| 14 | `watch` 不推进任何任务或组 | 只 follow 会让组停在原地 |
| 15 | 组成员不能自验收；独立任务不能事后入组 | `STATE_CONFLICT` |
| 16 | 活跃任务全局计数 | 并发被其他项目挤掉 |
| 17 | `--follow` 的游标只在首/末 meta 行（v2.3 起） | 把事件 `id` 当游标用会重放或跳事件 |
| 18 | `task logs` 无 `--jsonl` | exit 2 |
| 19 | `max_starts` 是计费启动额度 | 误读为进度 |
| 20 | `max_group_repairs` 缺省 0 | 以为默认可修复 |

---

## 6. 明确不做与本轮限制

### 6.1 明确不做

| 项 | 理由 |
|---|---|
| 新增 `zoe task monitor` 命令 | 会造第二套事件消费路径；有界查询 + 状态机足够 |
| 让 skill 猜模型档位 | 难度由 `task_type` + 显式 `agent_profile` 表达 |
| runtime 自动探测 `expected_version` | `start` 已写实测值，doctor 已报版本 |
| 顺手配 `spend_guard` | cost 常为 `unavailable`，配上限会直接 `SPEND_UNVERIFIABLE` |
| 改 `cb-run` 的既有字段 | 会改变历史任务绑定语义 |
| ~~本次给 `--follow` 加 meta 行~~ | v2.3 已做（§11.3）：首/末 meta 行回传游标 |
| 用 `cp state.db` 备份 | 不一致 |

### 6.2 本轮限制（如实登记）

| 限制 | 影响 | 登记位置 |
|---|---|---|
| 项目级没有"默认 pin 开关" | `premium` 必然默认 pin | 3.2.4 |
| ~~`model_of` 不读 `providerData.model`~~ | v2.3 已修（§11.2）：读 `providerData`、回显单列、`model_aliases` 可满足 pin | 3.2.4、11.2 |
| L3（服务端/计费）证据不可得 | 只能说"CLI 自报匹配" | 3.2.5 |
| runtime 无法区分"历史任务授权"与"新任务授权" | `cb-run` 只能靠两阶段或软约束处理 | 3.2.7 |
| ~~`watch --follow` 不回传游标~~ | v2.3 已修（§11.3）：首/末 meta 行给游标 | 3.4、11.3 |
| 无"标记证据无效"命令 | 冻结靠人工清单，不进入状态库 | 3.1.2 |
| 无"撤销验收"命令 | 只能拒绝 + `revise` 重开；不要用整库恢复 | 3.1.6 |
| ~~`task recover` 需要显式 `--run`，且不支持 `--json`~~ | v2.3 已修（§11.3）：缺省取 `current_run_id`，`run_source` 说明来源 | 9.2、11.3 |

若 1.5 的四条在某个任务上不满足，且 `close-external` 也不适用（例如工作区被改动但仍要保留候选），则登记 **runtime 缺陷（重验路径覆盖不足）**，不在本方案内绕过。

---

## 7. 回放验收

### 7.1 指标

| # | 指标 | 通过标准 |
|---|---|---|
| 1 | 证据可信 | 每个被 `accept` 的任务，其 `validation.json` 由 `build/vet/test` 生成，且 `fingerprint` 与候选一致 |
| 2 | 无假绿 | 负向验证（3.3.5）失败；checks 的 cwd 为 worktree |
| 3 | 重验可用 | 至少 1 个任务走完 `rebind → resume → accept`，且 `revalidate.pending=true` 时未重启 agent |
| 4 | 身份边界清楚 | 报告区分 L1/L2/L3，不把 `model_unresolved=false` 写成"身份已证明" |
| 5 | 监控正确 | 历史终态不让循环立即退出；一个完成时其余继续；`INPUT_REQUIRED` 被单独标记 |
| 6 | 推进责任清楚 | 推进器退出后，用 `resume`/`start` 成功续跑；不出现"只 follow 等它自己前进" |
| 7 | 集成正确 | 合并后的 main 上 `build/vet/test` 全通过 |
| 8 | **吞吐有证据** | 记录各任务的 `started_at`/`ended_at` 与重叠区间，给出总耗时；证明并发真的发生，而不是"配置了 3" |
| 9 | 名额耗尽可判 | 把 `max_active_tasks` 设为 1 跑两个任务，第二个必须得到明确的槽位拒绝（不是静默排队） |
| 10 | 统计不美化 | 交付率分母含 `external_closed_*` / `evidence_invalid` / `pending_acceptance` |
| 11 | 备份可恢复 | 备份文件能通过 `PRAGMA integrity_check`；记录 `user_version` 与 `epoch` |

### 7.2 负向判据（必须全部成立）

- 改配置后，未收口任务报 `POLICY_CHANGED`，而不是静默沿用旧策略；
- `attest` 后只改 `description`，create 报 `ALLOWLIST_UNCONFIRMED`；
- 用旧 `validation.json` 的 PASS 尝试 `accept` 且 `subject_sha` 不符时被拒（`WORKSPACE_CHANGED`）；
- `rebind` 在 worktree 被改动后返回 `revalidate.pending=false` + `WORKSPACE_CHANGED`，不产出新证据；
- `close-external` 的响应里 `accepted == false`；
- `group accept` 后成员 `task accept` 仍被 `STATE_CONFLICT` 拒绝；
- `--task` 指向别的项目返回 `PROJECT_MISMATCH`，不是空数组；
- 推进器退出后仅运行 `watch`，组状态**不再前进**（证明"观察≠推进"）。

---

## 8. 附录

### 8.1 执行清单

```bash
# 0) 一致性备份
stamp=$(date +%Y%m%d%H%M%S)
sqlite3 ~/.local/share/zoe/state.db ".backup '$HOME/zoe-state-$stamp.db'"
sqlite3 "$HOME/zoe-state-$stamp.db" "PRAGMA integrity_check;"   # 期望 ok
cp ~/.local/share/zoe/projects/zoe-go.json ~/.local/share/zoe/projects/zoe-go.json.bak.$stamp

# 1) 编辑配置：checks（build/vet/test）+ profiles + routing
# 2) 只读校验
zoe project register --config ~/.local/share/zoe/projects/zoe-go.json --dry-run
# 3) 落盘
zoe project register --config ~/.local/share/zoe/projects/zoe-go.json
# 4) 复验
zoe doctor --project zoe-go --json
# 5) 负向验证（3.3.5）——必须在重验历史任务之前
# 6) 确认候选（人确认后执行）
zoe project attest --project zoe-go --profiles cb-pro,cb-flash,cb-run --dry-run
zoe project attest --project zoe-go --profiles cb-pro,cb-flash,cb-run
# 7) 历史任务重验（逐任务，见 3.1.3）
# 8) 收口（accept 或 close-external）
# 9) 集成检查（build/vet/test）
# 10) 阶段 2：移除 cb-run 并重新 attest
```

### 8.2 待实测项（已由 9.1/9.3 关闭）

| 项 | 状态 | 结论 |
|---|---|---|
| Pro 的实际模型 ID | **已确认** | `BC-DeepSeek-V4-Pro`（`~/.codebuddy/models.json`） |
| Flash 的实际模型 ID | **已确认** | `BC-DeepSeek-V4-Flash` |
| 默认档 | **已定** | `cb-pro`（漏写 `task_type` 落在严谨侧） |
| 4 个任务路径 | **已走 A** | 4 个 worktree `HEAD == candidate_sha`，全部重验成功 |
| codebuddy 自报 model 是否与配置逐字一致 | **已实测** | 不一致：CLI 只报 `providerData.model=deepseek-v4.1-*`，runtime 不读该字段 |
| `GOWORK` / `replace` 是否指向 worktree 之外 | **待实测** | 影响验证输入可信度 |

### 8.3 关键锚点（以符号名为准）

```text
_profiles.model_unresolved / normalize_config           model 与 allow_cli_default_model 互斥
_routing.normalize_routing                             白名单必须显式
_routing.normalize_requirements                        pin_model 默认来自 cost_class
_routing.combination_allowed                           rebind 时按新白名单复核组合
_pipeline._require_attested                            ALLOWLIST_UNCONFIRMED
_pipeline._gate_model_identity / _block_and_quarantine MODEL_MISMATCH 的后果
_pipeline._revalidation_product / _revalidation_blockers  rebind 能否就地重验
_pipeline.rebind                                       READY/verify + revalidation.pending + recommended_action=resume
_pipeline.accept                                       policy 摘要 + subject_sha + 指纹
_pipeline.close_external                               CANCELLED + CLOSED_EXTERNAL + accepted=false
_pipeline.run_checks                                   resolve_check + search_path
_pipeline.slots                                        全局活跃计数
_pipeline.resume / _start_locked                       start 与 resume 同一函数
_backend.execute                                       cwd=t["workspace"]
_config.attestation_status / checks_preflight          授权确认与静态预检
cli._watch_once                                        next_cursor = "<epoch>:<next_id>"
cli._watch_follow                                      只在 cursor_expired 输出 next_cursor
_group_runner.begin / resume                           spawn 推进器 / 换租约续跑
_migrations.migrate                                    db.backup(target) 一致性备份
runtime-requirements.json                              group_serial_execution
zoe-workflows/build.py                                  WHITELIST 不含 docs/
```

---

## 9. 实施记录（2026-11-04）

### 9.1 已完成

| 步骤 | 结果 | 证据 |
|---|---|---|
| 一致性备份 | `~/zoe-backups/state-20261104091613.db`，`PRAGMA integrity_check` = `ok` | 配置副本 `zoe-go.json.20261104091613` |
| 证据冻结 | 4 个任务的 `candidate_sha`/`validated_sha` 与判定写入 `zoe-go/docs/evidence-freeze-2026-11-04.md` | 未跟踪文件 |
| checks 修正 | `bash -c "cd …"` → `["go","build","./..."]` + `vet` + `test` | doctor 三条 `ok` |
| profile 分级 | `cb-pro`（`BC-DeepSeek-V4-Pro`）/ `cb-flash`（`BC-DeepSeek-V4-Flash`）/ `cb-run`（保留） | `model_unresolved`: false / false / true |
| 路由 | `mode: auto`，8 条规则，`default=cb-pro`，`allowed=[cb-pro,cb-flash,cb-run]` | `attest` 确认集合 |
| 授权确认 | `project attest` 写入，`policy_hash=68c4518…c77b99` | `zoe-go.attest.json` |
| 负向验证 | 临时 worktree 注入语法错误：`go build` rc=1、`go vet` rc=1，报错指向 worktree 内文件 | `/tmp/neg-build.log` |
| 历史任务重验 | 4 个任务全部 `REVIEW_READY`，最新 run 的 `build/vet/test` 全 `PASS`，指纹与候选一致 | 见 9.2 |
| 集成检查 | 主仓库 `go build` / `go vet` / `go test` 全通过；`GOWORK` 为空、`replace` 0 条 | 终端输出 |

`doctor` 前后对比：

| 项 | 改前 | 改后 |
|---|---|---|
| `checks_preflight.build` | `shell`（inner unverified） | `ok`（`/Users/liuzhupeng/.local/go/bin/go`） |
| `checks` 条数 | 1 | 3（build/vet/test） |
| `model_unresolved` | 全项目 1 个 profile = true | `cb-pro`/`cb-flash` = false，`cb-run` = true（对照） |

### 9.2 四任务重验结果

| task_id | state | run | checks |
|---|---|---|---|
| `task-0234ce049bbc447e` | `REVIEW_READY` | `run-b9f2fbb252954bc7` | build/vet/test PASS |
| `task-24b05cd1095149f3` | `REVIEW_READY` | `run-6e8c86024cd74205` | build/vet/test PASS |
| `task-5a433b16253b4da5` | `REVIEW_READY` | `run-3202274fa6c0486e` | build/vet/test PASS |
| `task-c442d52b9aa44ca2` | `REVIEW_READY` | `run-a61df4db2fe94723` | build/vet/test PASS |

**重验发生了两次**：第一次按 v2 原方案（`cb-pro` = `premium`）落地并 `attest`（`policy_hash=9d985ad…`），随后实测发现 `model_identity` 恒 `unobserved`，`premium` 会让每个 Pro 任务必挂。于是把 `cb-pro` 改为 `standard`（见 3.2.4），摘要变化 ⇒ 第二次 `attest`（`policy_hash=68c4518…`）并对 4 个任务再走一遍 `rebind → resume`。

代价与教训：**先测观测口径，再定成本档**。v2 把"未知"当成"校准后可知"，导致一轮返工。这不是流程缺陷，是证据不足时的正常成本，但可以避免。

**一次 `PROCESS_UNKNOWN` 事故**：第一次重验时 `task-c442d52b9aa44ca2` 的 checks 全部 `PASS`、任务曾进入 `REVIEW_READY`，但 `run_finalized` 时判定 `PROCESS_UNKNOWN`（supervisor 收口竞态）。处置：

```bash
zoe task recover task-c442d52b9aa44ca2 --run run-c62ded1363a44cc5 --confirm-stop
# → supervisor_identity=dead, process_tree=dead, writer_lock=acquired, RUN_INTERRUPTED
zoe task resume task-c442d52b9aa44ca2 --request-file <…>
# → BLOCKED/RUN_INTERRUPTED → REVIEW_READY（证据保留，未重启 agent）
```

两点口径：

- `run.status=unknown` 与 `PROCESS_UNKNOWN` 同时出现是正常组合，不等于实现失败；
- `recover` **必须显式给 `--run`**，且不支持 `--json`（脚本要先从 `status` 取 `current_run_id`）。

### 9.3 实测发现的 runtime 缺陷（登记；已于 v2.3 修复，见 §11）

| 项 | 事实 |
|---|---|
| 现象 | `codebuddy -p --output-format json` 把实际模型放在 `providerData.model`（实测值 `deepseek-v4.1-flash`） |
| 代码 | `BaseAdapter.model_of` 只读顶层 `model`/`model_id`/`modelId` 与 `message.model` |
| 后果 | `run.model_identity` 恒为 `unobserved`；`pin_model=true` 恒阻断；`combination_verified` 恒 false |
| 影响面 | 所有 codebuddy profile，不只是 `cb-pro` |
| 建议 | `model_of` 增加 `providerData.model` 读取，或在 adapter 层声明该字段；改动前 `pin_model` 在本环境不可用 |
| 本次处理 | v2.1 未改 runtime，`cb-pro` 降为 `standard` 并登记（3.2.4）；v2.3 已修（§11.2），可按 3.2.4 文末步骤升回 |

**证据等级（重要，别把推断写成实测）**：本节的支撑只有两条——`BaseAdapter.model_of` 的源码，
以及一次 `codebuddy -p --output-format json` 的原始输出。**没有在 runtime 里跑过一次真实 agent
run 并读 `run.model_identity`**，所以"恒为 `unobserved`"是**代码推断 + CLI 实测**的合成结论，
不是 runtime 记录。要把它升为 runtime 实测，需做 9.4 的第 1 项。

**v2.3 更正**：这条推断的结论也不成立——stream-json 适配器本来就读 `message.model`，真实结论是
"请求回显 + 供应商名"导致的 `mixed`/`reported_mismatch`，而不是 `unobserved`。采集与修法见 §11.1、§11.2。

### 9.4 未完成与未验证

**未完成（有明确阻塞）**

| 项 | 原因 | 下一步 |
|---|---|---|
| 4 个任务的 `accept` | **验收是人的决定**，不由本会话代替 | 见 9.5 的命令 |
| 阶段 2：从 `allowed_profiles` 移除 `cb-run` | 需先收口（accept/close-external） | 收口后改配置 + 重新 `attest` |
| 监控脚本落成仓库文件 | 3.4.2 只是模板 | 放入项目 `scripts/`，同时改 `build.py` 白名单 |

**未验证（方案里写了验收标准，但没跑）**

| 项 | 缺什么 | 补法 |
|---|---|---|
| 3.2.9 第 4 条 | 真实 run 的 `run.model_identity` 从未观测 | 用 `cb-flash` 建一个 `docs` 小任务真跑一次，读 run 记录 |
| 3.4.4 第 1、2 条 | 没构造"一个目标 RUNNING / 一个 DONE"的并发场景 | 用两个小任务造重叠 |
| 3.4.4 第 3 条 | `INPUT_REQUIRED` 分支未实跑 | 需要一个会提问的任务，或人工 pause 后看 `[needs-human]` |
| 3.5.6 | 从未创建过组，组的推进/验收路径未验证 | 用一个两成员小计划走 `plan → create → start → resume → accept` |
| 7.1 第 8 条 | 没有并发重叠的实际记录 | 强制 `max_active_tasks: 2` 同时起两个任务，记录 `started_at`/`ended_at` |
| 7.1 第 9 条 | 名额耗尽时的拒绝行为未观测 | 临时把 `max_active_tasks` 设为 1，起两个任务看第二个的报错 |
| 3.3.6 第 3 条 | `test` 的"0 个测试被执行"口径未在 check 日志里逐包核对 | 读 `--log check-test`，数 `ok` 与 `no test files` |

这些都是"可执行但未执行"，不是"不可执行"。报告里不能把它们写成已通过。

### 9.6 文档同步（已完成）

| 文件 | 改动 | 对应缺陷 |
|---|---|---|
| `SKILL.md` 第 6 步 | 游标按模式分开（有界查询用 `next_cursor`，`--follow` 自行拼）；终止判断改读 `task status`；逐目标退出条件；`task logs` 去掉 `--jsonl` | D10、D11、v1 监控 6 缺陷 |
| `SKILL.md` 执行配置 | 新增三层身份证据、`premium ⇒ pin` 耦合、`model_of` 观测限制、校准顺序（先测报告值再定成本档） | D14、9.3 |
| `SKILL.md` 用任务组交付 | 新增"`watch` 不是推进"、`group resume` 命令、`group_serial_execution` 能力项 | D13 |
| `SKILL.md` 拆分 / `group-delivery.md` | 版本引用改为"v1.3 引入，当前版本由能力项保证" | 评审第 14 条 |
| `references/cli-contract.md` | 游标来源分模式表；`task logs` 无 `--jsonl`；组标题去版本号 | D10、D11 |
| `references/recovery-policy.md` | 新增"证据本身不可信"六步处置（冻结 → 修 checks → 负向验证 → rebind → resume → accept）与统计口径；`PROCESS_UNKNOWN` 补 `recover --run --confirm-stop` | D12、9.2 |
| `references/decomposition-patterns.md` | 新增"check 的验证对象自检"（cwd 是 worktree、不用 `bash -c`、记录 GOWORK/replace、负向验证） | D5 |
| `references/project-profile.multi-model.example.json` | `cb-review` 的 `cost_class` 改 `standard` 并在 `description` 说明真实成本与 pin 耦合 | 9.3 |
| `references/group-plan-schema.md` | 示例 `"task_type": "api"` → `"feature"`；补词表与"不退化而是整请求被拒"的口径 | D9 |
| `references/runtime-contract.md` | 补三个示例文件的"示例值不是推荐值"说明：`max_active_tasks: 1`、`cost_class: premium` 的 pin 陷阱、`register` 会补默认字段、`spend_guard` 不要顺手填 | 3.6 承诺、R7 |

`python3 build.py --check` 通过（`references/` 在 `WHITELIST` 内，`docs/` 不在）。

### 9.5 待执行的验收命令（人工）

**`expected_version` 与 `subject_sha` 必须逐任务现取，不能照抄**（四个任务的实际 `row_version` 在
2026-11-04 是 `18/18/18/23`，各不相同；抄错会 `VERSION_CONFLICT`）：

```bash
zoe task status <TASK> --json | jq '{row_version, validated_sha, current_run_id}'
```

```json
{
  "schema_version": 2,
  "request_id": "<uuid4>",
  "expected_version": "<row_version，现取>",
  "authorization_ref": "local-session-zoe-go",
  "reason": "checks 已在 worktree 内重跑，证据来自 build/vet/test；人工复核后验收",
  "decision": "accepted",
  "actor": "<你的名字>",
  "evidence": "<current_run_id>: build/vet/test PASS；指纹与候选一致",
  "subject_sha": "<validated_sha，现取>"
}
```

```bash
zoe task accept <TASK> --request-file accept-<TASK>.json
```

以 `task-0234ce049bbc447e` 为例，当前值为 `row_version=18`、
`subject_sha=228a82f96ae6588462fefe5d1991e8ffce20e9df`、`current_run_id=run-b9f2fbb252954bc7`。

已外部合并且不愿重验的任务用 `close-external`（`claim` 二选一），不要用 `accept` 追补。

---

## 10. 独立审查（2026-11-04，v2.2 依据）

审查方式：不采信第 9 节的自我报告，重新读配置、状态库、runtime 源码，并**实跑**文档中的命令与模板。

### 10.1 确认成立的部分

| 项 | 复核方式 | 结果 |
|---|---|---|
| 有界查询返回 `next_cursor` | `zoe watch --project zoe-go --json` | 键含 `next_cursor`，值 `e553b7c…:218` |
| `--follow` 不回传 `next_cursor` | 同命令加 `--follow --jsonl --timeout 3` 再 `grep -c next_cursor` | `0` |
| 无事件时的行为 | 用当前游标 `--after` 再查一次 | 输出一行 `cursor_status=heartbeat` 的 meta，游标不变 |
| 监控模板可运行 | 按 3.4.2 逻辑加轮次上限实跑 2 轮 | 游标推进、heartbeat 不落盘、重启复用游标 |
| 路由映射生效 | `zoe route plan` + `route.task_type` | `docs→cb-flash`、`feature/review→cb-pro`、未声明 `→cb-pro`（`catch_all_preference`） |
| 授权记录与配置一致 | 比对 `zoe-go.attest.json` 的 `policy_hash` 与当前摘要 | 同为 `68c4518…c77b99` |
| 4 个 run id 与 9.2 一致 | `task status` 取 `current_run_id` | `b9f2fbb` / `6e8c860` / `3202274` / `a61df4d` |
| 负向验证日志存在 | `ls /tmp/neg-build.log` | 存在（86 字节） |
| `max_group_repairs` 缺省 0 | `_group_runner.py:812` docstring + 849 行错误分支 | 成立 |
| `rebind` 的 revalidate 语义 | `_pipeline` 的 `_revalidation_product` / `_revalidation_blockers` | 成立（产物完整 + local_artifact + 无活跃 run） |

### 10.2 发现并已修复的缺陷

| # | 发现 | 严重度 | 后果 | 处理 |
|---|---|---|---|---|
| R1 | 3.4.2 游标文件**只写不读** | 高 | 重启后重新取"当前末端"，**跳过停机期间的事件**（静默丢事件） | 启动先读 `CURSOR_FILE` |
| R2 | 全部目标 `BLOCKED` 时**死循环** | 高 | `alive` 恒为 1，永不退出，监控空转 | 引入 `need_human`，`alive==0 && need_human>0` 时 `exit 10` |
| R3 | `zoe` 失败被 `jq` 的 exit 0 掩盖 | 中 | 状态读不到被当成"仍在运行" | `set -o pipefail` + `st` 空值判定 |
| R4 | 3.4.3 未写 `--log` 缺省 `agent` | 中 | 重验 run 无 agent 日志，`task logs` 直接 `INPUT_INCOMPLETE`，命令照抄即失败 | 补三条实测口径 |
| R5 | 3.3.5 让读者"在任务 worktree 里"注入错误 | 高 | 指纹被改 ⇒ `rebind` 返回 `WORKSPACE_CHANGED`，**自己毁掉重验路径** | 改为一次性临时 worktree |
| R6 | 9.5 写死 `expected_version: 24` | 中 | 实际 `18/18/18/23`，照抄 `VERSION_CONFLICT` | 改为现取，并给出示例任务的真实值 |
| R7 | 3.6 承诺改 `runtime-contract.md`，未落 | 中 | 示例值（`max_active_tasks: 1`、`premium`）仍会被照抄 | 已补示例值说明与 `spend_guard` 警告 |
| R8 | 9.3 用"实测"描述只由代码推断的结论 | 中 | 证据越级：`run.model_identity` 从未在 runtime 中观测 | 降级为"代码推断 + CLI 实测"，并注明补法 |
| R9 | 未说明 `task_type` 写在请求顶层会被忽略 | 中 | 路由静默退化为默认档，用户以为已降档 | 3.2.6 补正误写法与实测输出 |
| R10 | 9.4 只列"未完成"，漏"未验证" | 低 | 读者会以为 7.1 的吞吐、名额、组验收都验过了 | 拆成"未完成 / 未验证"两表 |
| R11 | 模板全程静默，无进度输出 | 低 | 无法验证"仍在监控"；实跑 10 秒零输出 | 每轮 `[tick]`，实跑已复现 |

### 10.3 功能完整度（按目标计）

| 目标 | 完整度 | 依据 |
|---|---|---|
| 验证正确性（D5） | **100%** | checks 三态 argv、doctor 全 `ok`、负向验证 rc=1 |
| 历史证据重建（D12） | **100%** | 4/4 `rebind→resume`，新证据三态 PASS |
| 执行组合分级（D1/D14） | **L1 100% / L2 0% / L3 不可得** | `model_unresolved=false` 已达成；`model_identity` 从未在 runtime 观测 |
| 监控升级（D2/D10） | **模板 100% / 落库 0%** | 模板修后实跑通过；未进 `scripts/` |
| 组交付（D4/D13） | **文档 100% / 实测 0%** | 只改文档，未创建过组 |
| 验收收口（D3） | **0%** | 需人工 `accept`，未执行 |
| 统计口径（3.1.7） | **文档 100% / 工具 0%** | 无统计命令，仅报告口径 |
| 备份与恢复（D15） | **100%** | `sqlite3 .backup` + `integrity_check=ok` |

**结论**：配置面与验证面已经闭环；**监控、组、模型身份 L2、验收四块仍停在"可执行但未执行"**。
因此不能对外表述为"文档功能已完整实现"，准确说法是"配置与验证链路完整落地，流程面按 9.4 待补"。

---

## 11. 运行侧修复（2026-11-04，v2.3）

第 9.3 节把"`model_identity` 恒为 `unobserved`"写成结论。修复前重新采集了一次真实输出，
**该结论不成立**，因此按新证据改代码，而不是按旧结论继续绕。

### 11.1 采集与更正

`codebuddy -p --output-format stream-json --model BC-DeepSeek-V4-Flash`（2.111.0）的等价形状：

| 行 | 结构位置 | 值 | 是什么 |
|---|---|---|---|
| `type=system, subtype=init` | 顶层 `model` | `custom-local:BC-DeepSeek-V4-Flash` | **请求回显**（不是运行事实） |
| `type=assistant` | `message.model` | `deepseek-v4.1-flash` | 供应商侧模型 |
| `type=result` | — | 无 model 字段 | 终态只带 usage/cost |

而 `--output-format json`（缓冲式）里，供应商模型同时在 `providerData.model` 与
`providerData.requestModelId/requestModelName`。

两个更正：

1. `model_of` 本来就读 `message.model`，所以 stream-json 路径**不是** `unobserved`；
2. 真实障碍是"同一模型的两个叫法 + 回显被当成运行观测" ⇒ 判成 `mixed`/`mismatch`，
   `pin_model` 仍然阻断。降 `cost_class` 只是关掉要求，不解决证据问题。

### 11.2 runtime 修复（zoe-runtime 1.5.1）

| 项 | 行为 | 落点 |
|---|---|---|
| `model_of` 读 `providerData.model` | 覆盖 `--output-format json` 里顶层无 `model` 的形态；忽略 `unknown` 占位串 | `_agents/base.py` |
| `request_echo` 作用域 | `system`/`init` 的 `model` 只进 `reported_models` 供审计，不参与身份判定 | `_agents/base.py`、`_routing.model_identity` |
| `model_aliases` → `alias_confirmed` | profile 声明"请求名与上报名是同一个模型"；全部上报值落在 `{model} ∪ aliases` 内但不是逐字相等 ⇒ `alias_confirmed`，`identity_basis=declared_alias` | `_agents/base.py`、`_routing` |
| pin 放行条件 | `reported_match` / `alias_confirmed`；未声明别名时仍是 `mismatch`/`mixed` | `_routing.pin_blocks`、`_pipeline._gate_model_identity` |
| 统计口径 | `counts.runs_identity_alias` 单列；`attribution` 不把声明等价当逐字一致（不进能力比较） | `_routing` |

对应地，`cb-pro` 恢复 `premium` 现在是**可执行**的（需人重新 `attest`），不再依赖降档绕开 pin。

### 11.3 文档面缺陷修复

| 原缺陷 | 修复 |
|---|---|
| D10：`--follow` 不回传游标 | 首行 `follow_start.cursor`、末行 `follow_end.next_cursor`（`cursor_expired` 同样带） |
| 6.2：`recover` 必须显式 `--run`、不支持 `--json` | `--run` 缺省取 `current_run_id`，响应带 `run_source`，接受 `--json` |
| 9.4：监控模板未落库 | `zoe-workflows/scripts/zoe-monitor.sh`（游标先读后写、事件先落盘再推进、`need_human` 退出 10、watch 失败上限退出 11、每轮 `[tick]`），并加入 `build.py` 的 `REQUIRED_FILES` 与可执行位检查 |

监控脚本已用假 CLI 实跑四种场景：全部终态 → 0；`BLOCKED`/`INPUT_REQUIRED` → 10；
一个 DONE 一个 RUNNING → 继续；`watch` 连续失败 → 11。

### 11.5 代码审查后的修复（2026-11-04，v2.4）

对 §11 之后的实现做了一次独立审查，发现三处功能缺陷与一处监控缺口，均已修复：

| 缺陷 | 事实 | 修复 |
|---|---|---|
| `rebind` 首次重验会接纳被篡改的 worktree | 基准取自当前树，`WORKSPACE_CHANGED` 只在"第二次 rebind"触发；人改的内容会被当 agent 产物重新签字 | 基准改取 `validated_sha/validated_fingerprint`，`not blockers and not product_intact` 即 `WORKSPACE_CHANGED`（`_pipeline.rebind`） |
| v3 组里 `group_id` + 非 `group_member` 可绑成成员 | 冻结 spec 校验只对 `group_member` 生效，绑定却无条件；`task accept` 的自验收拦截按 `delivery_mode` 判断，拦不住 | `create` 前置校验：v3 组的 `group_id/item_id` 要求 `delivery_mode=group_member`；legacy ordered 组沿用旧语义（`_pipeline.create`） |
| `stop.resume_hint` 在 `review_ready` 上是死命令 | `review_ready` 同时在 `_RESUMABLE`/`_NEEDS_HUMAN`；hint 恒为 `group start`，而 `begin`/`resume` 都不接受 `REVIEW_READY` | `_RESUMABLE` 与 `_NEEDS_HUMAN` 互斥；hint 按原因给 review/accept/repair/status（`_group_runner._resume_hint`） |
| 监控把 `INPUT_REQUIRED` 当 state，漏了 `REVIEW_READY` | `INPUT_REQUIRED` 是 `block_code`；`REVIEW_READY` 被当作"还在跑"，循环静默等待人工验收 | 脚本读 `state` + `block_code`，`REVIEW_READY` 与 `INPUT_REQUIRED` 单独标记；游标只取第一行（`scripts/zoe-monitor.sh`） |

回归：新增 4 条 runtime 测试（首次 rebind 漂移、从未验证的任务不误判、v3 组非成员绑定、
`review_ready` 停止语义）与监控脚本四个场景实跑；runtime 全量通过，`ruff check` /
`ruff format --check` 全绿。

### 11.4 仍未做（口径不变）

| 项 | 状态 |
|---|---|
| L3（服务端实际模型） | 仍无证据源 |
| 4 个任务的 `accept` | 仍需人工决定 |
| 阶段 2（移除 `cb-run`） | 需先收口 |
| 组交付实测、吞吐/名额记录 | 仍未执行（见 9.4） |

因此本轮能说的是"**观测口径与监控工具已修复并自测**"，不是"交付流程已全部验收"。
