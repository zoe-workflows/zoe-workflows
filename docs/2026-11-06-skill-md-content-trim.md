# SKILL.md 内容精简：不删判据的第二刀

| 项 | 内容 |
|---|---|
| 日期 | 2026-11-06 |
| 输入 | 使用 `skill-creator` 准则评估「`SKILL.md` 还能不能精简，但核心执行流程不能被削掉」；用户选定**保守档** |
| 被评估对象 | `zoe-workflows`（`SKILL.md` 880 行 / 38,971 字符，上一轮渐进披露后的状态） |
| 方法 | 分块字符量实测 → 按「每次必经 vs 特定分支」分类 → 只做不丢判据的三类改动（删重复 / 下移 / 压措辞）→ 改后跑 `--check`、`--pack`、跨仓 contract 测试，并对 19 个关键术语做归属自检 |
| 结论 | 可再精简约 11%：**删的是重复与场景错位，不是判据**；到不了 skill-creator 的「< 500 行」建议值，因为剩下的几乎全是判据 |
| 本文位置 | `zoe-workflows/docs/`（不进发布包） |

## 0. 一句话

`skill-creator` 的「SKILL.md < 500 行」是**默认值，不是配额**。本 skill 是编排协议，
每条判据都对应一次真实误判（`docs/` 里有记录），所以正确的目标是**"每条规则都在它该在的层"**，
而不是行数。按这个标准审计，真正可删的是重复表述与"配置/标定场景才用"的规则，共约 4,400 字符。

## 1. 判定

| 档 | 内容 | 裁定 |
|---|---|---|
| 纯冗余（同一件事说两遍 / 已在 reference 里） | 预检机制细节、attest 四行分支表、`reason` 四行表、组交付串行三遍、`route` 字段清单、两处 `doctor` 边界 | **删/压** |
| 场景错位（只在特定分支才用） | 模型身份 12 条纪律、共享路径计数与 TOCTOU | **下移** |
| 措辞 | 长句拆短、去掉"这正是/否则"类连接词 | **压** |
| 核心执行流程 | 9 步顺序与判据、错误码与处置、铁律 8 条、每次输出字段 | **不动** |
| 追 500 行 | 需再削 200 行 = 动第 3/4 步的 Spec 与并行判据 | **不采纳** |

## 2. 实测

| 度量 | 改前 | 改后 |
|---|---|---|
| `SKILL.md` | 38,970 字符 / 880 行 | **34,536 字符 / 781 行**（-11.4% / -99 行） |
| `references/model-identity.md` | — | 新增 6,575 字节 |
| `references/decomposition-patterns.md` | 5,499 字符 | 6,291 字符（承接共享路径计数） |
| `build.py` 的 `SIZE_BUDGET` | 46,000 | **38,000**（锁住本轮成果） |
| `references/cli-contract.md` | 788 行，无目录 | 795 行，加目录 |
| `references/runtime-contract.md` | 355 行，无目录 | 360 行，加目录 |

## 3. 改动

### 3.1 下移（场景错位，最大收益）

| 内容 | 原位置 | 落点 | SKILL.md 留了什么 |
|---|---|---|---|
| 模型身份三层、`model_aliases` 登记、`cost_class`/`pin_model`、probe 的代价、`MODEL_MISMATCH` 取证、别名登记表 | 「执行配置与模型授权」纪律 12 条（3,420 字符） | **新增** `model-identity.md`（4 节） | 5 条铁律级：不降档 / 不静默切换 / 不自行改授权 / 别名要有依据 / 改配置先 diff + 2 条短句 |
| 共享路径计数（jq 命令 + 触及数分档）、TOCTOU 两个限制、`shared_resources` 不排队 | 第 4 步（769 字符） | `decomposition-patterns.md` 的「共享路径计数」 | 3 行结论：≥3 个候选触同一路径按共享集成点处理 |

下移的两处都遵守同一条规则：**落点留一行结论 + 触发条件 + 链接**。只留链接等于删除，
这是本仓库记录过的失效模式。

### 3.2 删重复

| 位置 | 为什么是重复 |
|---|---|
| `能力与边界` 预检段 | 错误码与机制在 README、`runtime-contract.md` 各有一份 |
| `attest` 的四行分支表 | 信息压成一句"逐字一致才继续，否则一律视为未确认" |
| `ALLOWLIST_UNCONFIRMED` 的 `reason` 四行表 | 压成一行四分支，判据一条不减 |
| 组交付「组内串行是能力声明」 | 本节开头已用 `group_serial_execution` 说过一次 |
| `route` 的五个字段名 | 字段清单在 `create-request.routed.example.json` |
| 「必须写明的边界」四句 | 压成三句，保留"不证明用户读懂""不防伪造""不得声称原子" |
| `checks_preflight` / 额度耗尽 / 合并门禁 | 措辞压缩，判据与错误码全留 |

### 3.3 配套

- `cli-contract.md`（788 行）与 `runtime-contract.md`（355 行）加目录——`skill-creator` 要求
  >300 行的 reference 有 TOC。目录是普通列表，不触碰 ```text 契约块，contract 测试不受影响。
- `SIZE_BUDGET` 46,000 → 38,000：精简成果必须由闸门锁住，否则下一次加功能又会漂回去。

## 4. 不采纳

| 方案 | 裁定 | 依据 |
|---|---|---|
| 压到 500 行 | **不采纳** | 需再削 200 行，只能动第 3 步（Markdown spec 无 `allowed_paths` ⇒ 全仓可写）与第 4 步（4 路 3-way 合并）的判据，等于回退 v1.3 缺陷 |
| 把 `## 每次输出` / `## 保持边界` 下移 | **不采纳** | 每次回答都要用；下移会让"可信度标注"消失 |
| 把 `request_id` 复用、`resume` 两段式、三步诊断也下移 | **本批不做** | 各只值 400–600 字符，跳转代价高于收益（保守档只取前两项） |
| 再新建更多 reference | **不采纳** | 只新增 1 份；其余全部并入既有文件，避免碎片化 |

## 5. 验收

| 检查 | 结果 |
|---|---|
| `python3 build.py --check` | exit 0（35 个必需文件、链接、预算、可执行位全过） |
| `python3 build.py --pack` | 通过 |
| `ZOE_SKILL_DIR=… pytest tests/contract/test_skill_cli_contract.py` | 8 passed（含 `cli-contract` 的 ```text 块解析） |
| 19 个关键术语归属自检（`MODEL_MISMATCH` / `OVERLAP_WARNING` / `ATTEST_PRECONDITION_FAILED` / `quota_gate` …） | 全部有归属，**0 个 MISSING** |
| 结构闸门 | 第 6 步 8 个小节、7,260 字符，仍在预算内 |

## 6. 判错条件

- 出现某个错误码或处置只在 SKILL.md 被删、reference 里也没有（术语自检出现 MISSING）；
- 下移处只剩链接、没有一行结论 + 触发条件；
- `SKILL.md` 超过 38,000 字符；
- 第 6 步小节数 < 2 或任一小节 > 2,500 字符；
- 出现「`premium` 可以登记成 `standard`」「看到上报名不同就补别名」「`resume` 可以试额度」这类表述。

## 7. 附：同日 review 的修复

精简后对两个仓库做了一轮 review（`zoe-workflows` + `zoe-runtime`），发现并修了四处：

| 问题 | 证据 | 修复 |
|---|---|---|
| `scripts/zoe-revise-scope.sh` 已实现（v1.6，解决 `SCOPE_VIOLATION` 后"cancel 重派把工作区当废料"），但**技能文档、README、`REQUIRED_FILES` 三处都没有它** | `grep -rn revise-scope` 在 `*.md` / `*.py` 里零命中 | `REQUIRED_FILES` 登记 + SKILL.md 第 8 步给两段式入口与退出码 + README scripts 说明 |
| `build.py` 的可执行位检查漏了 `zoe-watchd.sh` 与 `zoe-revise-scope.sh` | `check()` 的 `for wrapper in (...)` 只有 6 项，目录里有 8 个可执行 `.sh` | 两个都加进检查表 |
| `zoe-runtime/docs/architecture.md` 的 module map 里 `src/_diff.py` 出现两次（两行不同描述） | 第 70 行与第 80 行 | 合并为一条完整职责描述 |
| 本文与渐进披露文档的字符/行数与实测差 1–17 | `splitlines()` vs 中间态统计 | 统一为 `splitlines()` 口径 |

`zoe-runtime` 侧 `pytest tests`（除 integration）基线：**1,131 passed / 6 skipped**，唯一失败是
`architecture.md` 的 module map 缺 `src/_baseline.py`，核对时该条目已在文件中，单独复跑通过
（怀疑是两次读取之间文件被外部改动，未改动源码）。
