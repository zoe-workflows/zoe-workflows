# 设计裁定记录（D 类）

裁定是**结论**，不是**改动**。它没有 diff、没有 checks、也没有"跑通了"这种证据，
所以它不能被当成代码任务派发。

## 什么时候用

三个判据，满足任意一条就是裁定：

1. 两个文档/两份代码对同一件事给了不同说法，必须选一个；
2. 选项之间的差别不在实现难易，而在**语义**（R 还是 F、冻结还是演进、复用还是重写）；
3. 判错的后果是"一批 AC 要重写"，而不是"某条测试变红"。

反例（**不是**裁定）：选哪个库、用什么数据结构、要不要加缓存——这些是执行期技术
决定，写进交付报告的「执行期间做出的决定」即可，不需要 owner 拍板。

## 记录形状

```markdown
### D-2 契约冻结方向

- 冲突点：`DEC.md` 说 C2/C3/C4/C7/C9 全部"判 R（保持旧签名）"，而 R-10 黄金算例
  需要 `serve.sh` 走新参数；两者不能同时成立。
- 选项：
  - R：保持旧签名，黄金算例的基线重做（成本：重写 out.json + 2 条 AC）
  - F：新增字段并迁移 3 处调用（成本：改 3 个调用方 + 1 条 AC）
- 建议：F。理由：R-10 是本次唯一端到端算例，为签名让步会让它失去证明力。
- 判错的后果：选 R 且事后反悔 ⇒ R-10 的验收要重做，且 C2 的冻结声明作废。
- 拍板人：<owner>；时间：<YYYY-MM-DD>；结论：F；回写位置：`decisions[1].resolution`
```

结构化版本（spec v3 的 `decisions[]`）：

```json
{
  "id": "D-2",
  "question": "C2 契约冻结判 R 还是 F",
  "options": ["R：保持旧签名，重做黄金算例基线", "F：新增字段并迁移 3 处调用"],
  "recommendation": "F",
  "impact_if_wrong": "选 R 且事后反悔会让 R-10 的验收重做",
  "status": "resolved",
  "resolved_by": "owner",
  "resolution": "F；迁移点在 commits abc123 中完成"
}
```

## 流程（不可跳步）

1. **登记**：写进 spec 的 `decisions`，`status: "open"`。此时任务仍可 create/start——
   实现可以开始，结论不能假定。
2. **派发**：只把**实现**派给 Worker，**不得**把"裁定"本身写成一条 task。worker 的
   交付里不允许出现"我复核后判定……"这类结论；那不是它的角色。
3. **拍板**：由 owner（或 owner 明确授权的角色）给结论。其他人只能给建议。
4. **回写**：`task revise` 把 `status` 改为 `resolved`，填 `resolved_by` / `resolution`。
   改验收标准要另走 `task revise` 的 AC 变更，不要混在同一次修改里。
5. **验收**：`accept` 时若仍有 `open` 项，返回 `DECISIONS_OPEN`（退出码 5），拒绝验收。

## 三条禁令

- **不得**用"先按 A 做，不行再改"绕过：那不是裁定，是把风险推给验收阶段。
- **不得**在 `acceptance` 请求里口头带上结论：`decisions` 之外的结论没有归属，
  下一个人读到的是一句无法追溯的话。
- **不得**让 worker 修改冻结的裁定文件（`docs/DEC.md` 之类）：把它放进项目
  `protected_paths`，worker 一碰就 `SCOPE_VIOLATION`，该 run 不产出 candidate。

## 与「待决问题」的区别

| | `open_questions` | `decisions` |
|---|---|---|
| 含义 | 实现无法开始 | 实现能开始，结论未定 |
| create | 阻断（`SPEC_CLARIFICATION_REQUIRED`） | 不阻断 |
| accept | — | 阻断（`DECISIONS_OPEN`） |
| 谁写 | 任何 | `resolved` 只能由 owner 写 |

分不清时问一句：**"现在能不能开工？"** 不能 → 待决问题；能，但做完也不知道算不算对
→ 裁定。
