# 配置摩擦优化方案（v8）

| 项 | 内容 |
|---|---|
| 日期 | 2026-10-30 |
| 输入 | 《配置摩擦评估》+ 外部建议一（统一准备入口）+ 外部建议二（兼顾小任务）+ 对 v4 的评审 |
| 被改对象 | `zoe-runtime`（v1.4.1 工作区）；`zoe-workflows` 只做文档同步 |
| 方法 | 逐条判定 → 冻结接口 → 给可判错的验收；被评审推翻的设计直接改写，不保留旧表述 |
| 本文位置 | `zoe-workflows/docs/`（不在 `build.py` 的 `WHITELIST` 内，不进入发布包） |
| 核验状态 | 本文标注为"已实现"的项均已在本工作区用 grep/read 核验；行号为 2026-10-30 快照，`cli.py`/`_config.py` 当日有推进，以函数名为准 |

## 修订记录

| 版本 | 变化 |
|---|---|
| v1 | 自评估取证后的六批方案（校验聚合 / dry-run / checks 预检 / 影响面 / allowed_paths 提示 / 文档） |
| v2 | 合并"统一准备入口"建议：新增 B7 `task prepare`；B4 改为双摘要；新增恢复分类与回放验收 |
| v3 | 对照"注册一次 / Spec 模板化 / watch --follow"重核代码：B3 已实现；新增 B8 模板与生成、§4.1 监控口径 |
| v4 | 合并"兼顾小任务"建议：新增 B9 轻量路径；分流判据改为四维度；明确不做 `quick` |
| **v5** | 按评审修正 **三项核心契约 + 三项同批项**：① `task_scope` 空值回退会扩权（改为 `is not None` + 显式空即拒）；② 「allowed 与 protected 有交集就拒」是新增限制（改为"显式声明才拒 + 祖先关系只提示 + 有效权限取差集"）；③ `prepare` 的幂等/生成/输出混写（拆成三种操作、`uuid4`、去掉 `changes[]`、`prepared` 改为快照语义）；④ 路径语义（Windows/符号链接/仓库边界）从 P2 提到第一批；⑤ 首期**不开放**空 checks；⑥ 修正四处指标误导（`SCOPE_VIOLATION`、126/127、`attempts`、"零写入"）。标题与修订记录统一为 v5 |
| **v6** | 第一批落地：B0（`_paths.py` + `task_scope` 冻结 + 保护路径差集）、B1（`_config.Diagnostics` 聚合）、B2（`register --dry-run`）、B5（路径警告）、B7（`_prepare.py` 三操作）、B8（两个模板 + 占位符拒绝 + `--emit`）、B10（profile 展示）。第二批（`project diff`、执行复校、Windows 实机）未做。差异与行为变更见新增 §8 |
| **v7** | 第二批落地：**B4 `project diff`**（`src/_diff.py` + 13 项测试，预览与 rebind 同源校验）；路径单测补 7 项（符号链接 / `..` / 组件边界 / `git` 文件边界 / 空 parent）；`report-template.md` 加"轻量结果"；**纠正一处旧判断**——checks 执行时复校早已实现（`resolve_check` + `error_class: environment`），不是待办。仅剩 Windows 实机验证与基线检查 |
| **v8** | 代码复查后的修复（设计未变，修的是实现）：① 项目与 spec 的 `allowed_paths` 都拒绝 `""` / `"."` / 绝对路径——此前 `"."` 能让 `is_within` 退化成"任意位置"，等于把项目授权放大成全仓；② `is_within` 对空/`"."` 父级返回 `False`；③ `project diff` 快照缺失时给 `False` 且不产出 rebind 命令；④ `prepare` 未注册时 `scope_source="unregistered"` + `SCOPE_UNVERIFIED`；⑤ `spec_hash` 与 `create` 同源；⑥ 删除 `--template standard`；⑦ `quarantine` 跟随 `task_scope`；⑧ 小修：`profile.authorized` 恒为布尔、非法 `--project` 过 `safe_id`、`spec_scope` 去重、`describe_missing` 接入警告、`prefix_covered` 转公开 |

---

## 0. 结论

方向不变：**降低首次配置成本，不新增系统模块**。v5 的变化全部是"把已有设计收紧到可实现、可判错"，不增加功能面。

| 外部建议 | 判定 | 落点 |
|---|---|---|
| 统一准备入口、准备不入库 | 采纳 | B7（三种操作分开） |
| 项目默认值 / 任务差异分层 | 已实现，补"来源 + 探测时间" | B7、B8 |
| `allowed_paths` 自动建议、不自动扩权 | 采纳，**语义重写** | B5 |
| `checks` 发现 / 引用 / 静态验证 | 部分采纳（静态预检已实现，执行复校待做） | B3 |
| 错误一次报全 + 结构化诊断 | 采纳，**措辞收紧**（只聚合可独立判断的问题） | B1 |
| 按变化影响恢复 | 部分已实现，补分类表 | §4 |
| 兼顾小任务、两种准备深度、同一引擎 | 采纳，**但首期不开放空 checks** | B9 |
| 路径 / Windows / 符号链接 | 采纳，**提到第一批** | B0 |
| 与模型授权衔接 | 采纳最小部分 | B10 |
| `quick` 参数 / 独立小任务系统 / runtime 解析自然语言 / `changes[]` | 不做 | §5 |

### 0.1 三个目的的达成对照

| 目的 | 代码现状 | 判定 |
|---|---|---|
| 项目注册一次，后续任务零成本 | `create` 每次 `store.config(project_id)` 读已注册文件（`_pipeline.py:311`） | **已达成**，不依赖本文档 |
| Spec 模板化，复制改改就行 | 只有 Markdown `spec-template.md` 与 `cli-contract.md` 文本示例；无 `spec.json` / `create.json` 模板；`request_id` 是幂等主键（`_store.py:252-265`），复制忘改即 `REQUEST_CONFLICT` | **部分达成**，由 B8 补齐 |
| watch --follow 代替轮询 | 过滤已生效（`cli.py:876-916`）；`task events/logs --follow`、`_progress.py` 均已实现 | **达成到"窗口内秒级 + 窗口重启"**，见 §4.1 |

### 0.2 小任务建议的判定

| 建议 | 判定 | 依据 |
|---|---|---|
| 用四维度替代时长/行数 | 采纳 | 那套阈值在本仓库文档中 **0 命中**（`zoe-workflows` + `zoe-runtime/docs` 全量 grep）；靶子不在现有 SKILL.md 里，但方向正确，用于改写分流表 |
| 一个入口、两种准备深度、同一引擎 | 采纳 | B9 |
| 小任务也有 Spec | 采纳 | 下限由契约决定，压不到"一句话直接执行" |
| 不给小任务跑昂贵路由 | **已实现** | 仅配 `routing` 或请求带 `route` 才走 `plan_route`（`_pipeline.py:327`），纯规则无模型调用 |
| 可升级、不静默扩权 | 已实现，补口径 | §4 + B9-d |
| 简洁结果 + 后台完整记录 | 已实现，补模板 | `task report` / `report.md` / `task summary` |
| 首期只支持"已配置项目内、明确目标、单任务、无需新权限" | 采纳为边界 | B9 适用范围 |

---

## 1. v4 评审的六项必修（本节是 v5 的改动依据）

| # | v4 的问题 | 判定 | v5 处理 |
|---|---|---|---|
| 1 | `t["task_scope"] or t["config"]["allowed_paths"]`：空列表 falsy，退回项目全范围 = **扩权** | 成立 | 改 `is not None`；显式空范围在 create 期拒绝；见 B0 |
| 2 | 「allowed 与 protected 有交集就拒」把 `["src"]` vs `["src/security"]` 这种合法配置判死，**属新增限制** | 成立 | 只有"显式声明保护路径本身或其子路径"才拒；祖先关系只提示；有效权限取差集；见 B5-b |
| 3 | `prepare` 同时要求幂等、随机 `request_id`、`changes[]`、不覆盖、`--emit`，无法写出确定测试 | 成立 | 拆成三种操作；`uuid4`；**删掉 `changes[]`**；见 B7 |
| 4 | `prepared: true` 声称"策略自 prepare 起未变"，只读预检无法保证 | 成立 | 改为"本次快照下通过"，附 `snapshot`，create/start 复核；见 B7.4 |
| 5 | 空 checks 的限定条件（无 check 型 AC + local_artifact）挡不住绕过：鉴权改动也能写成 manual AC | 成立 | **首期不开放空数组**；见 B9-c |
| 6 | 路径/Windows/符号链接不能放 P2 | 成立 | 提到第一批，与 task_scope 同批；见 B0 |

评审另指出四处收紧、五处指标误导，均已并入本文（§3.3、§4.1、B8、§7）。

---

## 2. 现状缺陷（v5 必须一并修）

### 2.1 `spec.allowed_paths` 不影响实际 scope

`create` 冻结的是项目配置本身（`_pipeline.py:311-313`、`:440`），`load_spec` 只验证不改写（`_contracts.py:203-243`），运行期范围检查读 `c["allowed_paths"]`（`_backend.py:607`）。

**后果**：spec 写 `["internal/export"]` 看起来收紧了，实际按项目全范围放行。

**必须同时说清的边界**：即使修好，`scope()` 也只是在 run 结束后做 diff 检查，保证的是**拒收越界产物**；`local-process` 下 worktree 不是沙箱，它**不阻止** Agent 写入越界文件。文档与汇报都不得写成"已阻止越界写入"。

### 2.2 保护路径与允许路径的关系被误读

`validate_spec_text` 只查"是否放宽"（`_contracts.py:186-199`），`_backend.scope()` 是拒绝优先（`_backend.py:607-628`）。合法形态 `allowed: ["src"]` + `protected: ["src/security"]` 现在既不在 create 期提示，也不在文档里解释；而错误的实现方式（要求两个列表不相交）会误杀它。

### 2.3 两套摘要不是同一个值

| 用途 | 值 | 位置 |
|---|---|---|
| 记录与展示 | `digest(c)[:16]` | `_pipeline.py` 8 处 |
| start 闸门 | `digest(normalize_config(c))` | `_start_locked`、`_profiles.py:148-159` |
| `rebind` 入参 | `digest(c)` 完整 64 位 | `rebind` 段 |

`project diff` 必须同时输出 `policy_hash`（完整，供 rebind）与 `policy_revision`（16 位，给人看）。

---

## 3. 方案批次

### 3.1 B0 路径与范围语义（第一批第 1 项）

#### B0-a `task_scope` 空值语义（修正 v4）

```
task_scope  = normalize(spec.allowed_paths)          # 规范化、只存"允许"部分
effective   = task_scope − config.protected_paths    # 集合差，运行时解释
```

| 情况 | 行为 |
|---|---|
| 任务记录**没有** `task_scope` 字段（历史任务） | 用冻结的项目 `allowed_paths`（兼容规则，不加迁移） |
| `task_scope` 为非空列表 | 用它 |
| `task_scope` 显式为 `[]` | **create 期拒绝**（`POLICY_DENIED`：任务范围为空的改动不可交付）；运行期不存在"空则回退" |
| spec 声明超出项目范围 | **`POLICY_DENIED`**，不静默取交集掩盖错误 |

实现要点：判定一律用 `t.get("task_scope") is not None`，**禁止 `or` 回退**。`protected_paths` 仍从 `t["config"]` 现读（不并入 `task_scope`），否则 rebind 后保护列表变了却沿用旧快照。`scope()`（`_backend.py:607-639`）的允许列表改为 `task_scope`（存在时），保护列表不变——两者的判定顺序保持"保护优先"，因此有效权限天然等于差集，不需要额外求交。

#### B0-b 保护路径语义（修正 v4 的 B5-b）

| 情况 | 处理 |
|---|---|
| spec **显式声明**保护路径本身或其子路径（`p == prot` 或 `p` 在 `prot/` 下） | `POLICY_DENIED`：等于要求修改保护目录 |
| 允许目录是保护路径的**祖先**（`["src"]` ⊃ `["src/security"]`） | `warning: protected_subset`，**不阻断** |
| 有效权限 | `allowed − protected`，按路径组成部分逐条扣减 |
| 实际产物命中保护路径 | 运行期拒收（已有行为，不变） |

验收：`allowed:["src"] + protected:["src/security"]` 可创建（有 warning），改动 `src/security/x` 被运行期拒；`allowed:["src/security"]` 在 create 期即拒。

#### B0-c 跨平台路径（从 P2 提到第一批）

- 分隔符归一（`\` → `/`）与 `.`/`..` 折叠，仅在**比较**时进行，不改用户原文；
- 目录边界：`src/a` 不匹配 `src/abc`（现有 `_prefix_covered` 已正确，不得回退成裸 `startswith`）；
- 符号链接与"新建文件的父目录"越界：比较前对**已存在的最深祖先**做 `realpath`；
- 大小写：按目标文件系统行为判定，不一律转小写（macOS 默认不区分、部分 Linux 区分）；
- `--repo` 规范化与仓库边界见 B7.2。

**验收**：同一组用例在 macOS 与 Windows 各跑一遍，包含 `src\a`、`src/../src/a`、`src/a` vs `src/abc`、符号链接目录外指、大小写差异五种。

### 3.2 B1 校验聚合（措辞收紧）

**不承诺"所有错误一次报完"**。语义冻结为：

> 聚合所有**能够独立判断**的问题；依赖无效字段的检查标为 `skipped`，不制造连锁假错误。

响应：顶层 `code`/`message` 保持"第一个错误"，新增 `details.errors[]`（`code` / `field` / `reason` / `suggested_change` / `requires_approval` / `source` / `observed_at`），以及 `details.skipped[]`。

两阶段：结构门（`schema_version`、`project_id`、`repo` 是目录、backend 非 docker）立即抛；独立字段聚合。`_profiles.normalize_config` 的错误仍不进聚合（已知边界）。

验收：3 处独立错误一次返回 3 条；`repo` 不存在时返回 1 条 + `skipped` 列表，且不出现"路径不存在"之外的连锁错误。

### 3.3 B2 `project register --dry-run`

分支放在 `Store(args.home)` 之前（`cli.py:1356`），与无项目 `doctor`（`cli.py:1348`）同位置。

**"零写入"的准确定义**：不写 Zoe 状态库、不写 `projects/*.json`、不取项目锁。命令自身的 stdout 不算写入。

输出 `valid` / `policy_hash` / `policy_revision` / `would_write` / `will_overwrite` / `warnings` / `normalized`。

验收：dry-run 前后 `$ZOE_HOME` 无变化、`state.db` 不存在；去掉 `--dry-run` 后 `policy_hash` 与 dry-run 一致。

### 3.4 B3 checks 预检（拆成两件事）

| 部分 | 状态 |
|---|---|
| 静态预检 `checks_preflight()`（`_config.py:122`，doctor 接入 `:313-320`、`:393-395`） | **已实现** |
| 执行时复校 | **已实现（既有，早于本方案）**：`_run_checks` 用 `resolve_check` 拦 `unresolved` → 该 check `FAIL` + `error_class: environment`，`shell` / `deferred` 放行 |

**统一状态表**（消除四态/五态混用）：实现产出四种 —— `ok` / `shell` / `deferred` / `unresolved`；`capabilities.observation.checks_preflight_statuses` 里的 `invalid` 是保留值，当前不会产出。

`shell` 与 `deferred` 都表示**静态确认未完成**，不等于已验证。`checks_preflight_ok = all(status in ("ok","shell","deferred"))`（`_config.py:318-320`），并**已并入 `ready`**（`:347-353`）——这与 v3 的建议相反，代价是 `ready: false` 可能同时代表"缺 git"和"check 拼错"，宿主必须读子项区分。

**`deferred` 的来源必须可解释**：仅当 `argv[0]` 指向已知生成目录（`node_modules/.bin`、`.venv/bin`、`target/debug`、`bin`、`dist/bin`）时才标 deferred；其余不可解析一律 `unresolved`。白名单之外禁止使用 deferred。

验收：依赖未装 → `deferred` 且 `ready` 不受影响；拼错 → `unresolved` 且 `ready: false`；不在白名单的路径 → `unresolved`。

### 3.5 B4 `project diff`（第二批）

输出 `changed_fields`、`policy_hash`（完整）、`policy_revision`（16 位）、`affected_tasks[]`（同项目 `READY/PAUSED/BLOCKED/RUNNING`）、`suggested_commands[]`。`spec_valid_under_new_policy` 必须调用 `_contracts.validate_spec_text(frozen_spec, new_config)`——与 `rebind` 同一调用。

不提供批量执行（§5）。

### 3.6 B5 `allowed_paths` 建议（提示级）

`prepare` / dry-run 输出 `allowed_paths.suggested[]`，来源优先级：spec 显式声明 > spec 正文提到的仓库内路径 > 相关测试与配置目录。每条带 `source` 与 `observed_at`；只建议，不写入。存在性/`git ls-files` 检查给 `warnings`，不阻断。

### 3.7 B7 `task prepare`（重写：三种操作分开）

```text
zoe task prepare --project P --spec spec.json               # 预检
zoe task prepare --repo PATH --spec spec.json               # 未注册：只读探测 + 注册草案
zoe task prepare --repo PATH --emit DIR                      # 生成草稿（spec 可省略）
```

#### 7.1 三种操作，语义互不重叠

| 操作 | 读 | 写 | 幂等 |
|---|---|---|---|
| 预检（默认） | 项目配置、spec、仓库 | 无 | 必然幂等 |
| `--out FILE` | 同上 | 该报告文件；已存在默认拒绝（`--force` 覆盖） | 内容相同则文件相同（不含时间戳外的不确定字段） |
| `--emit DIR` | 同上（`--spec` 可省） | `spec.json` + `create.json`；已存在**保留**，不覆盖 | 见 7.3 |

`--out` 与 `--emit` 互斥；`--emit` 允许没有 `--spec`（从 `--title`/`--intent` 起步），预检模式必须给 `--spec`。

#### 7.2 `--repo` 的匹配顺序

先用 `git rev-parse --show-toplevel` 确认真实仓库边界，再在 `$ZOE_HOME/projects/*.json` 里比对 `repo`：

1. 完全相等 → 命中；
2. PATH 是该项目 `repo` 的子目录 → 命中；
3. 命中多个不同 `project_id` → `PROJECT_AMBIGUOUS` + `candidates[]`，**不猜**（不设"最长匹配优先"这种隐式规则）；
4. 嵌套仓库（PATH 自身是另一个 git 仓库根）→ **不**归到外层项目，按未注册处理；
5. 无命中 → `registered: false` + 注册草案。

#### 7.3 草稿与 `request_id`

| 场景 | 规则 |
|---|---|
| 新建任务草稿 | `request_id = uuid4()`，写入 `create.json` |
| 重试同一任务（草稿已存在） | **复用**草稿里的 `request_id`；`--emit` 不覆盖已有文件 |
| 需要新任务 | 重新 `--emit` 到新目录，或用 `--force` 重建 |

不使用"时间戳 + 四位随机"这类自造格式。

#### 7.4 `prepared` 是快照结论，不是保证

```json
"prepared": true,
"snapshot": {"policy_hash": "…", "spec_hash": "…", "base_sha": "…",
             "observed_at": 1793500042.0,
             "checks_preflight": {"ok": 2, "shell": 0, "deferred": 1, "unresolved": 0},
             "static_checks_done": ["spec_valid", "checks_preflight", "scope_covered"],
             "static_checks_skipped": [{"check": "deploy_window", "reason": "cannot be judged statically"}]}
```

语义：**在本次观测快照下，已执行的准备检查通过**。`create`/`start` 用同一套校验复核，条件变化即返回明确诊断（`POLICY_CHANGED` / `SPEC_CHANGED` / `PROJECT_MISMATCH` 等），**不引入准备状态库**。

#### 7.5 输出（其余字段）

`project{project_id, registered, policy_hash, policy_revision}`、`repo{path, base_ref, base_sha, dirty, language_hints, observed_at}`、`spec{valid, effective_allowed_paths, scope_source}`、`allowed_paths{suggested, warnings}`、`checks{selected, preflight, suggested}`、`diagnostics[]`、`profile{…}`（见 B10）、`next[]`。

**不输出 `changes[]`**：没有上次报告或基线输入时无法定义"变化"，首期不做。

验收：`--repo` 对不存在的 `$ZOE_HOME` 运行后仍不存在；预检模式跑两次输出稳定字段一致；`--emit` 二次运行不改动已有草稿；`prepared:false` 时必有一条以上 `diagnostics`。

### 3.8 B8 模板与占位符（修正）

两个模板进 `references/` 并加入 `build.py` 的 `REQUIRED_FILES`：`spec.example.json`、`create-request.example.json`。

**占位符必须被显式拒绝**：`safe_id` 只约束 `project_id` / `check_id` 之类，`title`、AC `statement`、`instructions`、`allowed_paths` 条目里的 `<FILL:...>` 都能通过现有校验。因此 B8 必须新增一条规则：

> 任何字符串字段包含字面量 `<FILL:` → `INPUT_INCOMPLETE`，`field` 指向该字段。

验收：逐个位置（`title` / AC `statement` / `instructions` / `allowed_paths[]` / `create.json` 的 `title`）各测一次未替换即拒；全部替换后通过；同一模板连续创建两个任务不撞 `REQUEST_CONFLICT`。

### 3.9 B9 轻量路径（首期不开放空 checks）

两档准备深度，**同一引擎**（`create → start → verify → accept` 不变），不新增状态机、不新增 `quick` 布尔参数。

| 维度 | 轻量 | 标准 |
|---|---|---|
| 适用范围 | 目标明确、修改集中、现有授权内、验收简单 | 多模块、有歧义、多依赖或高风险 |
| 契约 | 最小契约 | 完整 AC 三层 |
| 检查 | **至少一个**与改动相关的 check（见 9-c） | 全量或明确子集 |
| 项目配置 | 复用（B7.2 自动匹配） | 复用，必要时补齐 |
| 任务组 | 不创建 | 有依赖时才创建 |

#### 9-a 最小契约

```json
{"schema_version": 2,
 "title": "<FILL:一句话目标>",
 "allowed_paths": ["<FILL:目标路径>"],
 "acceptance_criteria": [{"id": "AC-1", "statement": "<FILL:可判定的完成条件>",
   "verification": {"type": "manual", "instructions": "<FILL:谁来判、怎么判>"}}]}
```

下限由契约决定：`schema_version` / `title` / `acceptance_criteria`（manual 必须带 `instructions`）不可省。`allowed_paths` 必须给（B0 后它真的生效）。"只填三处"只作为**指标 2 的场景承诺**，不是通用保证。

#### 9-b 分工

"一句话 → 这份 JSON"是 **skill 的职责**；runtime 只校验、冻结、执行。runtime 不接受自然语言。

#### 9-c 空 checks：首期不开放（修正 v4）

理由：限定条件"无 check 型 AC + local_artifact"挡不住绕过——改鉴权代码也能被人为写成 manual AC。首期规则：

1. 项目有强制检查时，任务不得省略；
2. spec 引用了某个 check，该 check 必须被选中；
3. 空选择**不得**被解释为验证通过（`NOT_RUN` 永远不是 `PASS`）；
4. 人工验收要求满足后才进成功终态；
5. **skill 不得为提速把 `check` 型 AC 改成 `manual`**。

同时修正 v4 文案：选"必须选一个 check"**不等于**"README 改包名必须跑单测"——完全可以为文档任务配一个轻量检查（`markdownlint`、`git diff --check`、或一条文本核对脚本）。这是配置建议，不是例外通道。

若将来要开放"纯人工交付"，单独立项并定义"无自动检查但已人工验收"的契约，不混进轻量路径。

#### 9-d 升级路径（复用现有命令）

触发：实际改动超出 `allowed_paths`、需新依赖或改公共接口/数据结构、出现影响实现的歧义、实际跨模块。动作：`task pause` → `task revise`（旧证据失效）→ 必要时 `rebind`（扩权仍需批准）。不重配项目、不新建任务、产物保留。

#### 9-e 简洁结果

成功一句话：改了什么、改了哪些文件、哪项检查通过、任务 ID；失败说清阻塞、下一步、是否消耗实现次数。**验收结论、`NOT_RUN`、未验证项不得省略**。

### 3.10 B10 与 profile / 模型授权的衔接（最小部分）

`prepare` 复用 `_routing` / `_profiles`，**不新增第二套选择逻辑**：

```json
"profile": {"selected": "cb-approved", "source": "explicit|default|routing",
            "authorized": true, "model": "…", "model_source": "profile|cli-default",
            "model_unresolved": false,
            "conflicts": [{"code": "MODEL_PIN_CONFLICT", "detail": "…"}]}
```

规则：显示将用的 profile；校验其在 `authorized_actions` 内；显式 `model` 与 `allow_cli_default_model` 冲突时报告；用户要求固定模型时不接受身份不确定的默认；**预检过程不调用模型、不切昂贵模型**。

### 3.11 B6 文档同步

- `runtime-contract.md`：接入五步（`prepare` → `register --dry-run` → `register` → `doctor` → `create/start`）；`--config -` 按当前工作目录解析；`ready` 与 `checks_preflight_ok` 是两个子项，`ready:false` 需读子项区分。
- `cli-contract.md`：`task prepare`（三种操作）、`register --dry-run`、`project diff`、`checks_preflight`、`details.errors/skipped`、`task_scope` / `scope_source`。
- `SKILL.md`：分流表改为四维度（目标明确、权限可控、易验证、需持续或恢复），"在旁边盯着"只降低后台监控需求、不再是否决项；轻量任务走轻量路径而不是"不用 Zoe"。

---

## 4. 恢复路径分类

| 变化 | 现有通道 | 恢复动作 | 缺口 |
|---|---|---|---|
| 登录态、工具路径 | `_ENVIRONMENT_INCIDENTS` | 重跑 doctor/prepare；工具身份变化按 `runtime_binding` 评估证据 | 无"只重跑预检"的独立入口 |
| check 命令 / 验收标准 | `VERIFICATION_NOT_APPLICABLE` + `revalidate.pending` | 旧证据失效；`local_artifact` 且产物未变时只重跑 checks | 已实现 |
| 权限范围 | `_POLICY_INCIDENTS` | 保留产物，`rebind` 显式接纳并重新校验 spec | 已实现（逐任务） |
| Spec 目标 | `SPEC_CHANGED` | `revise`，旧验收与验证失效 | 已实现 |
| 执行归属未知 | `PROCESS_UNKNOWN` | 先对账 / `recover --confirm-stop`，禁止二次派发 | 已实现 |
| implement 越界 | `SCOPE_VIOLATION` + `_incident_basis` | spec 自己要求该路径 → 豁免实现次数；否则按策略修复 | 保留现状，先观测占比 |

### 4.1 监控口径

| 通道 | 语义 | 边界 |
|---|---|---|
| `watch --follow` | 过滤生效并前置校验归属（不符即 `PROJECT_MISMATCH`）；无事件不输出 | **Runtime 内部仍以 0.05–0.5s 间隔查询事件表**（`cli.py:1011`）；`--timeout` 默认 20s 到期退出，宿主凭游标重启 |
| `task events --follow` | 同上（`cli.py:381-388`） | 同上 |
| `task logs --follow` | 游标 `run:generation:offset`，`--projection` 三档（`cli.py:394-422`） | `--timeout` 默认 60s；无新增不输出 |
| `progress.json` | 10s / 8KB 双阈值；`observed_at` / `last_output_at` / `quiet_seconds` / `process_state` | 不写事件表；阈值走宿主 env，不进项目配置 |

准确表述：宿主侧从"每 5 分钟主动查一次"变成"持续 follow + 游标续读"，**Runtime 内部仍是短轮询**；感知延迟在指定测试条件下目标 ≤1s，不作为任意负载下的硬保证。事件密度不由本方案改变。

---

## 5. 明确不做

1. `quick` 参数或独立的小任务编排系统。
2. runtime 侧解析"一句话需求"。
3. 按"时长 / 行数 / 是否盯着"路由。
4. `prepare` 的 `changes[]`（无基线不定义"变化"）。
5. 首期开放通用空 checks（见 B9-c）。
6. `project init` 交互向导。
7. `policy_revision` 分区。
8. 批量 `task rebind --all`。
9. `allowed_paths` 与仓库结构的硬闸（提示级）。
10. 准备结果入库、向量记忆、推荐算法、插件框架、skill 侧第二套预检。

---

## 6. 实施顺序（按依赖重排，采纳评审顺序）

| 序 | 工作 | 归属 | 估时 | 说明 |
|---|---|---|---|---|
| 1 | **B0** `task_scope` 语义 + 保护路径差集 + Windows/符号链接 + 仓库边界 | `_contracts.py` / `_backend.py` / `_config.py` | 3 | 先解决"声明与执行不一致"，含旧任务兼容 |
| 2 | B1 诊断聚合（含 `skipped`）+ B2 `register --dry-run` + B3 契约对齐 | `_config.py` / `_util.py` / `cli.py` | 2 | 静态预检已实现，只做对齐 |
| 3 | B7 `task prepare`（只读）+ create/start 复用同一校验 | `cli.py` | 2 | 避免预览与执行分叉 |
| 4 | B8 模板与占位符 + `--emit` 草稿与 `request_id` 幂等 | skill + `cli.py` | 1.5 | 真正降低填写成本 |
| 5 | B9 轻量入口 + B10 profile 校验 + 简洁结果模板 | skill + `cli.py` | 1.5 | 体验层 |
| 后续 | B4 `project diff`、B3 执行复校、基线检查、纯人工交付契约 | — | — | 不阻塞首批价值 |

合计约 **10 人日**（含 B0 的跨平台验证与旧任务兼容）。v4 的 7 人日不含路径语义修复，**不作为交付承诺**。

---

## 7. 回放验收

### 7.1 五项指标（修正 v4 的误导）

| # | 指标 | 通过标准 |
|---|---|---|
| 1 | 首次准备即可启动 | **固定夹具**（配置、仓库、环境不变）下，`prepare` 通过后 create+start **不再出现该预检已覆盖的配置错误**；不承诺"任何配置错误都没有" |
| 2 | 人工输入次数 | 限定场景：README 包名修正 ≤3 次（一句话 / 确认范围 / 确认结果）；不作为通用承诺 |
| 3 | 配置类阻塞 | 只统计可归因于配置的：`POLICY_CHANGED`、`PERMISSION_PROFILE_UNBOUND`、`INPUT_INCOMPLETE`、以及 `_incident_basis` 判为 `policy-too-narrow` 的 `SCOPE_VIOLATION`。**不计入**：真实越界的 `SCOPE_VIOLATION`（那是 Agent 行为）、`126/127`（进程退出码，脚本内部也可能返回） |
| 4 | 因配置问题导致的**额外**启动次数 | 正常启动本身会增加 `attempts`；只统计"因配置错误而重跑 Agent"的次数，目标 0 |
| 5 | 授权边界 | 回放产物全部落在 `allowed − protected` 内；Windows 路径反例（见 B0-c 五例）全部通过 |

### 7.2 场景

- 正例：README 包名修正、局部 bug 修复、新增小脚本（各跑 macOS 与 Windows）。
- **反例**：一行鉴权修改——不得走轻量路径，判据是维度（高风险、验证不易）不是行数。
- 平台反例：`src\a`、`src/../src/a`、`src/a` vs `src/abc`、符号链接外指、大小写差异。

### 7.3 负向判据

- 准备阶段失败不产生 task 记录、不消耗 `attempts`（断言 `$ZOE_HOME/tasks/` 无新增目录）。
- `task_scope` 显式空 → create 期拒绝，不回退项目范围。
- 未替换的 `<FILL:` → 逐位置拒绝。

---

## 8. 落地状态（v8）

### 8.1 已完成

| 项 | 状态 | 实现位置 | 测试 |
|---|---|---|---|
| B0 路径语义 | 已实现，Windows 未实机验证 | 新增 `src/_paths.py`（`normalize` / `is_within` / `covers` / `same_path` / `subtract` / `declared_under` / `git_toplevel`）；`_contracts._prefix_covered` 委托；`_backend.scope` 与 `_config.path_warnings` 统一使用 | `tests/test_config_friction_v5.py::PathSemantics`（4 项） |
| B0-a `task_scope` | 已实现（选项 B） | `_pipeline._resolve_task_scope` 在 `create` 与 `revise` 时冻结；`scope()` 用 `is not None` 判定，**禁止 `or` 回退** | `TaskScope`（6 项） |
| B0-b 保护路径 | 已实现（差集语义） | 显式声明保护路径 → `POLICY_DENIED`；声明其祖先只提示不阻断；`protected_paths` 仍从 `config` 现读 | 同上 |
| B1 诊断聚合 | 已实现 | `_config.Diagnostics`；`details.errors[]` + `details.skipped[]`；顶层 `code`/`message` 仍是第一个错误；结构门仍立即抛 | `AggregatedDiagnostics`（3 项） |
| B2 `register --dry-run` | 已实现 | `cli._register_dry_run`，分支在 `Store(...)` 之前；`warnings` 来自 `_config.path_warnings` | `RegisterDryRun`（2 项） |
| B5 路径警告 | 已实现（提示级） | `_config.path_warnings`：不存在 / 无 git 跟踪文件 / 覆盖全仓 | 同上 |
| B7 `task prepare` | 已实现 | 新增 `src/_prepare.py`；预检 / `--out` / `--emit` 三操作分开；`--repo` 匹配；未注册给草案 | `Prepare`（9 项） |
| B7.4 快照语义 | 已实现 | `prepared` + `snapshot{policy_hash, base_sha, checks_preflight, static_checks_done, static_checks_skipped}`；无 `changes[]` | 同上 |
| B8 模板与占位符 | 已实现 | `references/spec.example.json`、`references/create-request.example.json`（进 `build.py` 的 `REQUIRED_FILES`）；`_contracts.reject_placeholders` 覆盖 spec 与 create request | `Placeholders`（2 项）+ `build.py --check` |
| B10 profile 衔接 | 已实现（只读展示） | `_prepare._profile_block`：`selected` / `authorized` / `model` / `model_source` / `conflicts`；不调用模型 | `Prepare`（1 项） |
| B4 `project diff` | 已实现（第二批） | 新增 `src/_diff.py`：字段级差异（`checks` / `agent_profiles` 按 id 配对）+ `policy_hash`（完整，即 `rebind.target_policy_hash`）与 `policy_revision`（16 位）+ `affected_tasks` + `suggested_commands`；`spec_valid_under_new_policy` 读同一份 `spec-<rev>.json` 快照并调 `rebind` 的 `validate_spec_text`，快照缺失时为 `null` 而不是猜测 | `tests/test_config_friction_v5_diff.py`（13 项） |
| B3 执行时复校 | **已实现（既有，早于本方案）** | `_run_checks` 里 `resolve_check` 拦 `unresolved` → 该 check `FAIL` + `error_class: environment`（不消耗修复预算），`shell` / `deferred` 放行 | 既有测试；本方案仅补文档。形式与 v5 建议（发事件不阻断）不同，但更强且已用 `error_class` 与 `environment_drift` 区分 |
| 文档同步 | 已实现 | `SKILL.md`（四判据分流 + prepare 步骤 + `ready` 子项分诊）、`cli-contract.md`（prepare / dry-run / `details.errors`）、`runtime-contract.md`（接入五步 + `ready` 两个故障面）、`architecture.md`（模块地图加 `_paths.py`） | `tests/contract/test_skill_cli_contract.py`、`tests/test_contract_artifacts.py`、`build.py --check` |

验证结果（本机 macOS）：

- `tests/test_config_friction_v5.py`：36 项通过（7 项路径语义 + 3 项"非相对路径条目"拒绝）；
- `tests/test_config_friction_v5_diff.py`：14 项通过（含"预览与 rebind 同源校验"、"快照缺失不给命令"、"报告只读"）；
- 全量：`870 passed / 6 skipped / 0 failed`（本机 macOS，2026-10-30 快照，含 review 修复）。

新增模块 `_paths.py` 与 `_prepare.py` 各自只做一件事，且都不引入第三方依赖。

### 8.2 实现与设计的差异（已回写正文）

1. **`--repo` 匹配用 git 仓库根相等**，不是"PATH 是项目 repo 的子目录"。子目录的 git root 本来就等于项目仓库，两者在该场景下等价；用根相等还能自动排除嵌套仓库，不需要额外规则。
2. **`git_toplevel` 用向上查找 `.git`**，不 shell out 调 `git`：`prepare` 要在任何运行时状态存在之前回答这个问题，也不该让答案取决于宿主是否装了 git。
3. **`create` 的占位符检查放在 `authorize` 之前**：否则 `--emit` 的草稿会先报"授权不匹配"，把真正该填的字段掩盖掉。
4. **`prepare` 完全不构造 `Store`**（连读都走 `projects/*.json`），因此 `--repo` 模式对一个不存在的 `$ZOE_HOME` 运行后目录仍不存在。

### 8.3 行为变更（需在发布说明中写明）

- **显式 `"allowed_paths": []` 从"通过"变为 `POLICY_DENIED`**。省略该 key 仍沿用项目范围；只有显式写空数组的 spec 受影响，而那种 spec 本来也交付不了任何改动。
- **`spec.allowed_paths` 现在真的生效**（此前只做"不得放宽"的校验，运行期按项目范围放行）。已有任务因为 `task_scope` 缺失而保持旧行为；新任务按声明收窄。
- **配置错误可能一次返回多条**。只读 `error.code` 的宿主不受影响（顶层仍是第一个错误）；按数组长度分支的宿主需要知道现在可能 >1，但只发生在 `details` 里。

### 8.4 未做（第二批）

| 项 | 原因 |
|---|---|
| Windows 实机验证 | `_paths` 已按 `normcase` / `samefile` 实现，且补了 7 项单测（分隔符归一、`..` 折叠、组件边界、符号链接、`git` 文件边界、空 parent、`describe_missing`），但 B0-c 的五例**只在 macOS 跑过**；Windows 上的大小写与 `PATHEXT` 行为需要实机确认 |
| 基线检查（记录已有失败） | 要真的有副作用地执行，且需先定义"基线红"与"本次退化"的区分口径，否则基线一旦红就永久阻断 |

第二批其余项已完成：`project diff`（B4）、执行时复校（既有实现）、轻量结果模板（`report-template.md` 新增一节）。

### 8.5 复查发现与修复（v8）

**结论：设计功能已实现，但复查抓到一个真实的权限放宽入口，必须修完才能宣称"研发完成"。**

| # | 发现 | 严重度 | 处理 |
|---|---|---|---|
| 1 | 项目 `allowed_paths` 只校验"非空列表"，`"."` 能通过注册；随后 spec 写 `["."]` 被 `covers` 判为"未放宽"而放行 → 任务实际获得整仓写权限 | **P0 权限放宽** | 已修：注册与 spec 双侧都拒绝 `""` / `"."` / 绝对路径 |
| 2 | `_paths.is_within` 把空/`"."` 父级当作"任意位置" | **P0（同上根因）** | 已修：返回 `False`；需要"未设置"的调用方显式表达 |
| 3 | `project diff` 快照缺失时给 `null`，却仍产出 `task rebind` 命令，而真 `rebind` 会因读不到文件失败 | **P0 假信息** | 已修：`False` + 明确 note，且不产出命令 |
| 4 | `prepare` 未注册时回显 `spec.valid=true` / `scope_source="spec"`，读者会当成"范围已确认" | P1 误导 | 已修：`scope_source="unregistered"` + `SCOPE_UNVERIFIED` 诊断 |
| 5 | `snapshot.spec_hash` 读文件字节，冻结快照是包裹格式，与 `create` 的文本 digest 不同源 | P1 | 已修：统一取 spec 文本 digest |
| 6 | `_flatten` 假设 `checks`/`agent_profiles` 元素是 dict（手改过的旧配置会崩） | P1 | 已修：逐项判型后按值比较 |
| 7 | `getattr(exc, "hint")` 恒为 `None`（`Error` 只把 hint 放进 `to_dict()`） | P1 | 已修：`exc.to_dict().get("hint")` |
| 8 | `profile.authorized` 在 `authorized_actions` 为空时给 `None`，而 `authorize()` 的语义是"全拒" | P1 | 已修：恒为布尔，另加 `actions_declared` |
| 9 | `--project ../escape` 能读到 `$ZOE_HOME` 之外的 JSON | P1 安全 | 已修：`safe_id`；磁盘里的 `project_id` 同样过滤 |
| 10 | `subtract` 是列表级减：`["src"] − ["src/security"] = ["src"]`，报告里会让人以为保护子目录可写 | P2 | **未改**：运行期 deny-first 已正确，`task_scope` 与报告字段名保留（改动会污染已冻结任务）；注释已写明 |
| 11 | `spec_scope` 静默丢弃空白条目 | P2 | 已修：仅用于已校验文档，加注释 + 保序去重 |
| 12 | 归一化后出现重复条目（`["src","src"]`） | P2 | 已修：保序去重 |
| 13 | `scope()` 的 `details.allowed_paths` 回显未归一化条目 | P2 | 已修：输出归一化形式 |
| 14 | `_worktree.quarantine` 仍读项目范围，`task_scope` 收窄后清理范围与判定分叉 | P2 语义分叉 | 已修：跟随 `task_scope`（与 `scope()` 同一表达式） |
| 15 | `--template standard` 与 `minimal` 的唯一差异是多一条必填占位符 | P2 | 已修：删除该模板与参数，只留一份最小模板 |
| 16 | `prepare` 与 `_pipeline._resolve_task_scope` 各写一遍"范围是否全被保护覆盖" | P2 | **未改**：会引入 `_prepare → _pipeline` 依赖（后者很重）；列为已知分叉点，改两边必须同步 |
| 17 | `_paths.describe_missing` 零引用 | P3 死代码 | 已修：接入 `path_warnings`，产出 `SCOPE_INVALID` |
| 18 | `_groups` 调 `_contracts._prefix_covered` 私有名 | P3 | 已修：转为公开 `prefix_covered`，保留别名 |
| 19 | `Diagnostics.skip()` 只在失败响应里可见 | P3 | **保持**：`skipped` 的语义就是"这次没判、别当通过"，成功路径不需要它 |

## 9. 附：关键锚点

> 行号基于 v5 设计快照。v6 落地后 `cli.py` / `_config.py` / `_pipeline.py` 均有偏移，
> **以符号名为准**；`_paths.py`、`_prepare.py` 为新增模块。

```text
zoe-runtime/src/cli.py:1348             无项目 doctor 分支先于 Store（dry-run/prepare 同位置）
zoe-runtime/src/cli.py:1356             Store(args.home) 构造即建 state.db
zoe-runtime/src/cli.py:1358-1370        project register 现状（read → validate → atomic）
zoe-runtime/src/cli.py:296-318          watch 参数（--project/--follow/--timeout=20）
zoe-runtime/src/cli.py:381-422          task events/logs --follow
zoe-runtime/src/cli.py:579-590          capabilities.observation
zoe-runtime/src/cli.py:876-916          事件过滤与归属校验（PROJECT_MISMATCH）
zoe-runtime/src/cli.py:984-1011         _watch_follow：内部短轮询，非 push
zoe-runtime/src/_config.py:122-131      checks_preflight（静态预检已实现）
zoe-runtime/src/_config.py:193-278      validate_config：串行 require 全在此区间
zoe-runtime/src/_config.py:255-263      checks 仅验 argv 形态
zoe-runtime/src/_config.py:313-320      预检接入：只 unresolved 让 checks_preflight_ok=false
zoe-runtime/src/_config.py:347-353      ready 已含 checks_preflight_ok
zoe-runtime/src/_config.py:393-395      顶层重复暴露 checks_preflight
zoe-runtime/src/_backend.py:251-266     _build_env：PATH 继承，预检复用
zoe-runtime/src/_backend.py:607-639     scope()：拒绝优先，一次报全部越界
zoe-runtime/src/_contracts.py:28-29     _prefix_covered：按路径组成部分比较（不得回退成裸 startswith）
zoe-runtime/src/_contracts.py:55-60     verification_scope.checks 必须非空
zoe-runtime/src/_contracts.py:116-200   validate_spec_text：widening 已校验，保护路径语义未校验
zoe-runtime/src/_contracts.py:203-243   load_spec：只验证，不改写 config
zoe-runtime/src/_pipeline.py:304-446    create：冻结 "config": c，attempts 初始 0
zoe-runtime/src/_pipeline.py:327        仅配 routing 或带 route 才走 plan_route（纯规则）
zoe-runtime/src/_pipeline.py:992-1011   _start_locked：用 _profiles.policy_digest 复核策略
zoe-runtime/src/_pipeline.py:1851       rebind：逐任务 + spec 必须在新策略下合法
zoe-runtime/src/_pipeline.py:199-204    _incident_basis：SCOPE_VIOLATION 豁免归因
zoe-runtime/src/_pipeline.py:2320       attempts 在真正启动 agent 前 +1（正常启动也增）
zoe-runtime/src/_pipeline.py:2491-2505  environment_drift：agent CLI 相邻 run 漂移（非 check 复校）
zoe-runtime/src/_progress.py:1-60        progress.json：10s/8KB 双阈值，阈值走宿主 env
zoe-runtime/src/_logstream.py            日志增量流（游标 run:gen:offset）
zoe-runtime/src/_profiles.py:148-159    policy_digest：normalize 后的全量摘要
zoe-runtime/src/_store.py:178-179       tasks()：影响面枚举来源
zoe-runtime/src/_store.py:252-265       _operation_key：request_id 即幂等主键
zoe-runtime/src/_util.py:149-157        read() 支持 stdin（--config - 已可用）
zoe-workflows/build.py:31-38            WHITELIST 不含 docs/（本文不进发布包）
```
