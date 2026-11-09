# 交付判定

独立验证优先于 Worker 自测和文字声明。required 检查绑定当前提交/工作区指纹；
记录命令、退出码、证据与时间。Agent 修改验证脚本或减少测试时应提示人工审查。
验证由受限执行环境运行，不带发布凭据。

- PASS：对应版本确已执行并符合标准。
- FAIL：断言/门禁失败，包括被超时/进程消失打断的断言（带 `error.code`）。
- NOT_RUN：本次**未声明执行**（不在 spec 的 `verification_scope` 内）。
- WAIVED：有真实人工授权和适用版本的豁免，Agent 不能自行填写。

`verification.type=manual` 的条目（自审项、集成场景）必须记录判者，且判者不能是产生该改动的
同一个上下文：执行者自己写「我看过了」不算通过，按 `NOT_RUN` 记，并在报告里写 `pending`。

## 两层验收，缺一层就不叫验收

| 层 | 谁执行 | 回答什么 | 记录位置 |
|---|---|---|---|
| 第一层 checks | 控制器 | 声明的检查都跑过且通过吗？ | `validation.json` / `evidence/<id>.json` |
| 第二层逐条判定 | 独立上下文的判者（人或另一个 profile） | 每条 AC 到底过没过？依据是什么？ | `reviews/<validated_sha>.json` |

第一层的 PASS **只回答"没崩"**：一条 manual AC 在第一层里没有位置，报告会老实写
「未记录逐项人工结论」。第二层才是"需求闭环"的答案。

- spec 声明 `acceptance_review.required` 时，`accept` 强制要求第二层（`ACCEPTANCE_UNREVIEWED`）；
- 判者与 candidate 产生者是同一 profile / 同一 run / 同一 actor ⇒ `SELF_REVIEW`，整份判定无效；
- `NOT_VERIFIED` 不阻断，但必须在验收请求里 `acknowledged_not_verified` 逐条确认
  （`ACCEPTANCE_UNACKNOWLEDGED`）；
- `FAIL` 阻断（`ACCEPTANCE_REVIEW_FAILED`）：修实现后重新 verify 再判，不改判定"变绿"。

`task report` 的验收项表会把两层并列：check 型 AC 给 exit code，manual 型 AC 给
`reviewer` + `evidence_refs`。表里出现「未记录逐项人工结论」就是第二层没做。

## 进度是交付物，不是收尾动作

`progress_refs` 声明的文档复选框在 verify 阶段被检查：marker 所在行必须是 `- [x]`，
否则 `PROGRESS_NOT_TICKED`，该 run 不产出 candidate。

- 把需求文档写进 `allowed_paths`（否则 `prepare` 报 `PROGRESS_REF_OUT_OF_SCOPE`，阻断）；
- 不要让 Worker 在任务之外"顺手"改文档：那是候选之外的改动，下一次 verify 会被
  工作区指纹打回；
- 覆盖关系只能由 `task coverage` 汇总，不能由编排者推断编号映射。

`NOT_RUN` 不是通过，也不是失败：它既不能记作「已验证」，也不能用来解释「为什么没报错」。
交付时必须同时说明两件事——**本任务验证了什么**（声明的 checks）与**项目级验证是否执行**
（`Project-wide verification`）。声明了范围的任务，合并门禁必须另跑全量：

- 任务级：只对 `verification_scope` 内的 checks 负责；
- 合并级：合并前的全量 checks 由 CI/PR 门禁执行，不由任务自己声明「已覆盖」；
- 报告中出现 `NOT_RUN` 的 check，不得在验收结论里写成「通过」。

## 合并门禁（无 CI 时）

`local_artifact` + `ci_required=false` 的项目**没有** CI 门禁，"合并级由 CI 执行"这句话对它
不成立。这类项目的合并门禁由编排会话执行，且不可省略：

1. 一次只合一个候选，**合完立刻跑全量 checks**（不是全部合完再跑一次）；
2. 跑在**集成分支**上，不是各任务的 worktree；
3. 记录 `integration_sha` + 每个 check 的 `exit_code` + 日志路径；
4. 任一 FAIL ⇒ 停在集成分支，不进主干。修实现，或由人确认这确实是契约变更并同时更新测试；
   "改测试让它变绿"不是通过；
5. 报告写「项目级验证已执行」或「未执行」，不写"应该没问题"；
6. 逐条 AC 核对：`bash <skill-dir>/scripts/zoe-ac-gate.sh --spec <spec.json> --report
   <report.json>` 退出码 0。它把「未记录逐项人工结论」「NOT_VERIFIED 未确认」「无本期
   证据」都算失败——这几种情形的共同点是**看不出来做没做**，而不是"看起来没问题"；
7. 清单清零看 `zoe task coverage --markers-file <需求清单>` 的 `cleared`。它是唯一判据：
   自己推断的编号映射（"这批 WP 应该覆盖了 R-01~R-13"）不是证据。

合之前先看任务记录里的 `concurrent_base`（v1.6），它把"要不要重验"从直觉变成事实：

```bash
zoe task status T --json | jq '{kind: .concurrent_base.kind, behind: .concurrent_base.behind_by,
                                overlap: .concurrent_base.overlapping_paths,
                                reverts: .concurrent_base.reverts_merged_work}'
```

- `kind=overlap` ⇒ 合并后**必须重跑全量**（第 1 条不能省，也不许复用候选自己的验证证据）；
- `kind=reverts` ⇒ 候选删掉了别人刚改过的文件，停：这不是冲突，是**丢改动**，交人判断；
- `kind=base_advanced` ⇒ 正常落后，照常合；
- 想看"这个候选会不会删掉已合入的代码"，用 `git diff --stat <base_sha>..<cand>`，
  **不要**用 `git diff --stat HEAD..<cand>`：后者拿当前 HEAD 比，会把"还没跟上"显示成
  "在删代码"，据此 abort 重派等于把 10 分钟的白工当成正确处置（真实批次里发生过三次）。

共享同一处行为契约的多片（同一个接口签名、同一张注册表）必须按**任务组**交付：
`group accept` 会在 `integration_sha` 上跑组 checks。独立任务并行 + 手工合并没有这一层。
排波次前先看重叠：`zoe task digest --project P --targets "T1 T2 T3" --json | jq .hot_paths`
里任一路径计数 ≥ 2 的，不要同波派发（或改走任务组）。

## 空候选

`candidate_sha == base_sha` 表示这次**没有任何可交付改动**（worker 零提交）。它仍然能走到
`REVIEW_READY`，`accept` 也能通过（`subject_sha` 与 `validated_sha` 都等于 `base_sha`）——
那是运行时的空洞，不是授权。

- 汇报不得写「已完成」：证据里那些 PASS 只说明**基线**本来就能过；
- 监控会打印 `[needs-human] T empty_diff=true` 并写进 `--stop-file` 的 `empty_candidates`；
- 处置是**重新派发**（补 spec / 换 profile / 缩小范围），不是 `accept`；
- 例外只有一种：spec 明确写了"本次只做验证/只补证据/无代码改动"，此时要在验收结论里写出
  这句话，并说明它交付的是什么（结论、证据或报告），而不是"改完了"。

重复请求不是新派发：同 `request_id` 的重放返回已有记录或 `dispatch_pending`，不产生新的
Run、不增加 `row_version`、不写事件；不得把重放响应当作「又启动了一次」或「正在运行」。
证据只对生成它的 run 有效，新 run 没有证据时报告写 `Evidence: none (this run)`，
不得沿用上一个 run 的 PASS。

CI 查询须核对当前 PR head，空检查不当成通过。明确 ci_required=false 才可在无 CI
情况下评审，并显示“未配置 CI”。PR 存在、已合并、用户认可、已上线分别记录。

pull_request 模式只有已确认合并且用户验收 accepted 才 DONE；local_artifact 模式需
产物可引用且用户验收 accepted。不从“谢谢”或 Agent 的完成说明推断正式验收。
需求不包含发布时不报告上线；用户提供发布证据时注明来源。

PR 发布由 CLI 独占 commit/push/创建更新操作；超时先对账，不由 Skill 直接 gh 重发。
远端任务分支漂移不自动强推；多 PR 候选不猜。Spec 敏感时写脱敏验收摘要，
不把本机路径伪装成可访问链接，不向 PR 泄漏客户原文。

输出使用 report-template；状态无实时证据时标“最后已知”和时间。
