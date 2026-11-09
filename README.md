# zoe-workflows

宿主技能包：用 Zoe CLI 把需求写成 Spec、派发给编码 Agent、跟踪进度、处理暂停与恢复、
汇总交付。**本仓库只包含技能内容，不含运行器**——运行器是独立安装的
[`zoe-runtime`](https://github.com/zoe-runtime/zoe-runtime) 发行版（≥ 1.5.2，< 2.0.0）。

```text
SKILL.md                   宿主读取的技能定义（能力边界、执行配置授权、工作步骤、组交付）
references/                契约、模板、策略与三档项目配置示例（23 份：17 Markdown + 6 JSON）
                           monitoring-playbook.md：监控的异常分支与低频语义（第 6 步按需读取）
                           model-identity.md：模型身份三层、别名登记、成本档与 probe 代价
scripts/                   zoe.sh / zoe.cmd / zoe.ps1：定位 + 兼容预检 + 转发
                           zoe-monitor.sh / .ps1：有界事件查询 + 权威状态机 + 可选可读进展
                           zoe-digest.sh：一版摘要（状态·静默·字节 + 最近说/动），--since 增量
                           zoe-watchd.sh：脱离会话的只读守护（live.md / live.jsonl），可停、锁自愈
                           zoe-resume.sh / zoe-attest.sh：恢复与授权确认的两段式入口
                           zoe-revise-scope.sh：只放宽 allowed_paths 的两段式入口（复用工作区）
                           zoe-ac-gate.sh：合并前逐条 AC 核对（第二层验收），只读，退出码即结论
                           zoe-auto-recover.sh：block_code → 恢复动作（默认只建议，--apply 仅 auto 档）
runtime-requirements.json 与运行器的唯一锚点（版本区间 + api_version + 能力名）
build.py                   --check 审计 / --pack 打包
docs/                      设计记录（配置摩擦、使用评估），不进入分发包
```

## 它做什么

技能本身不执行代码，只负责把「一次交付」拆成可被控制器审计的步骤：

```text
需求 ──▶ 分流（该不该进 zoe）──▶ Spec（三层验收 + allowed_paths + verification_scope）
      ──▶ task prepare（只读预检：会不会过、会冻结什么）
      ──▶ task create / start（冻结 Spec、派发执行）
      ──▶ watch --follow + task logs --follow（有界游标，静默即心跳）
      ──▶ task report ──▶ task accept（人工验收）
```

多成员交付走**任务组**，一次验收而不是逐个验收：

```text
group plan ──▶ group create（冻结）──▶ group start（短命推进器，成员串行）
            ──▶ group review（计划要求时必需，宿主独立上下文执行）
            ──▶ group accept ──▶ group report（七段）
```

技能里写死的纪律（不是建议）：单任务唯一写者、Agent 自述不是证据、检查失败不重写代码、
未验证执行器必须标 `unverified` / `trust_level`、组成员不能自验收、独立评审无法进行时
写「未能进行」而不是静默降级。

## 安装

### 1. 安装运行器（另一件事）

```bash
pipx install zoe-runtime
pipx ensurepath
zoe --version && zoe capabilities --json
```

只有 `zoe-runtime` 提供了本 skill 声明的版本区间与 API 版本时，调用才会被转发。
完整安装、离线安装与升级说明见运行器仓库的 `docs/installation.md` 与 `docs/upgrading.md`。

### 2. 安装本 skill

把本仓库内容放到宿主的技能扫描目录，**目录名用 `zoe-workflows`**：

```bash
git clone https://github.com/zoe-runtime/zoe-workflows.git ~/.workbuddy/skills/zoe-workflows
```

用 GitHub 的 “Download ZIP” 时，解压出来的目录可能带分支或版本后缀
（如 `zoe-workflows-main`、`zoe-workflows-1.0.0`）。宿主通常按**目录名**识别技能，
所以请改名后再放置：

```bash
unzip zoe-workflows.zip
mv zoe-workflows-main ~/.workbuddy/skills/zoe-workflows
```

发布包结构固定，顶层就是 `zoe-workflows/`：

```bash
python3 build.py --check     # 审计：白名单、frontmatter、必需文件、可执行位
python3 build.py --pack      # 输出 dist/zoe-workflows.zip
unzip -l dist/zoe-workflows.zip
```

打包用**白名单**：`SKILL.md`、`README.md`、`LICENSE`、`runtime-requirements.json`、
`references/**`、`scripts/**`。`docs/` 设计记录、实验文件与备份不会进入分发包；
`build.py --check` 还会逐个校验 35 个必需文件，缺一个就失败，而不是悄悄缩小发布包；
同一道闸门还卡 `SKILL.md` 的结构预算（总量、单个步骤、第 6 步的小节粒度），
规则被埋进长文会让 `--check` 变红，而不是等到宿主漏看。

## 兼容预检（强制）

预检在调用路径内部完成，不是可选步骤：包装器解析出一个绝对路径后，先用它执行
`capabilities --check-requirements runtime-requirements.json`，通过才用**同一个**路径转发
用户请求，两者不会分叉到不同二进制。

`runtime-requirements.json` 声明：`min_version` 1.6.0、`max_version_exclusive` 2.0.0、
`api_version` 2、`protocol_revision` 1，以及 21 个 `required_capabilities`
（任务组与组计划/依赖图/串行执行/租约/预算/检查/验收、`check_error_class`、`auth_mode`、
`group_design_review`、`group_review_contract`、`group_bounded_repair`、
`event_project_filter`、`logs_follow`、`logs_incremental_read`、`run_observation`、
`checks_preflight`、`task_digest`、`task_list_fields`、`base_drift_preflight`）。
少一项就不转发——能力名是运行器自己声明的，技能侧不猜。

| 情况 | 退出码 | `error.code` |
|---|---|---|
| 运行器未找到 / `ZOE_BIN` 不可执行 / `ZOE_SRC` 不合法 | 126 | `RUNTIME_NOT_FOUND` / `RUNTIME_NOT_EXECUTABLE` |
| 版本区间、`api_version`、`protocol_revision`、能力名不满足 | 5 | `RUNTIME_INCOMPATIBLE` |
| 技能包缺少 `runtime-requirements.json` | 126 | `RUNTIME_REQUIREMENTS_MISSING` |
| 运行器能启动但预检自己崩了（import 失败 / 语法错误） | 126 | `RUNTIME_BROKEN`（`details.gate_log` 指向原始 traceback） |

`--version` 与 `--which` 不受预检限制——运行器被拒时正需要它们来诊断。
结构化错误写在 **stdout**（与运行器同一通道），退出码语义不变。

```bash
bash scripts/zoe.sh --which      # 包装器实际会执行的 Zoe 路径、来源、锚点文件
bash scripts/zoe.sh --version
```

## GUI 宿主的 PATH 陷阱

终端里 `command -v zoe` 有结果，不代表由 GUI 启动的 WorkBuddy / OpenClaw 能找到它
（GUI 进程可能没有加载 shell 的 PATH）。处理顺序：

1. `bash scripts/zoe.sh --which` 看实际解析结果（**不是** `zoe doctor` 里的 `resolution`，
   那是编码 Agent 的路径）；
2. 为宿主配置显式的 `ZOE_BIN` 绝对路径；
3. 重启宿主后复验；
4. 预检与执行使用同一个路径，不要一处用 `ZOE_BIN`、另一处用 PATH。

## 使用要点

- **先预检再创建**：`task prepare --project P --spec spec.json` 是只读的，把诊断一次看完；
  `--emit` 生成的草稿带 `<FILL:...>` 占位符，没删干净时 `create` 会拒绝（设计意图）。
- **授权要先确认**：项目声明了 `routing` 段时，`create/start/reassign` 会返回
  `ALLOWLIST_UNCONFIRMED`；把候选与执行配置展示给用户，用户明确同意后才执行
  `project attest`。技能**不得**自行改 `agent_profiles` / `routing` 再把结果说成「用户授权」。
- **观察用游标**：`watch --follow --jsonl --after <epoch>:<event_id>` 与
  `task logs <id> --follow --cursor <run>:<gen>:<offset>` 都是到 `--timeout` 退出；
  `watch --follow` 的首行 `follow_start`、末行 `follow_end` 都带游标，可直接续读。
  无事件行是心跳，不是卡死，也不是可以结束回合的理由。
- **看"在做什么"用两条线**：非阻塞快照增量 `task logs <id> --after <run>:<gen>:<offset>`
  （读 `events` 里的 `kind=text|tool` 与 `next_cursor`，`has_more` 为假就停），
  或 `--follow`（不带 `--tail-bytes` 时从当前末尾开始）。`kind=record` / `kind=raw`
  不是"没有输出"；日志静默也不证明卡死。
- **监控用脚本**：`bash scripts/zoe-monitor.sh --project P --targets "T1 T2"` 把上面的
  纪律固化成退出码（0 全部终态 **或**预算到期 / 10 需人工介入 / 11 监控不可用）
  + `[stop] reason=…`（`--stop-file` 可写成 JSON），不做无人值守推进；
  `--with-log` 追加**新增的**可读进展（`[log]` 只是过程观察，不是成功证据）。
  预算别拍上限：传 `--deadline-in <本回合剩余秒数>`，脚本反推 `min(剩余-guard, max-seconds)`
  并打印 `[budget]`；`[tick]` 自带 `changed=N`，`--tick-content` 追加
  `[tick-log] last=…`。预算/人工/不可达退出时打印 `[renewal] owner=… command="…"`——
  那是**续期单**（谁负责拉起写在 `owner` 里），不是"稍后继续"的客套话。
- **会话之外**：`zoe-watchd.sh start/stop/status` 是只读常驻守护，变化写 `live.jsonl`、
  快照写 `live.md`；它不 start/resume/accept（脚本内部拦截，调用即 exit 70），也不代替
  合并判断。会话关闭后它只记录、不推进——无人值守推进需要宿主定时任务。
- **两种收口不能混**：任务组走 `group accept`（成员不能自验收），独立任务各自
  `task accept`；没有「事后把独立任务加进组」的命令。

细节都在 `SKILL.md` 与 `references/`：契约与错误码看
[cli-contract.md](references/cli-contract.md)，项目配置与 doctor 看
[runtime-contract.md](references/runtime-contract.md)，组交付看
[group-delivery.md](references/group-delivery.md)，设计审查看
[design-review-rubric.md](references/design-review-rubric.md)，监控异常分支看
[monitoring-playbook.md](references/monitoring-playbook.md)。

## 版本与升级

`runtime-requirements.json` 是本仓库对运行器的全部要求（版本区间、`api_version`、
`protocol_revision`、能力名），改动它就是改变兼容承诺；文件本身即唯一副本，此处不再复述。
落在区间内可以直接升级运行器，超出区间就要同时升级本 skill。升级运行器前先备份状态，
运行器侧的 schema 变更走 `zoe state migrate`。卸载运行器默认不删除任务状态与证据。

## 契约门禁

本仓库的 CI 校验「技能说了运行器做不到的事」：技能声称不存在的命令或参数为红，运行器删除
技能依赖的接口为红，两侧各自收敛未使用的命令为绿。命令级契约由 CI 校验，运行时不解析命令
清单——运行时只查版本、API 版本与能力名。

## License

Apache-2.0，见 [LICENSE](LICENSE)。
