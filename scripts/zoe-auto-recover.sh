#!/usr/bin/env bash
# zoe-auto-recover.sh — 按 block_code 给出恢复动作（默认只建议，--apply 才执行）。
#
# 为什么不是"一律 resume"：
#   resume 一个前置条件没解决的任务，只是把同一段失败重放一遍，还多烧一次预算。
#   真正该做的是**先看码**：限流可以续、缺输入必须先答、基线漂了要重派。
#
# 边界：
#   * 默认**只读**：打印建议命令与理由，不执行任何写操作；
#   * `--apply` 只执行 auto 档（`AGENT_RATE_LIMITED` / `RUN_TIMEOUT`）的 resume；
#     它们工作区保留、可重放，失败也只是再 BLOCKED 一次；
#   * 其它档位一律只打印——`task revise` / `task recover` / `quota clear` 都带
#     前置条件，脚本猜错会把"该人工介入"变成"又跑一遍"。
#
# 用法：
#   bash zoe-auto-recover.sh TASK [--apply] [--json]
#
# 退出码：0 有可直接执行的动作 / 1 需要人工 / 2 用法或依赖错误。
#
# 码表见 references/block-codes.md；新增码时两边一起改。

set -u
set -o pipefail

ZOE_BIN=${ZOE_BIN:-zoe}
TASK=""
APPLY=0
JSON_OUT=0

usage() {
    cat >&2 <<'EOF'
用法：bash zoe-auto-recover.sh TASK [--apply] [--json]

按 block_code 给出恢复动作。默认只打印建议，--apply 只执行 auto 档的 resume。

  TASK      任务 id（位置参数）
  --apply   执行 auto 档动作（目前仅 AGENT_RATE_LIMITED / RUN_TIMEOUT 的 resume）
  --json    输出结构化结果

退出码：0 有可直接执行的动作 / 1 需要人工 / 2 用法或依赖错误。
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --apply) APPLY=1; shift ;;
        --json) JSON_OUT=1; shift ;;
        -h|--help) usage; exit 0 ;;
        --*) echo "[error] 未知参数：$1" >&2; usage; exit 2 ;;
        *)
            if [ -n "$TASK" ]; then
                echo "[error] 多余的参数：$1" >&2
                usage
                exit 2
            fi
            TASK=$1
            shift
            ;;
    esac
done

[ -n "$TASK" ] || { echo "[error] 缺少 TASK" >&2; usage; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "[error] 需要 jq" >&2; exit 2; }

ERR_FILE=$(mktemp "${TMPDIR:-/tmp}/zoe-auto-recover.XXXXXX") || exit 2
trap 'rm -f "$ERR_FILE"' EXIT

if ! STATUS=$("$ZOE_BIN" task status "$TASK" 2>"$ERR_FILE"); then
    echo "[error] 读不到任务状态：$(tail -n 3 "$ERR_FILE")" >&2
    exit 2
fi

STATE=$(printf '%s' "$STATUS" | jq -r '.state // ""')
CODE=$(printf '%s' "$STATUS" | jq -r '.block_code // ""')
PROJECT=$(printf '%s' "$STATUS" | jq -r '.project_id // ""')
LAST_ERROR=$(printf '%s' "$STATUS" | jq -r '.last_error // ""' | head -c 400)
RESET_AT=$(printf '%s' "$STATUS" | jq -r '.block_details.quota_reset_at // .quota_reset_at // ""')

KIND=""
REASON=""
COMMAND=""
NOTE=""

if [ "$STATE" = "DONE" ]; then
    KIND=none
    REASON="任务已验收，没有需要恢复的东西"
elif [ "$STATE" != "BLOCKED" ]; then
    KIND=none
    REASON="任务当前是 ${STATE:-unknown}，不是 BLOCKED；先看 task status 再决定"
else
    case "$CODE" in
        AGENT_RATE_LIMITED)
            KIND=auto
            COMMAND="$ZOE_BIN task resume $TASK"
            REASON="上游限流。工作区保留，等几分钟后可以续跑"
            NOTE="若仍在限流窗口内，会再次 BLOCKED；不会丢已有工作区"
            ;;
        RUN_TIMEOUT)
            KIND=auto
            COMMAND="$ZOE_BIN task resume $TASK"
            REASON="本次 run 超时。同一 run 只允许一次续跑"
            NOTE="再超时就该改计划拆小任务（task revise），不是继续 resume"
            ;;
        CI_PENDING)
            KIND=human
            COMMAND="$ZOE_BIN task status $TASK"
            REASON="远端检查还没出结果。**不要 resume**，刷新状态等 CI 落地"
            ;;
        RETRY_EXHAUSTED)
            KIND=human
            REASON="自动重试已用尽。按 last_error 改计划，重试只会重复同一个失败"
            ;;
        INPUT_REQUIRED)
            KIND=human
            COMMAND="$ZOE_BIN task answer $TASK --request-file answer.json"
            REASON="worker 在等一个答案。**先答再 resume**，否则新 run 会在没有答案的情况下重跑"
            ;;
        SPEC_CLARIFICATION_REQUIRED|POLICY_CHANGED)
            KIND=human
            COMMAND="$ZOE_BIN task revise $TASK --request-file revise.json"
            REASON="spec/策略需要改，不是重跑"
            ;;
        DECISIONS_OPEN)
            KIND=human
            COMMAND="$ZOE_BIN task revise $TASK --request-file revise.json"
            REASON="设计裁定未拍板。由 owner 给结论后回写 decisions[].status=resolved"
            ;;
        SCOPE_VIOLATION)
            KIND=human
            COMMAND="bash $(dirname "$0")/zoe-revise-scope.sh $TASK"
            REASON="改动超出 allowed_paths。放宽范围要人确认，且只放宽必要的路径"
            ;;
        ALLOWLIST_UNCONFIRMED)
            KIND=human
            REASON="授权未确认。按 task attest 流程确认（范围可以比白名单更窄）"
            ;;
        POLICY_DENIED)
            KIND=human
            REASON="策略不允许这个操作。改操作或改策略，重试没有意义"
            ;;
        AGENT_PERMISSION_DENIED|AGENT_AUTH_REQUIRED)
            KIND=human
            COMMAND="$ZOE_BIN task resume $TASK"
            REASON="执行器权限/登录失效。修好授权后再 resume（工作区保留）"
            ;;
        ACCEPTANCE_UNREVIEWED|ACCEPTANCE_UNACKNOWLEDGED)
            KIND=human
            COMMAND="$ZOE_BIN task review $TASK"
            REASON="逐条判定缺失或未确认。补判定；NOT_VERIFIED 要逐条 ack"
            ;;
        ACCEPTANCE_REVIEW_FAILED)
            KIND=rework
            REASON="判定有 FAIL。修实现 → 重新 verify → 重新判定，不要改判定'变绿'"
            ;;
        ACCEPTANCE_REJECTED)
            KIND=rework
            REASON="人明确拒收。按拒绝理由改，不要 resume"
            ;;
        DEPENDENCY_NOT_MET|DEPENDENCY_BLOCKED)
            KIND=human
            COMMAND="$ZOE_BIN task graph --project ${PROJECT:-<P>} --format markdown"
            REASON="上游需求未闭环。去推上游；resume 还会被同一个门禁拒掉"
            ;;
        PROGRESS_NOT_TICKED)
            KIND=rework
            REASON="需求文档复选框没勾。把勾选作为交付物一起提交，不要另起一次 run 补"
            ;;
        PROCESS_UNKNOWN)
            KIND=human
            COMMAND="$ZOE_BIN task recover $TASK --confirm-stop"
            REASON="进程域无法核对。先拿到'旧执行已停止'的依据，再决定从哪个阶段 resume"
            ;;
        RUN_INTERRUPTED)
            KIND=human
            COMMAND="$ZOE_BIN task recover $TASK --confirm-stop"
            REASON="被中断收口。先 recover，再按阶段 resume"
            ;;
        WORKSPACE_CHANGED|BASE_DRIFT|REMOTE_DRIFT|STALE_CHECKS)
            KIND=rework
            REASON="候选/基线/证据已经不可信。重冻结基线后重派，不是续跑"
            ;;
        VALIDATION_FAILED)
            KIND=rework
            REASON="独立检查失败。先修实现；直接 resume 会重复同一段失败"
            ;;
        OUTPUT_LIMIT_EXCEEDED|PROMPT_TOO_LARGE)
            KIND=rework
            REASON="上下文或输出撑爆。拆小任务或收紧 spec"
            ;;
        AGENT_FAILED|AGENT_RESULT_INVALID)
            KIND=rework
            REASON="执行器失败或输出不合契约。读 last_error 定位；同一输入重试没有新信息"
            ;;
        ENVIRONMENT_ERROR|ENVIRONMENT_DRIFT|ADAPTER_VERSION_MISMATCH)
            KIND=rework
            COMMAND="$ZOE_BIN doctor"
            REASON="环境/适配器不匹配。先修环境，否则下一次还是同一个错"
            ;;
        QUOTA_EXHAUSTED|SPEND_LIMIT_EXCEEDED|SPEND_UNVERIFIABLE)
            KIND=stop
            COMMAND="zoe project quota clear --project ${PROJECT:-<P>} --why <原因>"
            REASON="项目级额度/花费事实。先停所有新派发"
            if [ -n "$RESET_AT" ]; then
                NOTE="重置时间：$RESET_AT"
            fi
            ;;
        CLOSED_EXTERNAL)
            KIND=none
            REASON="交付在 Zoe 之外发生。这是对账，不是验收结论，不计入 DONE"
            ;;
        "")
            KIND=human
            REASON="BLOCKED 但没有 block_code（旧记录或手工改过的行）。看 last_error"
            ;;
        *)
            KIND=human
            REASON="未登记的阻断码。读 last_error 后手工判定，并把它补进 block-codes.md"
            ;;
    esac
fi

ACTION="none"
if [ "$APPLY" -eq 1 ]; then
    if [ "$KIND" = "auto" ] && [ -n "$COMMAND" ]; then
        ACTION="executed"
        if [ "$JSON_OUT" -eq 0 ]; then
            printf '[apply] %s\n' "$COMMAND"
        fi
        # 只执行 auto 档的 resume：幂等、工作区保留、失败也只是再 BLOCKED 一次。
        if ! $COMMAND >/dev/null 2>"$ERR_FILE"; then
            ACTION="failed"
            if [ "$JSON_OUT" -eq 0 ]; then
                printf '[apply] 失败：%s\n' "$(tail -n 3 "$ERR_FILE")" >&2
            fi
        fi
    elif [ "$KIND" != "none" ]; then
        ACTION="refused"
        if [ "$JSON_OUT" -eq 0 ]; then
            printf '[apply] 拒绝自动执行（%s 档需要人处理）\n' "$KIND" >&2
        fi
    fi
fi

if [ "$JSON_OUT" -eq 1 ]; then
    jq -n \
        --arg task "$TASK" \
        --arg state "$STATE" \
        --arg code "$CODE" \
        --arg kind "$KIND" \
        --arg reason "$REASON" \
        --arg command "$COMMAND" \
        --arg note "$NOTE" \
        --arg last_error "$LAST_ERROR" \
        --arg action "$ACTION" \
        '{task_id: $task, state: $state, block_code: $code, kind: $kind,
          reason: $reason, command: (if $command == "" then null else $command end),
          note: (if $note == "" then null else $note end),
          last_error: (if $last_error == "" then null else $last_error end),
          apply: $action}'
else
    printf '## 恢复建议\n\n'
    printf -- '- 任务：%s（state=%s）\n' "$TASK" "${STATE:-unknown}"
    printf -- '- 阻断码：%s\n' "${CODE:-（无）}"
    printf -- '- 档位：%s\n' "$KIND"
    printf -- '- 动作：%s\n' "$REASON"
    if [ -n "$COMMAND" ]; then
        printf -- '- 命令：`%s`\n' "$COMMAND"
    fi
    if [ -n "$NOTE" ]; then
        printf -- '- 注意：%s\n' "$NOTE"
    fi
    if [ -n "$LAST_ERROR" ]; then
        printf -- '- last_error：%s\n' "$LAST_ERROR"
    fi
fi

case "$KIND" in
    auto) exit 0 ;;
    none) exit 0 ;;
    *) exit 1 ;;
esac
