# Spec：<标题>
- Spec ID：<稳定编号>
- Revision：1
- 来源：<需求、会议、工单或用户说明>
- 仓库与调研基线：<repo-id / SHA>
- Owner：<验收责任人>

## 目标与非目标
描述用户场景、期望行为、本期不做的范围。

## 用户强调
用户反复提到、用「尤其 / 务必 / 千万别」强调的点，以及搞坏了最难受的地方。
执行期遇到目标没覆盖的情况时，这里是判断依据，不是装饰。没有就写「无」，不要留空。

## 现状与依据
相关模块、已有接口、测试入口；区分已确认事实与假设。

## 文件边界
本节必须与结构化 spec 的 `allowed_paths` **逐条一致**。Markdown 只是给人看的副本：
**运行时只读 `spec.json` 的 `allowed_paths`**。整篇 spec 如果不是 JSON，会被解析成
`contract_version=1, document=null`，`allowed_paths`、AC 绑定全部失效、任务范围回落到
项目级——写在本节的路径一个字都不会生效。

- 必须修改：`internal/app/publish_flow.go`
- 允许新增：`internal/app/publish_flow_test.go`
- 禁止修改：其他任何文件（含 `go.mod`、注册表、入口文件、其他包）
- 依据：<为什么只动这些文件；跨文件的改动属于另一张任务单>

并行批次（同一波次 ≥2 个任务同时跑）里，本节的路径必须是**文件级**。只写包名/目录等于
没写：Worker 可以在该目录下任意改文件，而 `SCOPE_VIOLATION` 永远不会触发。目录级范围只
在"这个任务拥有整个包"时使用，并且要在本节写明这句话。

**改公开契约的硬要求**：如果本次改动会改变导出符号、接口签名、CLI 参数或 schema 字段，
那么"必须同步修改的既有用例文件"也要写进 `allowed_paths`。不写就会出现这条死路：Worker
为了让既有用例编译通过去改它 ⇒ 越界 ⇒ 该 run 以 `SCOPE_VIOLATION` 收场，改动留在 worktree
但不成为 candidate，只能 `revise` 后重起一轮。另一条合法路径是派发前拆成"先契约、后实现"
两个任务。

## 影响面（既有用例与调用方）

回答一个问题：**这次改动会不会牵动 spec 之外的既有文件？** 会，就把它们点名；不会，写「无」。

- 公开契约变化：<例如 `FetchRequest.q` 由可选改为必填 / 新增 CLI 子命令 / 删除字段>
- 必须同步的既有用例：<`tests/test_x.py` —— 仅参数对齐，断言数量与覆盖面不得减少>
- 必须同步的调用方：<模块或脚本；没有就写「无」>
- 未纳入 `allowed_paths` 的后果：`SCOPE_VIOLATION`，该 run 不产出 candidate
- 兼容性判断：<是否破坏既有调用方；需要迁移就写迁移方式>

这一节是给人读的：结构化 `spec.json` 没有对应字段，写在这里的路径必须同时出现在
`allowed_paths` 里才算生效。

## 业务与数据约束
权限、租户隔离、数据量、兼容性、敏感数据处理。
未确定且会推翻实现的问题不要塞在这里，见「待决问题」。

## 实现设计
模块与接口变化、数据流、异常处理。
涉及迁移/幂等/并发时补充相应设计；不要求简单文档任务填写空洞章节。

## 验收标准
三层分类，不要合并成一句「命令或人工步骤」。区别不在写法，在**谁能下结论**。

### 自动检查（结构化 spec：`verification.type=check`）
- AC-001：Given ... When ... Then ...；验证：`<check_id>`

由控制器在任务工作区执行，留 exit code 与日志。`check_id` 必须来自项目批准的 checks。

### 自审项（`verification.type=manual`）
- AC-002：<判断标准 + 什么算通过>；判者：<评审人 / 评审 agent 的 profile>

需要判断、无法命令化，但标准必须写得让第三者能判。

### 集成场景（`verification.type=manual`）
- AC-003：<步骤 → 预期结果>；执行与判定：<谁>

端到端链路，单条命令证明不了的那种。

自审项与集成场景的判者**不能是产生该改动的同一个上下文**：执行者自己写「我看过了」
不构成通过，按 `NOT_RUN` 处理（见 [delivery-policy.md](delivery-policy.md)）。
manual 项不写进 `verification_scope.checks`，也不占用 `check_id`。

**v3 结构化写法（`schema_version: 3`）**：manual 项必须声明 `judge`，并可以把
"机器能判的那一半"挂在 `supporting_checks` 上：

```json
{
  "id": "AC-3",
  "statement": "R-10 黄金算例经 serve.sh 端到端跑通，产物与基线一致",
  "verification": {
    "type": "manual",
    "judge": "independent",
    "supporting_checks": ["ac-r10-golden"],
    "instructions": "判者核对 ac-r10-golden 的日志中出现 served=true，并比对 out.json 与基线"
  }
}
```

`supporting_checks` 只能引用**项目已批准的 check**：spec 里内联 shell 命令既不执行、
也不进证据，写了等于没写。它的 PASS 只进"依据"列，**不构成该 AC 通过**——结论永远
来自 `task review`。

### 验收标准自检（写不出判据就退回重写）

| 反模式 | 为什么不行 | 改成 |
|---|---|---|
| 唯一 AC 是 `{"type":"check","check_id":"unit"}` | 只证明"没崩"，不证明"做完了" | 至少一条证伪式 AC：在 `base_sha` 上必然失败 |
| AC 说行为，check 跑的是另一个模块的测试 | 证据与 AC 没有因果关系 | AC 与 check 一一对应 |
| `verification_scope` 收窄到 `["unit"]` | 其它 check 记 `NOT_RUN`，而 `NOT_RUN` 不阻断 accept | 只验一部分时，报告必须写"项目级验证未执行" |
| manual 写"人工确认功能正常" | 无法判定，必然退化成"未记录逐项人工结论" | 写清"看哪条证据、什么算通过" |
| 一条 AC 覆盖多个可独立失败的机制 | 部分完成只能整条 FAIL 或整条 PASS | 拆成多条 |

`prepare` 会对上面几种形状给 `advice[]`（`AC_SINGLE_ITEM` / `AC_SINGLE_SIGNAL` /
`REVIEW_NOT_INDEPENDENT`）。它们是建议，不阻断派发——但**不处理的后果是这次交付没有
一条结论能指着证据说"过了"**。

## 开发任务
| 任务 | 范围 | 前置条件 | 交付物 | 验收 ID |
|---|---|---|---|---|
| T1 | ... | 无 | ... | AC-001 |

## 验证与交付
验证 profile、必要 CI、PR 目标分支、人工验收方式。
只验一部分 checks 时（结构化 spec v2）声明 `verification_scope`，例如
`{"verification_scope": {"checks": ["lint", "slice_a"]}}`：键缺省即跑全部 checks，声明后
未列入的记 `NOT_RUN`——不是通过，也不是失败。字段约束与 `INPUT_INCOMPLETE` 判定见
[cli-contract.md](cli-contract.md)。

声明范围不改变 `allowed_paths`、不改变策略，也不是「可以少写测试」的许可。

交付类任务还要声明两件事，否则第一层（checks 全绿）过了、第二层（每条 AC 有结论）
仍然是空的：

```json
"acceptance_review": {"required": true, "mode": "either", "independent": true},
"progress_refs": [
  {"acceptance_id": "AC-1", "doc": "docs/investment-os修复设计与研发任务拆分v1.md", "marker": "R-14"}
]
```

- 没有 `acceptance_review.required`，`accept` 只收一个整体 decision，manual 项在报告里
  永远是「未记录逐项人工结论」；
- `progress_refs.doc` **必须出现在 `allowed_paths` 里**（否则 `prepare` 报
  `PROGRESS_REF_OUT_OF_SCOPE`，阻断）。verify 阶段会检查该 marker 所在行已是 `- [x]`，
  否则 `PROGRESS_NOT_TICKED`——**进度回写是交付物的一部分，不是合并之后的收尾动作。**

**上游依赖**（`depends_on`，marker 列表）：

```json
"depends_on": ["R-10", "R-05"]
```

- `start` 要求上游**已闭环**（`DONE` + `accepted` + 逐条判定满足），不是"任务存在"；
  不满足返回 `DEPENDENCY_NOT_MET`（5），在派发之前就拒，不白烧一次 run；
- 用 marker 而不是 `task_id`：后者由运行时生成，没法预先写下来；
- 不能依赖自己认领的 marker（契约层直接拒绝——自依赖永远等不到）；
- 复核类（R 类）任务**必须**声明："我复核过了"在上游没闭环时是伪造结论，
  这正是 R-27 的形态。

## 待决问题
推迟或含糊的点，逐条写清「没答案会卡在哪一步」。映射到结构化 spec 的 `open_questions`：

- 阻塞性的必须先回答才能 create/revise（`INPUT_INCOMPLETE`），不要靠假设把它填满；
- 不阻塞的可以带着进入执行，但**一旦变成阻塞**，走 `task answer`（只澄清）或
  `task revise`（改验收标准），不得自行决定后继续。

没有就写「无」。

## 设计裁定（D 类）

与「待决问题」不是一回事：待决问题让实现**无法开始**（`open_questions` 非空即拒绝
create）；裁定让实现可以开始、但**结论未定**。

裁定**不是代码任务**，不得派发给 Worker。写进结构化 spec 的 `decisions`：

| 字段 | 要求 |
|---|---|
| `id` | `D-1` 起，跨版本稳定 |
| `question` | 一句话说清冲突点（"C2 契约冻结判 R 还是 F"） |
| `options` | ≥2 个互斥选项，每个都能被执行 |
| `recommendation` | 建议结论 + 一句理由；没有建议写 `null`，不要编 |
| `impact_if_wrong` | 判错会推翻什么（哪条 AC 要重写、哪个基线要重做） |
| `status` | `open` / `resolved`；`resolved` 必须带 `resolved_by` 与 `resolution` |

`open` 不阻断 create，**阻断 accept**（`DECISIONS_OPEN`）。这意味着带着未拍板裁定
派发的任务可以写完代码，但无法被验收——这正是我们要的形状：**先能开工，但不能
"顺手"把结论当事实**。

模板见 [decision-record.md](decision-record.md)。

## 风险与回滚
只列本次相关问题。记录已获授权的操作范围。

> 结构化 `spec.json` 只使用既有字段：验收标准与待决问题分别对应
> `acceptance_criteria[].verification`、`open_questions`，范围对应 `allowed_paths`；
> **不要新增顶层键**——旧版本不拒绝未知键，但冻结后不会有人按它执行。
> 「用户强调」与「风险与回滚」在结构化 spec 里没有独立字段：写进 Markdown 版，
> 或并入目标与约束的描述，不要凭空造键。
>
> 反过来更重要：**纯 Markdown spec 能 create，但它放弃了三样东西**——范围
> （`allowed_paths`）、边界（`SCOPE_VIOLATION` 判定依据）、AC 与 checks 的绑定。
> 交付类任务一律用结构化 `spec.json`（模板见 `spec.example.json`）；只有纯调研、
> 纯说明类任务才允许 Markdown-only。
