# 组计划请求（`group plan` / `group create`）

一份计划就是**一个被冻结的成员依赖图**：成员、谁依赖谁、每个需求由谁负责、最后一次验收跑哪些
检查。冻结之后运行中只改 `runtime`，不改 `definition`。

运行器侧契约见 `zoe-runtime` 的 `schemas/group-plan.v1.json`；派发与推进语义见
[group-delivery.md](group-delivery.md)。

## 两种 `group plan`

| 形式 | 作用 | 副作用 |
|---|---|---|
| `group plan --project P --request-file plan.json` | 预览**未冻结**计划：校验 + 路由预演 + 基线快照 | **无**（不建记录、不建任务、不写事件） |
| `group plan GID` | 已存在组的准入快照（哪些成员现在可派发、卡在哪） | 无 |

同名不同形，按有没有 `GID` 分派。先预览再 `create`：一个不可行的计划应该在被讨论时就被拒绝，
而不是冻结完才发现跑不动。

## 最小请求

```json
{
  "schema_version": 2,
  "request_id": "req-1",
  "authorization_ref": "owner:me@2026-10-30",
  "project_id": "demo",
  "title": "导出能力交付",
  "design_files": ["docs/design/export.md"],
  "delivery_mode": "local_artifact",
  "base_ref": "HEAD",
  "budget": {"max_starts": 12, "max_wall_seconds": 14400, "max_group_repairs": 2},
  "review": {"required": true, "mode": "agent"},
  "requirements": [{"id": "REQ-01", "statement": "支持按条件导出", "source": "export.md#3.2"}],
  "members": [
    {
      "task_key": "export-contract",
      "title": "导出接口",
      "spec_file": "specs/export-contract.json",
      "depends_on": [],
      "requirement_ids": ["REQ-01"],
      "acceptance_ids": ["AC-01"],
      "expected_paths": ["src/export", "tests/export"],
      "task_type": "feature",
      "requested_profile": null,
      "check_ids": ["export-contract-test"]
    }
  ],
  "group_checks": ["integration"]
}
```

字段口径：

- `schema_version` 固定 `2`。带 `ordered_items` 的旧请求仍可创建，但那只是**有序记录**：
  不能带 `depends_on`，不能 `start`。
- `delivery_mode` 只能是 `local_artifact`。`pull_request` **创建即拒**
  （`CAPABILITY_UNSUPPORTED` / `kind=group_pr_unsupported`）——v1.3 没有 PR 组收口路径，
  自己在外部合并只能 `group cancel --external` 记账。
- `budget.max_starts` **必填**且不会被按规模推算；`max_wall_seconds` 可为 `null`（不限，
  响应会写明"未设时长上限"）。
- `budget.max_group_repairs` 是**组级修复轮数**上限（v1.4）。缺省 = `0` = **不授权任何修复
  执行**；它不是"可以无限修"，也不会按成员数推算。写 `2` 就是最多两次有界修复。
- `review` 决定设计一致性审查是否参与验收（v1.4）：`{"required": true, "mode":
  "agent|human|either"}`。**省略这一段就等于放弃这一层**——验收只有结构覆盖 + 组级检查，
  `group create` 会在 `warnings` 里点名。审查怎么做、要覆盖什么，见
  [design-review-rubric.md](design-review-rubric.md)。
- `request_id` 是幂等键：同 id 同内容返回原结果，不再建第二个组。
- `members[].task_type` 只能用词表值：`bugfix` / `feature` / `refactor` / `test` / `docs` /
  `chore` / `review` / `unknown`。写成 `api`、`backend` 这类"看起来更具体"的类别会直接
  `INPUT_INCOMPLETE`。它同时是路由依据（`routing.rules[].task_type`），所以**词表外的值
  不会退化成默认档，而是整个请求被拒**。

## `expected_paths` 只是规划提示，不是授权

它在 `group plan` 里用于提示"这些成员会碰同一片目录"，在报告里用于说明预期范围。
真正生效的强制范围来自既有机制：项目 `allowed_paths` ∩ 成员 spec 的 `allowed_paths`
（spec 只能收紧，不能放宽），越界在事后由 `scope()` 列出。

所以：**不要把 `expected_paths` 当成扩权手段**，也不要因为计划里写了某个目录就认为可以改它。
校验只拒绝绝对路径、盘符、父目录逃逸，以及解析符号链接后落在所有 `allowed_paths` 目录之外的路径
（按目录边界判定，`src/export` 不包含 `src/exported`）。

## 会被拒绝的常见原因

| `details.kind` / 码 | 触发条件 | 处置 |
|---|---|---|
| `cycle` | `depends_on` 成环或指向不存在的 `task_key` | 改图；环在写任何东西之前就被拒 |
| `coverage_missing` | 某个 `REQ` 没有任何成员认领 | 给需求指定成员，或删掉这条需求 |
| `INPUT_INCOMPLETE` | `task_key` 重复/非安全 id、成员 spec 的 AC 为空、`check` 型 AC 指向未声明的检查、`max_starts` 缺失 | 补全请求或 spec |
| `POLICY_DENIED` | 成员 spec 的 `allowed_paths` 试图放宽项目范围 | 收窄 spec；扩权是显式策略变更，不是计划字段 |
| `CAPABILITY_UNSUPPORTED` + `group_pr_unsupported` | `delivery_mode=pull_request` | 改 `local_artifact` |
| `legacy_group` | 对旧有序组用了 `start/pause/resume/cancel/accept/report` | 以 `schema_version: 2` 重建为计划 |

**结构覆盖 ≠ 语义实现**：拒绝码只说明"计划结构自相矛盾"，通过也只说明"每个需求都有责任成员、
每个必需 AC 都有验证方法与责任成员"。实现是否符合设计语义，要看**设计一致性审查**——它是否
参与验收由 `review.required` 决定；没启用时报告写 `NOT_REQUIRED`，看起来像"通过"但不含任何
语义判断（见 [design-review-rubric.md](design-review-rubric.md)）。

## 冻结时发生了什么

`group create` 是一次性落盘：

1. 逐成员读取 `spec_file`，按 `_contracts.load_spec` 校验后写成
   `groups/<gid>/specs/<task_key>.json` 快照；记录 `spec_sha256`。仓库之后改 spec 不影响本组，
   成员任务创建时若快照的 sha 与记录不符 ⇒ `SPEC_CHANGED`。
2. 写 `plan-r001.json`（definition + `plan_digest`）、`baseline.json`、`design-manifest.json`，
   配了路由的项目还会写 `routes/<task_key>-a001.json`（纯预演，不是准入）。
3. 最后才提交组记录。记录先于产物会让状态指向不存在的文件，所以顺序不能反。

`plan_digest` 只覆盖不可变投影：需求、成员、组检查、预算上限、`base_sha`、`design_digest`。
运行中的计数（启动了次数、集成到哪个 SHA、检查结果）**不会**改摘要；只有计划本身变了才
`revision+1`。要改已冻结的计划 ⇒ 新组（`follow_up_of`），不在原组上原地改。
