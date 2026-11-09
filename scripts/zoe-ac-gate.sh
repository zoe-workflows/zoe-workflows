#!/usr/bin/env bash
# zoe-ac-gate.sh — 合并前的逐条 AC 核对（第二层验收的机械部分）。
#
# 为什么需要它：
#   `pytest 全绿` 回答的是"没崩"，不是"每条 AC 都过了"。manual 项在第一层里没有位置，
#   报告只能写「未记录逐项人工结论」——那句话本身就是一次漏验。本脚本把"逐条 AC 有没有
#   结论、结论是不是当前版本、NOT_VERIFIED 有没有被确认"变成**一个退出码**。
#
# 它核对的**只是第二层**：
#   * 第一层（checks exit code / 证据复算）由 `task report` 与合并门禁前几条负责；
#   * 本脚本不重跑 checks、不改任何状态、不写文件。
#
# 判据（任一不满足即退出码 1）：
#   1. `task review` 覆盖 spec 里每一条 AC（缺一条 = 无效，不是"默认通过"）；
#   2. review 绑定当前 `validated_sha`（旧版本的结论不算）；
#   3. 没有 FAIL；
#   4. NOT_VERIFIED 必须出现在验收请求的 `acknowledged_not_verified` 里，逐条一致；
#   5. `decisions` 里没有 `status=open`（未拍板的裁定阻断验收）；
#   6. 任务处于 `REVIEW_READY` 或 `DONE`。
#
# spec 没声明 `acceptance_review.required` 时输出 `SKIPPED`（**不假装通过**）：它说明
# 这次交付的第二层没有参与验收，汇报必须照抄这句话。
#
# 用法：
#   bash zoe-ac-gate.sh --task TASK [--spec spec.json] [--json]
#
#   --spec   可选。缺省用 `task review` 返回的 criteria（来自冻结 spec）。给了就以文件为准，
#            用于核对"要合并的那份 spec"与任务记录是不是同一份。
#
# 退出码：
#   0  逐条核对通过（或 spec 未要求第二层）
#   1  存在未闭合项（表格里逐条写明）
#   2  用法或依赖错误（缺 jq / 缺 --task / zoe 不可用）
#
# 依赖：jq、可执行的 zoe（ZOE_BIN 覆盖）。macOS 自带 bash 3.2 可跑。

set -u
set -o pipefail

ZOE_BIN=${ZOE_BIN:-zoe}
TASK=""
SPEC=""
JSON_OUT=0

usage() {
    cat >&2 <<'EOF'
用法：bash zoe-ac-gate.sh --task TASK [--spec spec.json] [--json]

逐条核对验收结论（第二层验收）。只读：不重跑 checks、不改状态、不写文件。

  --task TASK   任务 id（必需）
  --spec FILE   spec 文件；缺省用任务冻结 spec 里的 AC 形状
  --json        输出结构化结果（默认输出 Markdown 表格）

退出码：0 通过 / 1 存在未闭合项 / 2 用法或依赖错误。
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --task) TASK=${2:-}; shift 2 ;;
        --spec) SPEC=${2:-}; shift 2 ;;
        --json) JSON_OUT=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "[error] 未知参数：$1" >&2; usage; exit 2 ;;
    esac
done

if [ -z "$TASK" ]; then
    echo "[error] 缺少 --task" >&2
    usage
    exit 2
fi
command -v jq >/dev/null 2>&1 || { echo "[error] 需要 jq" >&2; exit 2; }

ERR_FILE=$(mktemp "${TMPDIR:-/tmp}/zoe-ac-gate.XXXXXX") || exit 2
trap 'rm -f "$ERR_FILE"' EXIT

if ! STATUS=$("$ZOE_BIN" task status "$TASK" 2>"$ERR_FILE"); then
    echo "[error] 读不到任务状态：$(tail -n 3 "$ERR_FILE")" >&2
    exit 2
fi
if ! REVIEW=$("$ZOE_BIN" task review "$TASK" 2>"$ERR_FILE"); then
    echo "[error] 读不到逐条判定：$(tail -n 3 "$ERR_FILE")" >&2
    exit 2
fi

STATE=$(printf '%s' "$STATUS" | jq -r '.state // ""')
SHA=$(printf '%s' "$STATUS" | jq -r '.validated_sha // ""')
REVIEW_STATE=$(printf '%s' "$REVIEW" | jq -r '.state // ""')
REVIEW_SHA=$(printf '%s' "$REVIEW" | jq -r '.review_subject_sha // ""')
DECISION=$(printf '%s' "$STATUS" | jq -r '.acceptance.decision // ""')

# AC 形状：`--spec` 优先（核对"要合的那份"），否则用 `task review` 带回的 criteria。
if [ -n "$SPEC" ]; then
    [ -f "$SPEC" ] || { echo "[error] spec 不存在：$SPEC" >&2; exit 2; }
    ACS=$(jq -r '(.acceptance_criteria // [])[]? | [.id, (.verification.type // "check")] | @tsv' \
        "$SPEC" 2>/dev/null) || {
        echo "[error] spec 不是合法 JSON：$SPEC" >&2
        exit 2
    }
    OPEN_DECISIONS=$(jq -r \
        '(.decisions // [])[]? | select((.status // "open") != "resolved") | .id' \
        "$SPEC" 2>/dev/null)
else
    ACS=$(printf '%s' "$REVIEW" | jq -r '(.criteria // [])[]? | [.id, (.type // "check")] | @tsv')
    OPEN_DECISIONS=$(printf '%s' "$REVIEW" | jq -r '(.open_decisions // [])[]? | .id')
fi

ITEMS=$(printf '%s' "$REVIEW" | jq -r '.items[]? | [.acceptance_id, .status] | @tsv')
ACKED=$(printf '%s' "$STATUS" | jq -r '(.acceptance.acknowledged_not_verified // [])[]?')

lookup_status() {
    printf '%s\n' "$ITEMS" | awk -F'\t' -v id="$1" '$1 == id { print $2; exit }'
}

has_ack() {
    [ -n "$ACKED" ] || return 1
    printf '%s\n' "$ACKED" | grep -Fxq "$1"
}

FAIL=0
ROWS=""
NOTE=""

add_row() {
    # add_row <ac> <type> <verdict> <note>
    ROWS="${ROWS}${1}	${2}	${3}	${4}
"
    case "$3" in
        FAIL|MISSING|STALE) FAIL=1 ;;
    esac
}

case "$STATE" in
    REVIEW_READY|DONE) : ;;
    *) add_row "-" "-" "FAIL" "任务状态是 ${STATE:-unknown}，不是 REVIEW_READY/DONE" ;;
esac

if [ -n "$SHA" ] && [ -n "$REVIEW_SHA" ] && [ "$SHA" != "$REVIEW_SHA" ]; then
    add_row "-" "-" "STALE" "判定绑定 ${REVIEW_SHA:0:12}，当前候选 ${SHA:0:12}"
fi

if [ "$REVIEW_STATE" = "NOT_REQUIRED" ]; then
    NOTE="spec 未声明 acceptance_review.required：第二层未参与验收（不得写成\"已逐条判定\"）"
    if [ "$JSON_OUT" -eq 0 ]; then
        printf '## 逐条 AC 核对\n\n- 任务：%s\n- 结论：**SKIPPED**\n- %s\n' "$TASK" "$NOTE"
    else
        jq -n --arg task "$TASK" --arg note "$NOTE" \
            '{task_id: $task, verdict: "SKIPPED", reason: $note, items: []}'
    fi
    exit 0
fi

if [ -z "$ACS" ]; then
    add_row "-" "-" "FAIL" "读不到 AC 列表（spec 无 acceptance_criteria）"
fi

while IFS=$'\t' read -r AC_ID AC_TYPE; do
    [ -n "$AC_ID" ] || continue
    ST=$(lookup_status "$AC_ID")
    case "$ST" in
        PASS)
            add_row "$AC_ID" "$AC_TYPE" "PASS" "review 判定通过"
            ;;
        NOT_VERIFIED)
            if has_ack "$AC_ID"; then
                add_row "$AC_ID" "$AC_TYPE" "ACK" "NOT_VERIFIED，已在验收请求里确认"
            else
                add_row "$AC_ID" "$AC_TYPE" "FAIL" "NOT_VERIFIED 且未被 acknowledged_not_verified 确认"
            fi
            ;;
        FAIL)
            add_row "$AC_ID" "$AC_TYPE" "FAIL" "review 判定失败"
            ;;
        "")
            add_row "$AC_ID" "$AC_TYPE" "MISSING" "没有任何判定记录（未记录逐项人工结论）"
            ;;
        *)
            add_row "$AC_ID" "$AC_TYPE" "FAIL" "未知状态 ${ST}"
            ;;
    esac
done <<EOF
$ACS
EOF

if [ -n "$OPEN_DECISIONS" ]; then
    while IFS= read -r DID; do
        [ -n "$DID" ] || continue
        add_row "$DID" "decision" "FAIL" "设计裁定未拍板（accept 会返回 DECISIONS_OPEN）"
    done <<EOF
$OPEN_DECISIONS
EOF
fi

if [ "$JSON_OUT" -eq 0 ]; then
    printf '## 逐条 AC 核对\n\n'
    printf -- '- 任务：%s（state=%s，candidate=%s）\n' "$TASK" "${STATE:-unknown}" "${SHA:0:12}"
    printf -- '- 逐条判定：%s\n' "$REVIEW_STATE"
    if [ -n "$DECISION" ]; then
        printf -- '- 验收记录：%s\n' "$DECISION"
    fi
    printf '\n| AC | 类型 | 结论 | 依据 |\n|---|---|---|---|\n'
    printf '%s' "$ROWS" | while IFS=$'\t' read -r a b c d; do
        [ -n "$a" ] || continue
        printf '| %s | %s | %s | %s |\n' "$a" "$b" "$c" "$d"
    done
    if [ -n "$NOTE" ]; then
        printf '\n- %s\n' "$NOTE"
    fi
    if [ "$FAIL" -eq 0 ]; then
        printf '\n结论：逐条核对通过。\n'
    else
        printf '\n结论：**存在未闭合项**，不得合并、不得写"已完成"。\n'
    fi
else
    printf '%s' "$ROWS" | jq -R -s --arg task "$TASK" --arg state "$STATE" \
        --arg sha "$SHA" --arg review_state "$REVIEW_STATE" --argjson fail "$FAIL" '
        split("\n")
        | map(select(length > 0) | split("\t") | {acceptance_id: .[0], kind: .[1], verdict: .[2], detail: .[3]})
        | {task_id: $task, state: $state, candidate_sha: $sha, review_state: $review_state,
           verdict: (if $fail == 1 then "BLOCKED" else "PASS" end), items: .}'
fi

if [ "$FAIL" -ne 0 ]; then
    exit 1
fi
exit 0
