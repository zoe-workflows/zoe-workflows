# 设计一致性审查（`group review`）

这一层回答的问题是：**最终集成出来的东西，是否符合当初批准的设计？**

它和组级检查不是一回事。组级检查回答"命令跑不跑得绿"，审查回答"需求语义有没有被实现"。
两者都不能替对方作证：检查全绿而实现走偏是常见事故，审查说"符合"而检查是红的也不成立。

## 谁来做

- 由**独立上下文**产出：不能是实现该成员的同一个会话，也不能把实现者的完成总结当作业绩材料。
- 同一个模型 + 新会话是允许的，但**不得**在报告里宣称"统计独立"或"独立第三方"；
  只能写"独立会话 / 独立上下文"。
- 高风险场景可以用不同 profile（换模型）做审查，但那是加强，不是本层的前置条件。
- 审查**只产出结论**，不改任务状态、不改验收标准、不合并分支。它没有权力把标准调低。

## 输入

| 输入 | 来源 |
|---|---|
| 冻结设计 | `groups/<gid>/design-manifest.json`（以及它列出的设计文件本身） |
| 最终差异 | `integration_sha` 相对 `base_sha` 的 diff |
| 需求与 AC 映射 | `plan-r001.json` 的 `requirements` / 成员的 `requirement_ids` / `acceptance_ids` |
| 检查结果 | `checks/<subject_sha>.json` 与成员任务的证据记录 |
| 交付版本 | `group status GROUP --json` 的 `integration_sha` |

审查**不要**读实现 Agent 的自述结论当证据；自述可以说明意图，不是事实。

## 逐条判据

必须对计划里的**每一个**必需 AC 给出状态，一个都不能少：

| 状态 | 什么时候用 | 后果 |
|---|---|---|
| `PASS` | 在最终差异里找到了满足该 AC 的实现，且证据可解析 | 计入通过 |
| `FAIL` | 找到明确偏差（缺实现、实现相反、权限没加、契约没改……） | 阻断 `REVIEW_READY`；可走 `group repair` |
| `NOT_VERIFIED` | 该 AC 是体验/业务判断，或证据不足以下结论 | 记录并逐条列出，**不计入通过** |

判 `PASS` 前自问三句：证据是**这个** `integration_sha` 上的吗？证据指向的记录真的存在吗？
如果把结论反过来，会不会也能自圆其说（能，就说明证据不够）？

## 证据写法

`evidence_refs` 只接受三种形态，且都必须指向**当前**集成版本：

| 形态 | 指向 | 何时可用 |
|---|---|---|
| `check:<check_id>` | 组级检查或已集成成员声明过的检查，且状态为 PASS | AC 是 check 型 |
| `group:<subject_sha>` | 本版本组级检查记录文件 | 结论建立在整组检查之上 |
| `task:<task_id>` | 本组已集成的成员任务（含修复单元）及其证据文件 | AC 由某个成员交付 |

`locations` 写仓库相对路径（`src/export/handler.py`），不要写绝对路径或 `..`。
`suggested_action` 只是给人看的建议，**永远不会**被当成 shell 命令执行。

## 常见错误（都会被拒或会让结论作废）

- **漏项**：只写有问题的几条，其余"应该没问题"。整份输出无效，不是部分通过。
- **伪引用**：写一个不存在的 check id 或别的版本的 SHA。与缺失证据同等处理。
- **拿旧结论交差**：修复单元集成后 `integration_sha` 变了，旧结论变 `STALE`。
- **把 `NOT_VERIFIED` 当通过**：它可以让组进 `REVIEW_READY`，但报告必须列出，且不计入成功。
- **改写标准**：为了让 finding 消失而放宽 AC，不是修复，是回到计划修订。

## 输出契约

```json
{
  "request_id": "review-1",
  "actor": "workbuddy",
  "authorization_ref": "<项目授权引用>",
  "review": {
    "schema_version": 1,
    "subject_sha": "<group status 里的 integration_sha>",
    "design_digest": "<group status 里的 design_digest>",
    "reviewer": {
      "kind": "agent",
      "profile_id": "review-profile",
      "independent_context": true
    },
    "items": [
      {
        "acceptance_id": "AC-01",
        "status": "FAIL",
        "finding": "普通用户仍可调用导出接口",
        "locations": ["src/export/handler.py"],
        "evidence_refs": ["check:export-contract-test"],
        "suggested_action": "补权限判断并重跑权限测试"
      }
    ]
  }
}
```

运行器侧契约见 `zoe-runtime` 的 `schemas/group-review.v1.json`。

## 审查之后

| 结论 | 下一步 |
|---|---|
| 全部 `PASS` | `group accept`（还需要证据引用与授权引用） |
| 有 `FAIL` 且在预算内 | `group repair` → `group start` → **重新审查** |
| 有 `FAIL` 但预算为 0/用尽 | 停下来问人：新组（计划修订）还是外部收口 |
| 有 `NOT_VERIFIED` | 逐条列进交付报告，指定人或说明为何无法自动判定 |
| 结论被拒收 | 看 `details.errors` 逐条改，不要"删掉有问题的条目"重试 |
