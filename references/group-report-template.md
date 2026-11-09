# 任务组交付报告模板

`group report GROUP` 生成的结构固定七段（顺序不可调换）。宿主转述时保留段落与结论，不要
合并成"已完成"三句话。下面给出每段要回答的问题与常见错写。

## 0. 头部

```text
组：<group_id> ｜ 状态：<state> ｜ 版本：<revision>
计划摘要：<plan_digest 前 12 位>
设计清单：<design_digest 前 12 位>
基线 → 集成：<base_sha 前 12 位> → <integration_sha 前 12 位>
设计一致性审查：<review.state>（参与验收：<是/否>）
```

`review.state` 有七种，含义不同，**不能压缩成"通过/未通过"两档**：
`NOT_REQUIRED`（计划没启用这一层）、`NOT_RUN`（还没做）、`STALE`（只有旧版本结论）、
`INVALID`（上次提交无效）、`PASS`、`NOT_VERIFIED`、`FAIL`。
只有 `NOT_REQUIRED` 和 `PASS` 能出现在"已验收"的语境里，且 `NOT_REQUIRED` 必须同时说明
「本层未参与验收」。

## 1. 需求覆盖（结构覆盖，非语义验证）+ 设计一致性审查

| REQ | 成员 | AC | 成员状态 |
|---|---|---|---|

- 回答：「每条需求由谁实现、对到哪些 AC、现在走到哪」。
- **错写**：把这张表当成"需求已满足"。它是**结构覆盖**，语义证据只来自 check 型 AC 的实际
  执行结果，以及绑定本次 `integration_sha` 的审查结论。没有成员覆盖的需求写「覆盖缺失」，
  不要删行。

紧接着是审查的逐条结论（`group report --format json` 的 `review.items`）：

| AC | 结论 | 说明 | 位置 | 证据 |
|---|---|---|---|---|

- `FAIL` 项必须写清 finding 与建议动作；`NOT_VERIFIED` 项必须单列「未验证项（不计入通过）」。
- 审查状态为 `STALE` 时**不得**引用上一版的条目——那份结论已经不是这次交付的结论。

## 2. 成员与执行组合

| 成员 | 状态 | profile | combination</br> | CLI | auth_mode |
|---|---|---|---|---|---|

- 修复单元（`repair-*`）也在这一节，标注它对应的 finding（`parent_acceptance_id`）与
  影响成员；不要把它藏起来当成普通成员，也不要漏报它消耗的启动额度。
- 回答：「谁在什么样的执行组合里干的」。
- `auth_mode` 为 `unknown` 时写「认证态未知」；`cli_login` 的 `login_state` 未通过
  `agent probe` 证明时同样写未知，不要写「已登录」。
- `unverified` / `trust_level` 原样保留。

## 3. SHA 链

- base、每个成员的 `validated_sha` / `integrated_sha`、最终 `integration_sha`。
- 回答：「验收的是哪一份字节」。
- 成员 `integrated_sha` 为空 = 未交付；不要用"已合过"之类的表述代替 SHA。

## 4. 组级检查明细

| check | 状态 | exit | 日志 |
|---|---|---|---|

- 回答：「组级门禁在**这个** SHA 上跑过什么、结果如何」。
- 没有记录就写「未在该 SHA 上执行」，不要写"通过"。
- `NOT_RUN` 与另一个 SHA 的通过记录都**不算**通过，必须显式说明。

## 5. 阻塞历史与最小必要决策

- 每条阻塞：成员、`code`、原因、需要谁做什么。
- 验收被拒绝时列出 `rejections`（原因 + 决定人）。
- 回答：「如果现在卡住，卡在哪、要谁拍板」。只写必要的决策，不要罗列所有历史事件。

## 6. 预算与时间

- 计费启动额度：`starts_billable / max_starts`（含已预留、已释放及其依据）。
- 实际 Agent 进程启动数：以每个 run 的 `pid` / `launch_stage` 为证据。
- 墙钟时长（**含机器休眠与等待**）/ 上限（未设就写"未设时长上限"）。
- 组级修复轮数：`repairs_total / max_group_repairs`；上限为 0 时写「本计划未授权修复」，
  不要写成"修复次数为 0 所以很干净"。

**错写**：把"计费启动额度"当成"跑了几次"，或把墙钟时长当成"Agent 实际工作时长"。

## 7. 交付边界声明

至少回答：

- 无沙箱：`local-process` 以本机账户运行，`allowed_paths` 提供问责而非预防。
- 设计一致性审查：写真实状态 + 一句"这一层是否参与验收"；`NOT_REQUIRED` 与 `NOT_VERIFIED`
  都不等于通过。
- PR 组不支持；外部收口（`group cancel --external`）写 `external_close`，`accepted:false`。
- 未运行项：列出 `NOT_RUN` 的检查与 `NOT_VERIFIED` 的 AC。
- 成员任务保持 `REVIEW_READY`，由组统一收口。

## 收尾句式

结论只能落在四档之一，并写清依据：

| 结论 | 依据 |
|---|---|
| 已验收交付 | `group accept` 返回 `accepted: true` 且 `state=DONE` |
| 可验收未验收 | `state=REVIEW_READY`，组级检查在当前 SHA 全 PASS，且（要求时）审查无 `FAIL` |
| 未完成 | 仍有 READY/EXECUTING/WAITING 成员，或存在阻塞（含 `DESIGN_REVIEW_FAILED`） |
| 交付在 Zoe 之外 | `external_close` 存在；`accepted:false`，**不是**验收结论 |

不要写「应该没问题」「看起来跑通了」——Zoe 的结论只有记录，没有语气。
