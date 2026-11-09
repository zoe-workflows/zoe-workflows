#!/usr/bin/env bash
# zoe-digest.sh — 一命令输出整批任务的"状态 + 内容"视图（默认写 Markdown）。
#
# 为什么需要它（而不是每次手拼 N 条命令）：
#   一版可读摘要原本需要 N 次 `task status` + N 次 `task logs`，宿主只能一条条发、
#   一条条读，于是汇报退化成"只报状态、不报内容"。本脚本把这件事压成**一次进程**。
#
# 成本要如实说（`--debug-calls` 会打印实际次数）：
#   * runtime ≥ 1.6：走 `task digest` 原生聚合，**1 次**调用；
#   * runtime < 1.6：自动回退到逐任务读取，**1 + 2N 次**（N 个目标，`--no-content` 时 1+N）。
#   回退路径不是降级告警——功能一样，只是慢一点。
#
# 三条边界（与 SKILL 第 6 步同语义，写在这里避免误用）：
#   1. **不判断终态**：输出里没有"已完成 / 失败 / 通过"这类结论。任务是否结束只看
#      `state`，是否可交付只看 `task report` 与验收记录。digest 只做事实聚合。
#   2. **不复制 runtime 的判断**：`REVIEW_READY` / `SCOPE_VIOLATION` / `empty_candidate`
#      原样转述字段，不重新解释、不推断"卡住"。
#   3. **不改任何状态**：只读 `task status` 与 `task logs`，不写状态库、不推进任务。
#      `--out` 只写调用方指定的 Markdown 文件。
#
# 内容行的语义（与 report-template 一致）：
#   `说：…` 是 Agent 的自述，`动：…` 是工具调用。两者都是**过程观察**，不是成功证据。
#
# 用法：
#   bash zoe-digest.sh --project P [--targets "T1 T2" | --targets-file F]
#                      [--out .zoe/P-digest.md] [--tail-bytes 131072] [--lines 2]
#                      [--no-content] [--json] [--debug-calls]
#                      [--since STATE] [--no-update-state]
#
# `--since`（增量视图）：只输出与上次相比**变了**的任务，让"读一版"的成本恒定。
#   * 状态文件由本脚本维护（JSON，按 task 存指纹）；不存在时全部视为变化并写入；
#   * Markdown 模式：无变化时 stdout **为空**（0 行），有变化时只输出变化行；
#   * `--json` 模式：始终输出完整 JSON（`changed[]` 为空表示无变化）——JSON 没有
#     "0 行"这个形态，用空数组合乎契约；
#   * `--since` 与 `--out` 互斥：一个是增量片段，一个是完整快照，混用会让文件含义漂移。
#
# 退出码：
#   0  生成成功（个别任务读不到只告警）
#   2  用法或依赖错误（缺 jq / 缺 --project / 参数越界）
#   11 全部目标都读不到状态（监控面不可用，与 zoe-monitor 的 WATCH_ERROR 同族）
#
# 依赖：jq、可执行的 zoe（ZOE_BIN 覆盖）。macOS 自带 bash 3.2 可跑。

set -u
set -o pipefail

ZOE_BIN=${ZOE_BIN:-zoe}
PROJECT=""
TARGETS=""
TARGETS_FILE=""
OUT=""
TAIL_BYTES=131072
LINES=2
NO_CONTENT=0
JSON_OUT=0
DEBUG_CALLS=0
SINCE=""
UPDATE_STATE=1

CALLS=0
STATUS_OK=0
STATUS_FAIL=0

usage() {
  cat <<'EOF'
用法: zoe-digest.sh --project P [options]

  --project P         项目 ID（必需；目标集合与归属校验都用它）
  --targets "T1 T2"   要汇总的任务 ID，空格分隔（缺省取项目内所有非终态任务）
  --targets-file F    从文件读任务 ID（每行一个，# 开头为注释）
  --out F             同时写入该路径（默认 .zoe/<project>-digest.md；--no-out 关闭）
  --no-out            不写文件，只打印
  --tail-bytes N      每任务日志读取窗口（默认 131072，上限 1048576）
  --lines N           每任务最多几条内容行（默认 2，范围 1..10）
  --no-content        只跑 status，不读日志（任务多或 CLI 慢时降级）
  --json              输出结构化 JSON（含 hot_paths），不输出 Markdown
  --debug-calls       在 stderr 打印实际 CLI 调用次数（验收用）
  --since F           增量模式：只输出与上次相比变化的任务（F 为本脚本维护的状态文件）
  --no-update-state   增量模式下不写回 F（只读比较，用于"看一眼变了什么"）
  -h, --help          显示本帮助

环境变量：ZOE_BIN（默认 zoe）
退出码：0 成功 / 2 用法或依赖 / 11 全部目标状态不可读
提示：本脚本只做事实聚合，不判断任务是否完成；终态只看 state。
      --since 的 Markdown 模式在无变化时输出 0 行；--json 模式输出 changed: []。
EOF
}

log_err() { printf '[warn] %s\n' "$1" >&2; }

die_usage() {
  printf '[error] %s\n' "$1" >&2
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --project) PROJECT=${2:-}; shift 2 ;;
    --targets) TARGETS=${2:-}; shift 2 ;;
    --targets-file) TARGETS_FILE=${2:-}; shift 2 ;;
    --out) OUT=${2:-}; shift 2 ;;
    --no-out) OUT=""; NO_OUT=1; shift ;;
    --tail-bytes) TAIL_BYTES=${2:-}; shift 2 ;;
    --lines) LINES=${2:-}; shift 2 ;;
    --no-content) NO_CONTENT=1; shift ;;
    --json) JSON_OUT=1; shift ;;
    --debug-calls) DEBUG_CALLS=1; shift ;;
    --since) SINCE=${2:-}; shift 2 ;;
    --no-update-state) UPDATE_STATE=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die_usage "unknown argument: $1" ;;
  esac
done

[ -n "$PROJECT" ] || die_usage "--project is required"
case "$TAIL_BYTES" in ''|*[!0-9]*) die_usage "--tail-bytes must be a positive integer" ;; esac
[ "$TAIL_BYTES" -ge 1 ] && [ "$TAIL_BYTES" -le 1048576 ] \
  || die_usage "--tail-bytes must be 1..1048576"
case "$LINES" in ''|*[!0-9]*) die_usage "--lines must be a positive integer" ;; esac
[ "$LINES" -ge 1 ] && [ "$LINES" -le 10 ] || die_usage "--lines must be 1..10"
command -v jq >/dev/null 2>&1 || die_usage "jq is required"
command -v "$ZOE_BIN" >/dev/null 2>&1 || die_usage "zoe not found: $ZOE_BIN"

# --no-out 之前把默认值补上；两者都缺省时写 .zoe/<project>-digest.md。
# --since 是增量片段，--out 是完整快照：混用会让同一个文件时而完整、时而只有几行。
if [ -n "$SINCE" ]; then
  if [ -n "$OUT" ]; then
    die_usage "--since cannot be combined with --out (incremental snippet vs full snapshot)"
  fi
  OUT=""
elif [ -z "${NO_OUT:-}" ] && [ -z "$OUT" ]; then
  OUT=".zoe/${PROJECT}-digest.md"
fi

# 计数包装：所有 CLI 调用都必须走这里，否则 --debug-calls 会少报。
zoe_call() {
  CALLS=$((CALLS + 1))
  "$ZOE_BIN" "$@"
}

TMP=$(mktemp -d 2>/dev/null) || die_usage "cannot create a temp dir"
trap 'rm -rf "$TMP"' EXIT

# 目标集合：显式给定优先；否则取项目内**非终态**任务（历史任务不进 digest）。
if [ -n "$TARGETS_FILE" ]; then
  [ -f "$TARGETS_FILE" ] || die_usage "targets file not found: $TARGETS_FILE"
  from_file=$(sed -e 's/#.*//' "$TARGETS_FILE" | tr '\n' ' ')
  TARGETS="$TARGETS $from_file"
fi
if [ -n "${TARGETS// /}" ]; then
  TARGETS=$(printf '%s\n' $TARGETS | awk 'NF && !seen[$0]++' | tr '\n' ' ')
else
  if ! zoe_call task list --project "$PROJECT" --json >"$TMP/list.json" 2>/dev/null; then
    die_usage "cannot list tasks for project: $PROJECT"
  fi
  TARGETS=$(jq -r '.[] | select(.project_id == $p)
                   | select(.state != "DONE" and .state != "CANCELLED")
                   | .task_id' --arg p "$PROJECT" "$TMP/list.json" 2>/dev/null | tr '\n' ' ')
  [ -n "${TARGETS// /}" ] || die_usage "no active tasks in project: $PROJECT"
fi

NOW=$(date +%s)

# 秒 → 人读时长。只用于展示，不参与任何判定。
human_seconds() {
  local s=${1:-0}
  case "$s" in ''|*[!0-9]*) printf '%s' "-"; return 0 ;; esac
  if [ "$s" -lt 60 ]; then printf '%ss' "$s"
  elif [ "$s" -lt 3600 ]; then printf '%sm' "$((s / 60))"
  else printf '%sh%02dm' "$((s / 3600))" "$(((s % 3600) / 60))"
  fi
}

: >"$TMP/tasks.ndjson"
: >"$TMP/body.md"

# v1.6 原生聚合优先：`task digest` 一次调用拿全，省掉 1+2N 次 fork。
# 旧 runtime 没有这个子命令，静默退回逐任务读取——回退路径的行为与 v1.5 一致，
# 所以"装了旧 runtime"不会变成"digest 不可用"，只会变成"慢一点"。
USED_NATIVE=0
set -- --project "$PROJECT" --tail-bytes "$TAIL_BYTES" --lines "$LINES"
[ "$NO_CONTENT" -eq 1 ] && set -- "$@" --no-content
[ -n "${TARGETS// /}" ] && set -- "$@" --targets "${TARGETS% }"
if zoe_call task digest "$@" >"$TMP/native.json" 2>/dev/null \
   && jq -e '.api_version == 1 and (.tasks | type) == "array"' "$TMP/native.json" >/dev/null 2>&1; then
  USED_NATIVE=1
  jq -c '.tasks[]' "$TMP/native.json" >"$TMP/tasks.ndjson"
  STATUS_OK=$(jq '.tasks | length' "$TMP/native.json")
  # 版式必须与逐任务路径一致，否则"哪条路径生效"会改变汇报的读法。
  jq -r '
    def dur:
      if . == null then "-"
      elif . < 60 then "\(.|floor)s"
      elif . < 3600 then "\((. / 60)|floor)m"
      else "\((. / 3600)|floor)h\(((. % 3600) / 60)|floor|tostring|if length < 2 then "0" + . else . end)m"
      end;
    def kb: if . == null then "-" else "\((. / 1024)|floor)KB" end;
    .tasks[] |
    "- **\(.title // .task_id)** `\(.task_id)` — \(.state // "unknown") · \(.phase // "?") · \(.elapsed_seconds | dur) · 静默 \(.quiet_seconds | dur) · \(.log_bytes | kb)",
    ( if .content_note != null then "  - \(.content_note)"
      else (.content[]? | if .kind == "text" then "  - 说：\(.text)"
                          else "  - 动：\(.name) \(.target)  (过程观察，非成功证据)" end)
      end ),
    ( if .block_code != null then "  - 阻断：`\(.block_code)`" else empty end ),
    ( if .observations_stale == true then "  - 观测已过期（监控进程失联，需重新对账，不是任务失败）" else empty end )
  ' "$TMP/native.json" >"$TMP/body.md"
fi

if [ "$USED_NATIVE" -eq 0 ]; then
for t in $TARGETS; do
  # 1) 权威状态：先 --refresh，旧运行器不认时退回只读（与 monitor 同语义）。
  if zoe_call task status "$t" --json --refresh >"$TMP/status.json" 2>/dev/null; then
    :
  elif zoe_call task status "$t" --json >"$TMP/status.json" 2>/dev/null; then
    :
  else
    STATUS_FAIL=$((STATUS_FAIL + 1))
    log_err "status unreadable: $t"
    continue
  fi
  if ! jq -e . "$TMP/status.json" >/dev/null 2>&1; then
    STATUS_FAIL=$((STATUS_FAIL + 1))
    log_err "status is not JSON: $t"
    continue
  fi
  STATUS_OK=$((STATUS_OK + 1))

  st=$(jq -r '.state // ""' "$TMP/status.json")
  phase=$(jq -r '.phase // ""' "$TMP/status.json")
  block=$(jq -r '.block_code // ""' "$TMP/status.json")
  # 标题按 codepoint 截断（不是字节）：中文标题按字节切会出乱码。
  title=$(jq -r '(.title // "") | .[0:40]' "$TMP/status.json")
  created=$(jq -r '.created_at // 0' "$TMP/status.json")
  scope_source=$(jq -r '.scope_source // ""' "$TMP/status.json")
  empty_cand=$(jq -r 'if .empty_candidate == true then "true" else "false" end' "$TMP/status.json")
  scope_json=$(jq -c 'if (.task_scope // null) == null then null else .task_scope end' "$TMP/status.json")
  # progress 是加法字段：没有 run 时整块缺失，缺失就写 null 而不是 0。
  quiet=$(jq -r 'if (.progress // null) == null then "null" else (.progress.quiet_seconds // "null") end' "$TMP/status.json")
  bytes=$(jq -r 'if (.progress // null) == null then "null" else (.progress.bytes // "null") end' "$TMP/status.json")
  process=$(jq -r '.progress.process_state // ""' "$TMP/status.json")
  stale=$(jq -r 'if .progress.observations_stale == true then "true" else "false" end' "$TMP/status.json")

  # 已运行时长从 created_at 起算（包含排队时间）。没有该字段时写 "-"，不猜。
  if [ "$created" = "0" ] || [ -z "$created" ]; then
    elapsed_json="null"; elapsed_text="-"
  else
    elapsed=$((NOW - ${created%%.*}))
    [ "$elapsed" -lt 0 ] && elapsed=0
    elapsed_json="$elapsed"; elapsed_text=$(human_seconds "$elapsed")
  fi

  # 2) 内容线：只在 --no-content 关闭时读，且读取失败不改变退出码。
  content_json="[]"
  content_note=""
  if [ "$NO_CONTENT" -eq 1 ]; then
    content_note="skipped (--no-content)"
  else
    if zoe_call task logs "$t" --log agent --json --tail-bytes "$TAIL_BYTES" \
         >"$TMP/logs.json" 2>/dev/null && jq -e . "$TMP/logs.json" >/dev/null 2>&1; then
      rotated=$(jq -r 'if .rotated == true then "true" else "false" end' "$TMP/logs.json")
      reason=$(jq -r '.empty_reason // ""' "$TMP/logs.json")
      # 只取 text / tool，按时间顺序取最后 N 条；record=认出了信封没认出内容，
      # raw=不是结构化记录，两者都不是"可读进展"，不占内容行。
      # 先去重（保留首次出现的顺序），再取最后 N 条：同一条工具调用可能连续出现多次，
      # 重复行会制造"一直在动"的假象，而那正是 --with-log 曾经踩过的坑。
      content_json=$(jq -c --argjson n "$LINES" '
          [ .events[]? | select(.kind == "text" or .kind == "tool")
            | if .kind == "text"
              then {kind: "text", text: ((.text // "") | .[0:120])}
              else {kind: "tool", name: (.name // ""), target: ((.target // "") | .[0:60])}
              end
          ]
          | reduce .[] as $item ([]; if any(.[]; . == $item) then . else . + [$item] end)
          | .[(-$n):]' "$TMP/logs.json" 2>/dev/null) || content_json="[]"
      if [ "$rotated" = "true" ]; then
        content_note="（日志已轮转，从新文件重新定位）"
      elif [ "$content_json" = "[]" ] || [ -z "$content_json" ]; then
        case "$reason" in
          no_new_records) content_note="（游标之后无新记录）" ;;
          no_newline_in_window) content_note="（窗口内没有完整记录，可加大 --tail-bytes）" ;;
          no_complete_line) content_note="（窗口内只有半行/空行）" ;;
          rotated) content_note="（日志已轮转，从新文件重新定位）" ;;
          *) content_note="（没有可读进展记录）" ;;
        esac
      fi
    else
      log_err "logs unreadable: $t"
      content_note="（日志读取失败，不影响状态与退出码）"
    fi
  fi

  # 3) 每任务一行 JSON，避开在 shell 里手拼转义。
  # run_id / candidate_sha / validated_sha 与 native 路径同字段：`--since` 的指纹
  # 要在两条路径上一致，否则"装了旧 runtime"会让候选变化永远被漏报。
  candidate=$(jq -r '.candidate_sha // ""' "$TMP/status.json")
  validated=$(jq -r '.validated_sha // ""' "$TMP/status.json")
  run_id=$(jq -r '.current_run_id // ""' "$TMP/status.json")
  jq -n -c \
    --arg task "$t" --arg title "$title" --arg state "$st" --arg phase "$phase" \
    --arg block "$block" --arg process "$process" --arg scope_source "$scope_source" \
    --arg elapsed_text "$elapsed_text" --arg content_note "$content_note" \
    --arg candidate "$candidate" --arg validated "$validated" --arg run "$run_id" \
    --argjson elapsed "$elapsed_json" --argjson quiet "$quiet" --argjson bytes "$bytes" \
    --argjson stale "$stale" --argjson scope "$scope_json" \
    --argjson empty_candidate "$empty_cand" --argjson content "$content_json" \
    '{task_id: $task, title: $title, state: $state, phase: $phase,
      block_code: (if $block == "" then null else $block end),
      run_id: (if $run == "" then null else $run end),
      candidate_sha: (if $candidate == "" then null else $candidate end),
      validated_sha: (if $validated == "" then null else $validated end),
      elapsed_seconds: $elapsed, elapsed: $elapsed_text,
      quiet_seconds: $quiet, log_bytes: $bytes,
      process_state: (if $process == "" then null else $process end),
      observations_stale: $stale,
      empty_candidate: $empty_candidate,
      scope: $scope, scope_source: $scope_source,
      content: $content, content_note: (if $content_note == "" then null else $content_note end)}' \
    >>"$TMP/tasks.ndjson"

  # 4) Markdown 正文：标题行 + 内容行。不写"完成/失败/通过"。
  {
    printf -- '- **%s** `%s` — %s · %s · %s · 静默 %s · %s\n' \
      "${title:-$t}" "$t" "${st:-unknown}" "${phase:-?}" "$elapsed_text" \
      "$( [ "$quiet" = "null" ] && printf '%s' '-' || human_seconds "$quiet" )" \
      "$( [ "$bytes" = "null" ] && printf '%s' '-' || printf '%sKB' "$((bytes / 1024))" )"
    if [ -n "$content_note" ]; then
      printf '  - %s\n' "$content_note"
    else
      printf '%s' "$content_json" | jq -r '.[] |
          if .kind == "text" then "  - 说：\(.text)"
          else "  - 动：\(.name) \(.target)  (过程观察，非成功证据)" end'
    fi
    [ -n "$block" ] && printf '  - 阻断：`%s`\n' "$block"
    [ "$stale" = "true" ] && printf '  - 观测已过期（监控进程失联，需重新对账，不是任务失败）\n'
  } >>"$TMP/body.md"
done
fi

if [ "$STATUS_OK" -eq 0 ]; then
  # 空集合与"读不到"是两件事：前者是用法/前置条件（退出 2），后者是监控面不可用（11）。
  if [ "$USED_NATIVE" -eq 1 ]; then
    die_usage "no active tasks in project: $PROJECT"
  fi
  printf '[error] no target status readable (targets=%s)\n' "${TARGETS% }" >&2
  exit 11
fi

# 热区：同一路径被几个候选触及。只统计**声明了 task_scope** 的任务；
# task_scope=null 表示沿用项目范围，参与统计会得到"所有任务都重叠"的假信号。
HOT=$(jq -c -s '
  [ .[] | select(.scope != null) | .task_id as $t | .scope[] | {path: ., task: $t} ]
  | group_by(.path)
  | map({path: .[0].path, tasks: (map(.task) | unique)})
  | map(. + {count: (.tasks | length)})
  | map(select(.count >= 2))
  | sort_by(-.count)' "$TMP/tasks.ndjson" 2>/dev/null) || HOT="[]"
[ -n "$HOT" ] || HOT="[]"

# --------------------------------------------------------------------------- #
# 增量视图（--since）                                                          #
# --------------------------------------------------------------------------- #
# 只输出与上次相比**变了**的任务。指纹字段与 native/回退两条路径同一份定义，
# 所以"装了旧 runtime"不会让候选变化永远漏报。
if [ -n "$SINCE" ]; then
  mkdir -p -- "$(dirname -- "$SINCE")" 2>/dev/null || true
  if [ -f "$SINCE" ]; then
    cp -- "$SINCE" "$TMP/since-old.json" 2>/dev/null || printf '{"tasks":{}}' >"$TMP/since-old.json"
  else
    printf '{"schema_version":1,"project_id":"%s","tasks":{}}' "$PROJECT" >"$TMP/since-old.json"
  fi
  # 两条都要查：语法合法但结构不对（比如 tasks 被写成字符串）会让 jq 在索引时
  # 报错，而不是给出"没有旧记录"。坏状态一律重建 + 全量输出，比静默漏报安全。
  if ! jq -e '(.tasks // {}) | type == "object"' "$TMP/since-old.json" >/dev/null 2>&1; then
    log_err "since state has no usable tasks map; treating every task as changed"
    printf '{"schema_version":1,"project_id":"%s","tasks":{}}' "$PROJECT" >"$TMP/since-old.json"
  fi

  if ! jq -s --slurpfile old "$TMP/since-old.json" '
      def snap: {
        state: (.state // null),
        phase: (.phase // null),
        block_code: (.block_code // null),
        run_id: (.run_id // null),
        candidate_sha: (.candidate_sha // null),
        validated_sha: (.validated_sha // null),
        empty_candidate: (if .empty_candidate == true then true else false end)
      };
      (($old[0].tasks // {}) | if type == "object" then . else {} end) as $prev
      | map(. as $r
            | ($r | snap) as $s
            | ($prev[$r.task_id] // null) as $p0
            | ($p0 | if type == "object" then . else null end) as $p
            | {row: $r, snap: $s,
               change: (if $p == null then ["new"]
                        else ([($p | keys_unsorted[]), ($s | keys_unsorted[])] | unique
                              | map(. as $k | select($p[$k] != $s[$k]) | $k))
                        end)})
    ' "$TMP/tasks.ndjson" >"$TMP/checked.json" 2>/dev/null; then
    die_usage "cannot compute --since diff"
  fi

  CHANGED=$(jq '[.[] | select((.change | length) > 0)] | length' "$TMP/checked.json" 2>/dev/null) || CHANGED=0
  TOTAL=$(jq 'length' "$TMP/checked.json" 2>/dev/null) || TOTAL=0

  if [ "$UPDATE_STATE" -eq 1 ]; then
    jq -c --arg project "$PROJECT" --argjson now "$NOW" \
      '{schema_version: 1, project_id: $project, updated_at: $now,
        tasks: ([.[] | {key: .row.task_id, value: .snap}] | from_entries)}' \
      "$TMP/checked.json" >"$TMP/since-new.json" 2>/dev/null \
      && mv -- "$TMP/since-new.json" "$SINCE" 2>/dev/null \
      || log_err "cannot update since state: $SINCE"
  fi

  if [ "$JSON_OUT" -eq 1 ]; then
    jq -c --arg project "$PROJECT" --arg since "$SINCE" --argjson now "$NOW" \
          --argjson calls "$CALLS" --argjson total "$TOTAL" --argjson changed "$CHANGED" \
      '{api_version: 1, project_id: $project, generated_at: $now, calls: $calls,
        mode: "since", since: $since, total: $total, changed_count: $changed,
        unchanged_count: ($total - $changed),
        changed: [.[] | select((.change | length) > 0) | (.row + {change: .change})]}' \
      "$TMP/checked.json"
    [ "$DEBUG_CALLS" -eq 1 ] && printf '[calls] %s\n' "$CALLS" >&2
    exit 0
  fi

  if [ "$CHANGED" -eq 0 ]; then
    # 0 行是契约的一部分：调用方可以据此判断"这一轮没有新东西"。
    [ "$DEBUG_CALLS" -eq 1 ] && printf '[calls] %s\n' "$CALLS" >&2
    exit 0
  fi

  jq -r '
    .[] | select((.change | length) > 0) | . as $item | $item.row |
    "- **\(.title // .task_id)** `\(.task_id)` — \(.state // "unknown") · \(.phase // "?") · 静默 \(if .quiet_seconds == null then "-" else "\(.quiet_seconds | floor)s" end) · \(if .log_bytes == null then "-" else "\((.log_bytes / 1024) | floor)KB" end)",
    "  - 变化：\($item.change | join(", "))",
    ( if .block_code != null then "  - 阻断：`\(.block_code)`" else empty end ),
    ( if .candidate_sha != null then "  - 候选：`\(.candidate_sha[0:12])`" else empty end )
  ' "$TMP/checked.json"
  [ "$DEBUG_CALLS" -eq 1 ] && printf '[calls] %s\n' "$CALLS" >&2
  exit 0
fi

if [ "$JSON_OUT" -eq 1 ]; then
  if [ "$USED_NATIVE" -eq 1 ]; then
    # 原样转出 runtime 的聚合结果，只补实际调用次数：在脚本里再拼一遍会让
    # `note` / `tail_bytes` 这类边界字段在两条路径之间漂移。
    jq --argjson calls "$CALLS" '. + {calls: $calls}' "$TMP/native.json"
  else
    jq -s --arg project "$PROJECT" --argjson now "$NOW" --argjson calls "$CALLS" \
          --argjson hot "$HOT" \
      '{api_version: 1, project_id: $project, generated_at: $now, calls: $calls,
        tasks: ., hot_paths: $hot}' "$TMP/tasks.ndjson"
  fi
else
  {
    printf '# zoe digest · %s\n\n' "$PROJECT"
    printf '生成于 %s（%s 个目标 · %s 次 CLI 调用）\n\n' \
      "$(date -r "$NOW" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date '+%Y-%m-%d %H:%M:%S')" \
      "$STATUS_OK" "$CALLS"
    printf '> 事实聚合，不判断完成。`说：` 是自述、`动：` 是工具调用，两者都不是成功证据；\n'
    printf '> 是否结束只看 `state`，是否可交付只看 `task report` 与验收记录。\n\n'
    cat "$TMP/body.md"
    if [ "$HOT" != "[]" ]; then
      printf '\n## 共享路径（本批静态快照）\n\n'
      printf '%s' "$HOT" | jq -r '.[] | "- `\(.path)` — \(.count) 个候选：\(.tasks | join(", "))"'
      printf '\n计数是派发前的静态快照（TOCTOU），不提供互斥。\n'
    fi
    printf '\n<!-- zoe-digest project=%s tasks=%s calls=%s generated_at=%s -->\n' \
      "$PROJECT" "$STATUS_OK" "$CALLS" "$NOW"
  } >"$TMP/digest.md"
  cat "$TMP/digest.md"
  if [ -n "$OUT" ]; then
    out_dir=$(dirname -- "$OUT")
    if mkdir -p -- "$out_dir" 2>/dev/null && cp -- "$TMP/digest.md" "$OUT" 2>/dev/null; then
      printf '[out] %s\n' "$OUT" >&2
    else
      log_err "cannot write $OUT"
    fi
  fi
fi

[ "$DEBUG_CALLS" -eq 1 ] && printf '[calls] %s\n' "$CALLS" >&2
[ "$STATUS_FAIL" -gt 0 ] && printf '[warn] %s target(s) unreadable\n' "$STATUS_FAIL" >&2
exit 0
