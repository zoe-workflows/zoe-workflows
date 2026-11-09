# 任务交付：{{title}}

- Task / Spec revision：`task-…` / rev N
- Run / attempt：`run-…` / N
- Candidate / Evidence：`sha` / `ev-…`（本 run 无证据时写 `none (this run)`）
- State / Phase：
- 执行工具与版本（adapter / backend / trust_level）：
- Branch / Diff：`zoe/task-…` / `files changed`
- Started / Ended：`…` / `…`（来源: observed；只有 `reconciled_at` 时写
  `Ended: unknown` 并另列 `Reconciled at`，不计算耗时）
- Verification scope：全量 N/M 或 显式范围 N/M（未执行: …）
- Project-wide verification：PASS / **NOT_RUN**

| 验收项 | 结论 | 依据 |
|---|---|---|
| AC-001 | PASS / FAIL / NOT_VERIFIED / INVALID / 无本期证据 / 未记录逐项人工结论 | `check <id> exit <code>`；manual 项写 `review:<判者> @<sha>` + `evidence_refs` |

表后两行是机器事实，宿主只能转述、不能改写：

- 逐条判定：`<verdict>`（`<state>`；判者 `<actor>`；独立上下文 / 未声明独立上下文）
- 覆盖账本：`cleared=true|false`（声明 N / 闭环 n / 待验收 p / 无任务 m）

出现「未记录逐项人工结论」不是排版问题，是**第二层验收没做**：补 `task review` 后重出报告。
`NOT_VERIFIED` 必须逐条列进「需要人工验证的事项」，不得并入 PASS。

## 检查明细

| check | 状态 | exit | 日志 |
|---|---|---|---|
| lint | PASS | 0 | `runs/<run>/check-lint.log` |

## 阻断与未完成

- 阻塞码 / 失败 check / 未执行 check（`NOT_RUN` 附原因）

## 执行配置

```text
执行配置：<profile id>
选择方式：项目默认（routing.mode=explicit）/ rule_preference（task_type=... 的 prefer[0]）/ requested
模型：显式指定 <model-id>；报告值 <reported or 未上报>
授权：confirmed（policy_hash 前四后四）/ legacy_config_is_authorization
```

自动选择时补一行 `选择原因`，取值只能来自 `route_reason` 的固定枚举（`requested` /
`project_default` / `only_eligible` / `rule_preference` / `catch_all_preference` /
`fallback_default`），不得自创说法。`model_unresolved=true` 时写"运行模型未解析"，不写"已固定"。

## 执行期间做出的决定

原 Spec 未覆盖、执行时必须拍板的技术决定（换了实现方式、加了依赖、调整了顺序、缩小了范围）。
逐条写：决定 / 原因 / 影响范围 / 是否已走 `task revise` 补进合同。没有就写「无」。

这部分不是编排层决策（派谁、为什么还没派），是本 run 实际改了什么判断——人回来第一个要看的就是它。

## 需要人工验证的事项

无法自动化、必须由人确认的项。逐条给到能直接照做的步骤与预期结果：

- [ ] <检查什么> — 步骤：<命令 / 操作> — 预期：<结果> — 判者：<人 / profile；未判写 pending>

`verification.type=manual` 的自审项与集成场景在这里收口；没有独立判者的一律写 `pending`，
不得因为「执行者认为没问题」记为通过。

## 交付边界声明

- 执行器 `trust_level` 非 verified 时：不得表述为「已验证」。
- 项目级验证未执行时：`NOT_RUN`，合并门禁由 CI/PR 负责。
- 合并与验收未由控制器执行；accepted ≠ 已上线。
- **过程观察不是证据**：`[log]` / `kind=text` / `kind=tool`（`task logs` 或监控的
  `--with-log`）只说明 Agent 报告了什么、调用了什么工具。不得把「它说改了 X」「它调了
  Edit」写成 PASS、已修复或已验证；结论只能来自 check 结果、验证证据与人工判定。
- 日志静默、`quiet_seconds` 变大、`progress` 无增长都不是"卡死"，也不是失败。

`zoe task report --format markdown` 输出的是上面机器事实那几节（元信息、AC 表、检查明细、
阻断）；「执行期间做出的决定」「需要人工验证的事项」「交付边界声明」由宿主按本节结构补写，
**不得覆盖或改写机器事实**。

`--write` 落盘为 `delivery-<spec_revision>.md`（不复用 `report.md`，那是
`task summary submit` 的进度视图）。

## 轻量任务的一句话结果（宿主自拟，不改机器事实）

目标明确、单任务、改动集中的轻量交付不需要把上面全部章节摊开给用户，但**信息不能少**，
只是排版更短：

> 已更新 README 安装命令。仅修改 `README.md`，目标文本核对通过；项目级检查
> `unit` PASS，`lint` 未执行（`NOT_RUN`，本次未声明）。任务 `task-…`。

失败时同样一句：

> 未完成：`verify` 阶段 `unit` FAIL（exit 1，`check-unit.log`）；实现尝试还剩 1 次。
> 下一步：修 `src/a.py` 后 `task resume`；范围未变，无需 `revise`。

三条硬约束（沿用上面的规则）：

- **不得省略** `NOT_RUN`、未验证项、`trust_level` 非 verified 的声明；短的是排版，不是内容。
- **不得把机器事实改写成"通过"**：`status=succeeded`、`accepted=true` 都不等于验收通过。
- 一句话结果里出现的每个结论都要能在 `task report` 的机器事实里找到对应行。
