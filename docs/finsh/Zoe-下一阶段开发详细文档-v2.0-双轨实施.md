# Zoe 下一阶段开发详细文档（v2.0 · 双轨实施）

- 文档版本：2.0
- 日期：2026-11-06
- 上游文档：`Zoe-下一阶段详细设计与开发计划-v1.0.md`（以下简称 v1.0）
- 适用仓库：`zoe-runtime`、`zoe-workflows`
- 状态：实施文档；本版已完成源码级落点核验（与 v1.0 的"接口均为提案"不同，本文标注的现有文件/函数均已核对），未标注"待核实"的落点以当前工作区代码为准
- 执行基线：以 T0（A0）产出的两仓 SHA 冻结为准，本文不预填 SHA

---

## 0. 与 v1.0 的采纳关系

本文是 v1.0 的执行版，采纳其约 80%，按"轨 A（立即）/ 轨 B（条件）"双轨重组。差异如下：

| v1.0 内容 | 本文处置 | 原因 |
|---|---|---|
| T0 基线核查、T1 发行组合 | **采纳为轨 A 前两项**（A0/A1），并追加"首屏保证表述修正" | 上轮评审 P0 项，独立于新特性 |
| §8 敏感路径变更视图 | **采纳并从 T5 解耦**为轨 A 独立任务（A2） | 复用 `scope()`/`protected_paths` 既有机制即可落地，不依赖子 Agent |
| 真实资格与故障演练（T6 部分） | **拆出为轨 A 任务（A3/A4）**，并明确交付物含 `docs/compatibility/` 升级记录 | 能力升级通道是本项目 `VERIFIED` 的唯一依据，v1.0 只写"演练"不写升级，遗漏交付物 |
| §10 对照实验设计与指标 | **采纳为轨 A 任务（A5）**，样本分两步（先 3–5 对校准，后扩 5–10 对） | 测量协议错误是试点最常见废因，先用小样本校准口径 |
| T2 原生能力探针 | **采纳为轨 B 唯一入口（B1）**，补量化判定标准与 kill-switch 验收 | 可行性闸门必须可执行，不能是软约束 |
| T3/T4/T5 委派特性实现 | **采纳为轨 B（B2–B4）**，T4 增加退化路径设计 | 事件观察是最大不确定块，先探针后实现 |
| T7 试点、T8 发布 | 采纳为 B6 / B7 | — |
| `native_readonly_delegation_v1` 进技能全包 `required_capabilities` | **不采纳**，按 v1.0 §5.3 自己的替代方案（入口条件要求 + 新旧配套包） | 全包门槛会复现"1.6.0 挡住所有已发布运行器"的问题 |
| §9 "共享 ref、固定端口和测试库分别按现有项目配置串行化" | **改写**：现有机制仅 `max_active_tasks` 全局串行化，无按资源类型规则；试点以单顶层任务回避，资源级规则留待 §14 条件满足后设计 | 不能把不存在的能力写成已有 |
| 15–25 人日总量估算 | 改为轨 A 5–8 人日 + 轨 B 8–15 人日（B1 后重估） | 捆绑估算掩盖了轨 A 可独立交付的事实 |

---

## 1. 总体路线

```
轨 A（立即，5–8 人日）                     轨 B（条件启动，8–15 人日，B1 后重估）
─────────────────────────                ─────────────────────────────────────
A0 基线核查（1–2d）                       B1 原生能力探针（2–3d）──失败──▶ 关闭轨 B，
A1 发行组合修复 + 保证表述（1–2d）                │                        交付"不支持"结论
A2 敏感路径变更视图（2–3d）                      │ 通过
A3 主力组合真实 E2E + VERIFIED（1–2d）    B2 策略编译与授权（2–3d）
A4 断连/故障演练（1d，纯执行）            B3 观察与收敛（3–5d，含退化路径）
A5 测量协议校准试点（1d）                 B4 报告增量（1d）
        │                                B5 资格扩展与故障演练（2d）
        ▼                                B6 对照试点 5–10 对（2–3d）
【里程碑 M1：一条已验证交付路径】          B7 发布与交接（1–2d）
                                                  ▼
                                        【里程碑 M2：只读委派 + 价值证据】
```

- 轨 A 各任务相互独立（A0 除外），可并行分派；A1/A2/A3 可并行。
- 轨 B 全部以 B1 通过为前置；A3 是 B1 的前置（探针要在已验证的执行链上做才有意义）。
- 轨 A 完成即构成上一阶段评审定义的 P0 主线（"一条已验证交付路径"），**不依赖轨 B 存在**。

---

## 2. 轨 A：可靠交付验证（立即执行）

### A0 基线核查

**目标**：冻结实施基线，把本文所有"待核实"项变为事实。

**核查项**（产出绑定两仓 SHA 的核查记录，放 `zoe-workflows/docs/`，每项标"已确认 / 需改动 / 不支持"）：

| # | 核查项 | 已知事实（本次核验） | 待核实 |
|---|---|---|---|
| 1 | 两仓 SHA 与未提交改动 | — | 精确 SHA、工作区干净度 |
| 2 | 已发布版本 | `CHANGELOG.md` 标 1.6.0 / 1.5.3 均 unreleased，README 称 v1.5.0 | PyPI 上实际最新版本号 |
| 3 | adapter backend 标签 | `claude_code.py` 的 `default_backend = "anthropic-api"`，而 README 称后端仅 `local-process` | `anthropic-api` 与 `local-process` 的确切关系与注册表语义 |
| 4 | 契约测试入口 | `tests/contract/` 需要 `ZOE_SKILL_DIR` 指向技能仓 | 本机跑通的完整命令行 |
| 5 | qualification fixture | `docs/compatibility/README.md` 给出 `zoe qualification run --fixture tests/qualification/basic` | 该 fixture 在当前树中存在且可运行 |
| 6 | Claude Code CLI 实际版本与 `--agents` 支持 | `adapter-qualification.md` Q1–Q4 记录为 yes | 目标机器安装版本的 `--help` 实测输出 |

**估算**：1–2 人日。**不通过任何一项时**：记录事实后再决定对应任务的处理，不冻结基线不开发。

### A1 发行组合修复 + 首屏保证表述修正

**目标**：新用户按说明安装后能直接运行（AC-DA-01/02）；README 首屏保证与 threat-model 一致。

**1. 版本组合（二选一，推荐方案一）**

- **方案一（推荐）：发布 zoe-runtime 1.6.0**。理由：`required_capabilities` 中的 `task_digest` / `task_list_fields` / `base_drift_preflight` 与 `quota_gate` 已在代码中实现（`CHANGELOG` [1.6.0] 节），技能侧 `zoe-digest.sh --since` 已依赖；发布比降级技能包改动小。
  - 按 `docs/releasing.md` 的 TestPyPI → PyPI 流程执行；
  - 发布前跑 `python3 build.py --check`（技能仓）与 runtime 全量测试 + 契约测试；
  - 1.6.0 的 unreleased 条目定稿（目前混有 1.5.3 未发布项，需理清两个版本各自的内容）。
- **方案二：技能包降级**。`runtime-requirements.json` 的 `min_version` 回到已发布版本、`required_capabilities` 移除 1.6 能力名，同时 `zoe-digest.sh` 降级为可选。仅当方案一被发布流程阻塞时采用。

**无论哪个方案**：修正 `zoe-workflows/README.md` 第 5 行（`≥ 1.5.2`）与第 97 行（`min_version 1.6.0`）的自相矛盾，以 `runtime-requirements.json` 为唯一事实来源复述。

**2. 首屏保证三分法（纯文案，直接复用 threat-model 现成措辞）**

修改 `zoe-runtime/README.zh-CN.md`（及英文版）"安全保证"节首屏表格：

| 保证类型 | 可主张的内容 |
|---|---|
| 流程保证 | 正常发布路径必经 publisher（Agent 不经控制器无法产生发布记录） |
| 审计保证 | 越界写、指纹变化、`allowed_paths` 违规事后检测并阻断交付 |
| 权限保证 | **当前不具备**：无容器/OS 隔离，Agent 持有本机凭据（详见 threat-model open risks） |

同步把"独立验证"拆为三层表述：执行独立（已实现）/ 基准独立（检查配置冻结已实现，检查文件**内容**变更检测由 A2 补齐）/ 需求覆盖（`_task_review.py` + `_coverage.py` 已有，依赖 Spec 写清 AC）。

**验收**：AC-DA-01（干净环境安装相容组合并跑通最小任务）、AC-DA-02（旧配置/旧任务回归不破坏）。
**估算**：1–2 人日。

### A2 敏感路径变更视图

**目标**：候选 diff 触及验证敏感文件时，在证据与交付报告中**单列可见**——提醒而非禁止（合法测试修改照常通过），闭合"Agent 改测试/检查脚本内容、重跑检查仍绿"的唯一验证空白。

**现状（已核验）**：
- `src/_backend.py` `scope(t)` 已做 `git diff --name-only <base_sha>` + 未跟踪文件枚举，并有 `protected_paths`（默认 `[".env", ".github"]`）；
- `src/_evidence.py` `build()` 产出的证据已绑 `spec_hash` / `candidate_sha` / `check_policy_hash` / `selected_check_ids` / `not_run_check_ids` / `verification_semantics`，docstring 明确增量字段保持新旧证据可比；
- `src/_reports.py` 生成 `delivery-<rev>.md`。

**设计**：

1. 新模块 `src/_sensitive.py`，单一函数：

```python
def classify_sensitive(w: Path, base_sha: str, config: dict) -> list[dict]:
    """返回 [{path, category, note}]；category ∈
    check_entry | test_code | fixture | ci_config | agent_config | protected | build_dep
    """
```

分类规则（保守匹配，不做 shell 语义分析）：

| category | 匹配来源 |
|---|---|
| `check_entry` | 项目 `checks[].argv` 中出现的脚本/配置路径（含其所在目录） |
| `test_code` | 项目声明的测试目录与命名约定（`tests/`、`test_*`、`*_test.*`；允许项目配置覆盖） |
| `fixture` | 测试目录内的夹具/数据文件 |
| `ci_config` | `.github/workflows/**`、`.gitlab-ci.yml` 等声明式清单 |
| `agent_config` | `.claude/**`、agent 定义、权限配置文件 |
| `protected` | `protected_paths` 命中（沿用现有语义，越界即拒绝，与提醒类区分） |
| `build_dep` | checks 依赖的构建/依赖清单（`pyproject.toml`、`package.json` 等，项目可声明） |

2. 调用点：verify 阶段候选固定后、checks 执行前调用一次，结果以**增量字段** `sensitive_changes` 附入证据 dict（不做 schema 破坏性变更；`tests/contract/` 增加字段契约测试，旧解析器不拒新字段——若拒，按 v1.0 §7.3 提契约版本，不假装零迁移）。
3. 项目配置新增可选键 `sensitive_globs`（追加自定义敏感路径），进入 `policy_digest`（改它触发既有 `POLICY_CHANGED` 语义，复用不新造）。
4. `task report` / `delivery-<rev>.md` 增加紧凑段落（沿用 v1.0 §8.2 格式）：敏感变更计数 + 分类明细 + "验收时请核对断言与覆盖变化"提示。**不阻断**原有业务检查，除非命中 `protected`（走既有 `SCOPE_VIOLATION`）。

**改动文件**：`src/_sensitive.py`（新）、`src/_backend.py`（复用其 diff 枚举或抽公共函数，避免二次实现）、`src/_evidence.py`、`src/_reports.py`、`schemas/`（如证据有 schema）、`zoe-runtime/tests/test_sensitive_paths.py`（新）、技能仓 `references/cli-contract.md`（新字段）。
**验收**：AC-DA-09（测试/夹具/CI 变更被正确分类；合法测试修改不被禁止）、AC-DA-08（验证后文件变化仍按既有 `WORKSPACE_CHANGED` 失效，回归确认）。
**估算**：2–3 人日。

### A3 主力组合真实 E2E 与 `VERIFIED` 升级

**目标**：把一个 `(adapter, backend, version)` 组合从 `NOT_RUN` 推到 `VERIFIED`，使后续所有记录摘掉 `unverified` 标签。

**主力组合选择**：macOS × `claude-code`（轨 B 目标组合，升级一次两轨受益）。若 A0 第 3 项核实 backend 语义有变，按核实结果定。

**步骤**：
1. 确认 `tests/qualification/basic` fixture 可运行（A0 第 5 项）；
2. 执行 `zoe qualification run --project P --profile <p> --fixture tests/qualification/basic --repo /tmp/disposable-repo --out docs/compatibility/claude-code-<backend>.json`；
3. **六项检查全部通过且 `source: real_e2e`** 才算成功；落到 `local_admin` 不升能力态（按 `docs/compatibility/README.md` 既有规则）；
4. 记录必须含精确 CLI 版本、平台架构、`argv[0]` 绝对路径（v0.5.0 起的 pinning 要求，bare-name 旧证据不采用）；
5. 同步更新 `docs/capabilities.md` 矩阵行与 `docs/adapter-qualification.md` Tested combinations 的 real 行。

**验收**：AC-DA-03（资格记录可被 schema 校验、`real_e2e` 来源、能力态升级生效，`zoe capabilities --json` 可见）。
**估算**：1–2 人日（不含环境开通等待）。

### A4 断连 / 故障演练

**目标**：机制已实现，缺实测记录。产出 `docs/drills/2026-Q4-drills.md`，每个场景记录：操作、观测、结果、与文档语义的一致性偏差。

**场景清单**（机制均已有，纯执行）：

| 场景 | 预期既有机制 | 观测点 |
|---|---|---|
| D1 `kill -9` 宿主与 `zoe` 进程后重新接管 | reconcile 决策树、writer lock、handoff.json | 恢复从哪个 phase 续、无重复写者 |
| D2 断网后 publish | drift 决策树 `remote_unknown` | 不当作 clean、不重复 PR |
| D3 push 成功但响应丢失（用代理注入） | 超时先对账 | 对照远端 ref，不重复副作用 |
| D4 旧 runner 存活时二次 `group start` | `lease_stale` | 旧实例拒绝写 |
| D5 验证后手改工作区再 accept | `WORKSPACE_CHANGED` / 指纹校验 | 拒绝沿用旧证据 |
| D6 `PROCESS_UNKNOWN` 时 `task recover --confirm-stop` | recovery-policy 收口前置 | 无依据时拒绝收口 |

**验收**：AC-DA-11/12/13（对应 D1/D3/D4）。
**估算**：1 人日。

### A5 测量协议校准试点（3–5 对，单 Agent）

**目标**：先用小样本校准 v1.0 §10.3 的测量口径，不产出收益结论。

- 任务：3–5 个真实小任务（短修复、跨文件改动各至少 1 个），A/B 各跑一次；
- A/B 配置：同一 CLI、同一模型、同一 Spec 与检查——**不含子 Agent**（轨 B 未启动）；
- 只校准三件事：H（主动时间）区间记录是否可操作且不重复累加、外部等待归类是否一致、验收返工判据是否清晰；
- 产出：测量协议修订稿 + 校准记录；**不计算净收益、不发结论**。
**估算**：1 人日。

### 轨 A 出口条件（里程碑 M1）

- [ ] 相容组合可安装（A1）
- [ ] 一个 `(adapter, backend, version)` 为 `VERIFIED`（A3）
- [ ] 敏感路径视图进入证据与报告（A2）
- [ ] D1–D6 演练记录在案（A4）
- [ ] 测量协议校准完成（A5）

---

## 3. 轨 B：原生只读委派（条件启动）

**总闸门**：B1 失败即关闭轨 B，交付一份"不支持"资格结论（写进 `docs/adapter-qualification.md`），**不启动 B2–B4**。

### B1 原生能力探针（可行性闸门）

**探针项与判定标准**（在 A3 已验证的执行链上进行；每项记录 CLI 精确版本 + 实测输出）：

| # | 探针项 | 通过标准 | 失败处置 |
|---|---|---|---|
| P1 | 动态子 Agent 定义入口（`--agents` 或等价） | 受控定义可注入且**优先级可证明**（与用户全局同名定义冲突时行为明确） | 不可证明优先级 → 判失败 |
| P2 | 子 Agent 工具限制真实生效 | 反向哨兵测试：子 Agent 调 Write/Bash/MCP 被底层工具层拒绝（不是模型口头承诺） | 判失败 |
| P3 | 生命周期闭合 | 目标版本下子任务不后台化，**父进程退出 ⟹ 子调用全部终结**可证明 | 需要额外事件通道才能证明闭合 → 进入 P3b |
| P3b | 事件通道（仅当 P3 需要时） | `--output-format stream-json`（或等价）提供子调用 start/stop 事件且事件 ID 稳定 | 判失败（否则 T4 需自建守护，违反非目标） |
| P4 | 非交互兼容 | `-p` 模式下子 Agent 可运行且权限继承行为明确 | 判失败 |
| P5 | 子调用模型上报 | 子调用模型可归属（复用 `requested/reported/identity_basis` 结构）或明确 `unobserved` | 无法固定子模型且无法阻止降级 → 判失败 |
| P6 | 配置来源清单 | 子 Agent 生效配置的来源集合（用户/项目/插件/hooks/MCP）可枚举 | 不能限定有效配置 → 判失败 |

**当前已核验的基础**：`claude_code.py` 已有 `permission_switch=True`、`permission_bindings={"isolated-edit": ("--permission-mode", "acceptEdits")}`、`--allowedTools` 逐工具传参（主线程限定可直接映射）；但 `output_protocol="json-final"`（单对象解析），**无事件流**——P3b 是 B3 工作量的决定项。
**验收**：AC-DB-04/05/06（对应 P2/P1/P4 的哨兵与反向用例）。
**估算**：2–3 人日。**kill-switch 写进本任务验收：任一判失败 → 轨 B 终止。**

### B2 策略编译与授权

**设计**（沿用 v1.0 §5，落点具体化）：
- `agent_profiles[].native_delegation = {"mode": "off|readonly", "child_profile": "<id>"}`，缺省 `off`；`child_profile` 引用既有已授权 profile，解析值（模型、`cost_class`、凭据前缀）进冻结策略；
- 只读模板（`zoe-readonly`：Read/Glob/Grep + 明确 prompt）由 adapter 编译为原生定义；**模板内容、工具清单、child_profile 解析值全部进 `policy_digest`**——任何变更走既有 `POLICY_CHANGED` + `rebind`，不热加载；
- 名称冲突且不能证明优先级时启动前拒绝（B1-P1 结论）；不覆盖用户全局配置；
- 模式行为表沿用 v1.0 §5.2（旧任务按旧语义恢复、`off` 不可关闭时不得宣传该保证、readonly 组合不合格则启动前阻断）。

**改动文件**：`src/_profiles.py`（解析与绑定）、`src/_routing.py`（冻结摘要）、`src/_agents/claude_code.py`（编译模板进 `LaunchSpec`）、契约测试。
**验收**：AC-DB-02/03/04。
**估算**：2–3 人日。

### B3 观察与收敛（含退化路径）

**两条实现路径，B1 结论决定走哪条**：

- **路径 α（P3 直接通过，优先）**：闭合判定退化为"父进程受管退出 + 适配器终态有效"，`assess_native_closure` 是一次廉价判定；观察记录仍写（覆盖标记 `complete` 仅在有覆盖契约时使用）。
- **路径 β（需 P3b 事件流）**：adapter 切换/增加事件流解析，归一化子调用事件进 `runs/<run_id>/native-delegation.json`（结构按 v1.0 §7.2：`schema_version`/`effective_policy_digest`/`observation.{coverage,closure,invocations}`/`review_binding`/`sensitive_changes`）；去重用原生 event ID，停止先于开始可暂存，截止收敛仍不一致则 `closure=unknown` 并阻断 verify。

**共同纪律**：
- 该清单是**可重建证据视图**，不是新状态库；状态转移依赖它时先持久化再推进（复用集成账本"prepared 先于 ref"的同款纪律）；
- `null` / `0` / `not_recorded` / `unknown` 四态严格区分；老任务标 `not_recorded` 不回填；
- 取消/恢复复用既有 supervisor / 租约 / handoff 语义；崩溃重试绑定新 attempt，旧子调用事件不计入新运行；
- 收敛公式沿用 v1.0 §6.2，但路径 α 下 `native_delegation_has_complete_closure` 由父进程终结证明直接满足。

**验收**：AC-DB-07/13/14/16。
**估算**：路径 α 1–2 人日；路径 β 3–5 人日（B1 后按实际重估）。

### B4 报告增量

- `task report` / delivery report 增加原生委派段（v1.0 §8.2 格式）：模式、资格、观察覆盖、收敛、子调用数、模型身份摘要、候选绑定评审状态、敏感变更；
- `review_binding: null` 时绝不展示"最终评审已通过"；辅助发现只标 advisory；
- JSON 与文本双输出进契约测试。
**验收**：AC-DB-10/14。**估算**：1 人日。

### B5 资格扩展与故障演练

- qualification 在六项既有检查外增加原生用例（真实只读拒绝、真实委派发生、真实终结），**独立于"CLI 可发现"资格**；证据仍走 `zoe qualification run` 输出格式，新增检查项进对应 schema 版本；
- 事件故障矩阵按 v1.0 §11.3 执行（重复/乱序/缺失/未知事件/截断/父退子未闭）。
**验收**：AC-DB-05/07/16。**估算**：2 人日。

### B6 对照试点（5–10 对）

- 沿用 A5 校准后的协议，加入子 Agent 维度（A/B 用相同子 Agent 定义与限制，按 v1.0 §10.1 控制项表）；
- 混杂因素处理、分配顺序、指标定义全部按 v1.0 §10 执行，本文不重复；
- 决策规则沿用 v1.0 §10.4：可靠性门禁失败先修；收益正向扩试点；混合则限域；无收益或维护过高则收缩——**功能发布成功不强迫收益结论为正**。
**验收**：AC-DB-15。**估算**：2–3 人日。

### B7 发布与交接

- 技能包：`native_delegation` 说明进 `references/runtime-contract.md`；监控/摘要说明同步；**不把 `native_readonly_delegation_v1` 加入全包 `required_capabilities`**，由入口实际使用时提出（配套发布旧版兼容包）；
- 支持矩阵只列实测组合；未验证平台明确"不标 VERIFIED"；
- 回滚按 v1.0 §13：先运行器后技能包、默认关闭、升级不自动打开、旧版本不恢复新模式在途任务。
**估算**：1–2 人日。

### 轨 B 出口条件（里程碑 M2）

- [ ] B1 全部探针通过（否则轨 B 已关闭）
- [ ] `native_delegation` 进冻结策略与授权链（B2）
- [ ] 收敛语义可证明且 unknown 阻断 verify（B3）
- [ ] 报告四态区分 + 契约测试（B4）
- [ ] 原生资格用例与故障矩阵通过（B5）
- [ ] 试点报告含原始配对表、失败与缺失数据（B6）

---

## 4. AC 清单（重编号）

`DA-` 属轨 A，`DB-` 属轨 B。验证方式列是验收时的证据要求。

| ID | Given / When / Then | 验证方式 | 来源 |
|---|---|---|---|
| DA-01 | 干净环境按发行说明安装相容组合，预检与最小任务成功 | 真实安装记录 | v1.0 AC-01 |
| DA-02 | 旧配置无新字段，既有任务生命周期回归不破坏 | 既有回归 + 旧任务恢复夹具 | v1.0 AC-02 |
| DA-03 | 资格记录通过 schema 校验、`source=real_e2e`、能力态升级在 `capabilities --json` 可见 | `qualification run` 产物核查 | 新增（v1.0 遗漏的交付物） |
| DA-08 | 候选验证后文件变化，旧验证不得用于交付 | 既有指纹回归 | v1.0 AC-08 |
| DA-09 | 测试/夹具/CI/Agent 配置变更被正确分类；合法测试修改不被禁止 | diff 夹具 + 报告快照 | v1.0 AC-09（提前至轨 A） |
| DA-11 | 关闭宿主后重新接管，不丢任务事实、不重复发布 | D1 真实演练 | v1.0 AC-11 |
| DA-12 | 远端动作成功但响应丢失，对账后不重复副作用 | D3 故障注入 | v1.0 AC-12 |
| DA-13 | 崩溃恢复遇旧运行活跃/身份未知，不生成新写者 | D4/D6 + reconcile 测试 | v1.0 AC-13 |
| DB-02 | 旧任务无 `native_delegation` 字段，按旧语义恢复且报告"未启用" | 兼容测试 | v1.0 AC-02 扩展 |
| DB-03 | 合格 readonly 配置启动，策略摘要覆盖模板与子 profile | 单测 + 冻结产物核查 | v1.0 AC-03 |
| DB-04 | 未授权子模型 / 不支持版本 / 配置不可验证 → 启动前拒绝，不静默降级 | 反向测试 | v1.0 AC-04 |
| DB-05 | 合格用例触发真实委派，得到关联 run 的原生证据 | CLI E2E | v1.0 AC-05 |
| DB-06 | 子 Agent 尝试写/shell/MCP/递归委派被底层拒绝 | 原生反向哨兵（P2） | v1.0 AC-06 |
| DB-07 | 子调用无未决且受管执行结束才进 verify；unknown 阻断 | 事件乱序/缺失/残留测试 | v1.0 AC-07 |
| DB-10 | 辅助发现未绑定候选时不展示"最终评审通过" | 报告契约测试 | v1.0 AC-10 |
| DB-14 | 报告严格区分 unknown / 0 / 未启用 / 未记录 | JSON+文本兼容测试 | v1.0 AC-14 |
| DB-15 | A/B 共用合理配置，全部试点运行与失败可追溯 | 冻结实验清单 | v1.0 AC-15 |
| DB-16 | 取消/超时后不能证明子任务终止，交付保持阻断 | 生命周期故障测试 | v1.0 AC-16 |

v1.0 的 AC-08/09/11/12/13 已并入轨 A 提前交付；其余编号保持 v1.0 语义。

---

## 5. 门禁与风险

### 门禁

| 门禁 | 条件 | 不满足时 |
|---|---|---|
| G0 可安装 | A0/A1 完成 | 只修发行缺陷，不开 A2 之后任务 |
| G1 已验证 | A3 完成（存在一条 `VERIFIED` 路径） | 轨 B 不启动（B1 探针无意义） |
| G2 可交付 | 轨 A 全部 AC 通过 | 修复后复测 |
| G3 可限定 | B1 全部探针通过 | **轨 B 终止**，交付"不支持"结论 |
| G4 可解释价值 | B6 完成，成本/失败/限制完整披露 | 可保留实验功能，不宣称收益 |

### 风险与对策

| 风险 | 概率 | 对策 |
|---|---|---|
| B1 P3/P3b 判失败（子任务后台化或无事件通道） | 中 | kill-switch 生效，轨 B 终止；轨 A 成果独立保留 |
| 1.6.0 发布流程阻塞 A1 | 低 | 切换 A1 方案二（技能包降级） |
| `anthropic-api` backend 语义与文档不符（A0-3） | 低 | 按核实结果修正文档与注册表标签，不新造语义 |
| 敏感分类误报（合法测试改动被过度提醒） | 中 | 分类只提醒不禁止；`sensitive_globs` 可被项目收窄；报告标注"提醒，不阻断" |
| 试点人工时间记录失真 | 高 | A5 校准先行；区间并集口径；无法记录的任务如实标缺失 |
| 契约测试拒绝证据新字段 | 低 | 按 `_evidence.py` 既有增量字段惯例 + 契约版本提升预案 |

### 回滚

- 轨 A 各任务独立成 PR，单独可回滚；A2 的 `sensitive_changes` 为增量字段，回滚不破坏旧证据读取；
- 轨 B 回滚按 v1.0 §13 执行（默认关闭、旧版本不恢复新模式在途任务、保留资格与失败记录）；
- 全程禁止热降级；schema 变更走 `zoe state migrate` 备份链。

---

## 6. 最终交付检查表

- [ ] T0/A0 核查记录绑定两仓 SHA，所有"待核实"项闭环
- [ ] 相容组合新用户可安装、可跑通最小任务（A1）
- [ ] README 首屏保证与 threat-model 三分法一致（A1）
- [ ] 敏感路径视图进入证据与交付报告，合法测试修改不被禁止（A2）
- [ ] 一条 `(adapter, backend, version)` 升 `VERIFIED`，`docs/compatibility/` 有 real_e2e 记录（A3）
- [ ] D1–D6 演练记录在案（A4）
- [ ] 测量协议经 3–5 对校准并定稿（A5）
- [ ] （若轨 B 启动）B1 探针记录 + kill-switch 判定留痕
- [ ] （若轨 B 启动）只读委派真实发生、真实拒绝、真实终结三类证据齐全
- [ ] （若轨 B 启动）模型授权覆盖子调用，未知身份/未知费用未被掩盖
- [ ] （若轨 B 启动）试点报告含原始配对表、失败与缺失数据，决策规则已执行
- [ ] 支持范围、回滚方式、未验证平台公开说明
- [ ] 阶段结论允许继续 / 限域 / 停止扩展，不预设正收益

---

## 附：本版相对 v1.0 的关键增补

1. **轨 A 独立成线**：M1（一条已验证交付路径）不依赖轨 B，5–8 人日可达。
2. **`VERIFIED` 升级为明确交付物**：`zoe qualification run` → `docs/compatibility/` 记录 → 能力态升级，六检查全过且 `real_e2e`（v1.0 遗漏）。
3. **敏感路径视图解耦并给出代码级落点**：`src/_sensitive.py` + `scope()` 复用 + 证据增量字段 + 报告段，2–3 人日。
4. **B3 双路径设计**：P3 直接通过时闭合判定退化为廉价检查，避免 3–5 人日的事件流工程。
5. **B1 探针量化为 P1–P6 判定表**，kill-switch 写进验收而非附注。
6. **修正 v1.0 §9 的资源串行化表述**，试点以单顶层任务回避。
7. **试点分两步**：A5 校准（3–5 对、单 Agent、不出结论）→ B6 正式（5–10 对）。
