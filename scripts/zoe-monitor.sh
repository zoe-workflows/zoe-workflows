#!/usr/bin/env bash
# zoe-monitor.sh — 有界事件查询 + 权威状态机 + 可读进展的交付监控（v1.5.2）
#
# 职责边界（先说清楚，避免把"看见"当成"推进"）：
#   * 本脚本只**观察**：读 `task status`（权威当前状态）、`zoe watch`（历史事件），
#     以及可选的 `task logs`（Agent 逐条输出了什么）。
#   * 它不推进任何任务或组：`watch` 不推进，`group start`/`group resume` 才推进。
#   * 终止判断读 `task status`，不读事件历史，也**不读日志**——历史里的 `DONE`
#     不代表当前状态，日志里的 `[log]` 也不代表推进。
#
# 四条设计约束（对应并发交付加固文档 §3.4 与可读化文档 §S8）：
#   1. 游标在轮与轮之间持久化，重启时**先读**再决定是否初始化，否则停机期间的事件
#      会被跳过（静默丢事件）。
#   2. 事件先落盘再推进游标：写日志失败时游标不动，宁可重放也不丢。
#   3. 剩余目标全部需要人工介入时 `exit 10`，不空转；watch 连续失败到上限 `exit 11`，
#      不把"读不到"当成"还在跑"。"需要人"包括 REVIEW_READY（等验收）与
#      BLOCKED/INPUT_REQUIRED（等回答）——它们都只标记，不结束其他目标的监控。
#   4. 日志是**展示**，不是判据：`--with-log` 用进程内展示游标去重，读取失败只记
#      `[log-error]`，不参与 `alive` / `need_human` / 退出码。
#
# 退出码（**不因新选项改变**）：
#   0  目标全部终态（DONE/CANCELLED），或预算（--max-rounds / --max-seconds）到期
#   2  用法/依赖错误（缺 jq、缺 --project、目标为空、参数非法）
#   10 剩余目标都需要人工介入（审查/验收/排障），脚本主动停下
#   11 `zoe watch` 连续失败达到 `--max-errors`
#
# 每次退出都打印一行 `[stop] reason=<...>`，并用 `--stop-file` 可写成 JSON：
#   ALL_TERMINAL / BUDGET_EXHAUSTED / HUMAN_REQUIRED / WATCH_ERROR / DEPENDENCY_ERROR
# 退出码 0 有两种含义（终态 / 预算到期），`reason` 是唯一可引用的区分依据。
#
# 用法：
#   zoe-monitor.sh --project demo --targets "task-a task-b"
#   zoe-monitor.sh --project demo --targets-file targets.txt --interval 5
#   zoe-monitor.sh --project demo --targets "task-a" --max-rounds 1   # 冒烟
#   zoe-monitor.sh --project demo --targets "task-a" --with-log --max-seconds 600 \
#     --stop-file .zoe/stop.json
#
# 感知延迟 ≈ --interval + 查询耗时；不要对外声称实时。

set -u
set -o pipefail

ZOE_BIN=${ZOE_BIN:-zoe}
PROJECT=""
TARGETS=""
TARGETS_FILE=""
EVENTS=./zoe-events.jsonl
CURSOR_FILE=./zoe-cursor.txt
WATCH_ERR=./zoe-watch.err
INTERVAL=3
MAX_ROUNDS=0
MAX_ERRORS=5
MAX_SECONDS=0
# 本回合还能用多少秒（宿主/agent 提供）。脚本不猜宿主预算，只接受并反推：
#   effective = min(max_seconds, deadline_in - guard)
# 拿不到就按 --max-seconds 走；两个都没给才是"不限"（SKILL 不允许这种情况出现在
# 有人在等的回合里，但脚本不替调用方做业务决定）。
DEADLINE_IN=0
DEADLINE_GUARD=30
# 窗口小于这个值时不做任何轮询：一次 status+watch 都跑不完，只会消耗预算并留下
# 一个"运行过"的假象。
MIN_WINDOW=45
EFFECTIVE_MAX=0
BUDGET_SOURCE="unbounded"
STOP_FILE=""
WITH_LOG=0
# 回合内检查点默认只有状态字段：内容（最近说了什么）要么走 --with-log 的 [log]，
# 要么显式开 --tick-content。默认关是因为它每轮多读 N 次日志。
TICK_CONTENT=0
LOG_BYTES=8192
LOG_LINES=3
LAST_LOG=""
PREV_SNAP=""
# `emit_stop` 可能在循环之前被调用（窗口过小、依赖错误），那时循环里才赋值的
# 变量都还不存在。`set -u` 下这不是"少打一个字段"，而是把退出码从 0 改成 1。
EMPTY_CANDIDATES=""
SELF_DIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd || printf '.')

# 预算用单调时钟（bash 的 SECONDS 从脚本启动起单调递增），不用
# "interval × rounds" 估算——每轮还有 CLI 查询与重试耗时。
START_SECONDS=$SECONDS

cur=""
rounds=0
STOP_EMITTED=0
LOG_STATE=""

usage() {
  cat <<'EOF'
Usage: zoe-monitor.sh --project P (--targets "T1 T2" | --targets-file F) [options]

  --project P         项目 ID（必需；事件过滤与归属校验都用它）
  --targets "T1 T2"   要监控的任务 ID，空格分隔
  --targets-file F    从文件读任务 ID（每行一个，# 开头为注释）
  --events F          事件落盘路径（默认 ./zoe-events.jsonl）
  --cursor-file F     游标持久化路径（默认 ./zoe-cursor.txt）
  --interval N        轮间隔秒数（默认 3；即感知延迟）
  --max-rounds N      跑满 N 轮后正常退出（默认 0=不限；冒烟用 1）
  --max-seconds N     预算秒数（单调时钟，与 --max-rounds 先到者生效；默认 0=不限）
  --deadline-in N     本回合**剩余**秒数（宿/agent 提供）；脚本反推有效预算
                      effective=min(max-seconds, N-guard)，并打印 [budget] 行
  --deadline-guard N  为收尾留出的余量（默认 30s；effective 低于 MIN_WINDOW=45s 时不启动）
  --max-errors N      watch 连续失败上限（默认 5，超过则 exit 11）
  --stop-file F       把结束原因写成 JSON（默认不写）
  --with-log          每轮追加仍在跑的目标的**新增**可读进展（默认关）
  --tick-content      在 [tick] 之后追加一行 [tick-log]（changed=N + 最近一条可读进展）
  --log-bytes N       单轮每目标读取窗口字节数（默认 8192；上限 1048576）
  --log-lines N       单轮每目标最多输出行数（默认 3）
  -h, --help          显示本帮助

环境变量：ZOE_BIN（默认 zoe）、ZOE_MONITOR_SLEEP（覆盖 --interval）。
退出码：0 全部终态或预算到期 / 2 用法错误 / 10 需人工介入 / 11 监控不可用。
结束原因另见末行 `[stop] reason=…`；`--stop-file` 时同值写入 JSON。
EOF
}

# 每行都带前缀，宿主可以按前缀分流；日志行统一是 `[log]`。
log() { printf '%s\n' "$*"; }

elapsed_seconds() { printf '%s' "$((SECONDS - START_SECONDS))"; }

# 结束原因只写一次：无论从哪条路径退出，都有一行可机器判定的 `[stop] reason=`。
# $1=reason  $2=1 表示"全部终态"
emit_stop() {
  [ "$STOP_EMITTED" -eq 1 ] && return 0
  STOP_EMITTED=1
  log "[stop] reason=$1 cur=$cur rounds=$rounds elapsed=$(elapsed_seconds)s"
  # 续期单：skill 不能保证"跨回合持续"，但能保证"每次让出都留下可机械执行的续期请求"。
  # 谁执行写在 owner 里，下一段命令与游标写在同一行，接手方不必重新发现状态。
  case "$1" in
    BUDGET_EXHAUSTED|HUMAN_REQUIRED|WATCH_ERROR)
      owner=next-turn-agent
      [ "$1" = "WATCH_ERROR" ] && owner=human
      targets_clean=${TARGETS% }
      target_arg=""
      [ -n "${targets_clean// /}" ] && target_arg="--targets '$targets_clean'"
      log "[renewal] owner=$owner reason=$1 cursor=${cur:-none} cursor_file=$CURSOR_FILE window_hint=600 command=\"bash $SELF_DIR/zoe-monitor.sh --project $PROJECT $target_arg --cursor-file $CURSOR_FILE --deadline-in 600 --with-log\""
      ;;
  esac
  [ -n "$STOP_FILE" ] || return 0
  local   all_terminal="false"
  [ "${2:-0}" -eq 1 ] && all_terminal="true"
  # 空候选列表作为 JSON 数组写出（纯增量键）：调用方不必自己比对两个 SHA。
  empty_json="[]"
  if [ -n "${EMPTY_CANDIDATES:-}" ]; then
    empty_json=$(printf '%s' "$EMPTY_CANDIDATES" | tr ',' '\n' \
      | jq -R -s -c 'split("\n") | map(select(length > 0))' 2>/dev/null) || empty_json="[]"
    [ -n "$empty_json" ] || empty_json="[]"
  fi
  printf '{"monitor_stop_reason": "%s", "all_terminal": %s, "next_cursor": "%s", "rounds": %s, "elapsed_seconds": %s, "empty_candidates": %s}\n' \
    "$1" "$all_terminal" "$cur" "$rounds" "$(elapsed_seconds)" "$empty_json" >"$STOP_FILE" \
    || log "[warn] cannot write stop file: $STOP_FILE"
}

# 依赖/用法错误：不是任务失败，但监控本身不可用。
die_usage() {
  log "[error] $1"
  emit_stop DEPENDENCY_ERROR 0
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --project) PROJECT=${2:-}; shift 2 ;;
    --targets) TARGETS=${2:-}; shift 2 ;;
    --targets-file) TARGETS_FILE=${2:-}; shift 2 ;;
    --events) EVENTS=${2:-}; shift 2 ;;
    --cursor-file) CURSOR_FILE=${2:-}; shift 2 ;;
    --interval) INTERVAL=${2:-}; shift 2 ;;
    --max-rounds) MAX_ROUNDS=${2:-}; shift 2 ;;
    --max-seconds) MAX_SECONDS=${2:-}; shift 2 ;;
    --deadline-in) DEADLINE_IN=${2:-}; shift 2 ;;
    --deadline-guard) DEADLINE_GUARD=${2:-}; shift 2 ;;
    --max-errors) MAX_ERRORS=${2:-}; shift 2 ;;
    --stop-file) STOP_FILE=${2:-}; shift 2 ;;
    --with-log) WITH_LOG=1; shift ;;
    --tick-content) TICK_CONTENT=1; shift ;;
    --log-bytes) LOG_BYTES=${2:-}; shift 2 ;;
    --log-lines) LOG_LINES=${2:-}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die_usage "unknown argument: $1" ;;
  esac
done

INTERVAL=${ZOE_MONITOR_SLEEP:-$INTERVAL}

[ -n "$PROJECT" ] || die_usage "--project is required"
if [ -n "$TARGETS_FILE" ]; then
  [ -f "$TARGETS_FILE" ] || die_usage "targets file not found: $TARGETS_FILE"
  from_file=$(sed -e 's/#.*//' "$TARGETS_FILE" | tr '\n' ' ')
  TARGETS="$TARGETS $from_file"
fi
# 去重并压掉多余空白：重复的 ID 会让计数与 [needs-human] 记录重复。
TARGETS=$(printf '%s\n' $TARGETS | awk 'NF && !seen[$0]++' | tr '\n' ' ')
[ -n "${TARGETS// /}" ] || die_usage "no targets: use --targets or --targets-file"

# 参数校验放在依赖检查之后、循环之前：错在启动时比错在第五轮便宜。
case "$MAX_ROUNDS" in ''|*[!0-9]*) die_usage "--max-rounds must be a non-negative integer" ;; esac
case "$MAX_SECONDS" in ''|*[!0-9]*) die_usage "--max-seconds must be a non-negative integer" ;; esac
case "$MAX_ERRORS" in ''|*[!0-9]*) die_usage "--max-errors must be a non-negative integer" ;; esac
case "$LOG_BYTES" in ''|*[!0-9]*) die_usage "--log-bytes must be an integer" ;; esac
[ "$LOG_BYTES" -ge 1 ] && [ "$LOG_BYTES" -le 1048576 ] \
  || die_usage "--log-bytes must be 1..1048576"
case "$LOG_LINES" in ''|*[!0-9]*) die_usage "--log-lines must be an integer" ;; esac
[ "$LOG_LINES" -ge 1 ] || die_usage "--log-lines must be at least 1"
# 轮间隔也会直接交给 `sleep`：不是非负整数时每一轮都会报一次 sleep 用法错误，
# 循环照跑但延迟变成 0（CPU 空转）。启动期拒绝比跑到第五轮才发现便宜。
case "$INTERVAL" in ''|*[!0-9]*) die_usage "--interval must be a non-negative integer of seconds" ;; esac

command -v jq >/dev/null 2>&1 || die_usage "jq is required"
command -v "$ZOE_BIN" >/dev/null 2>&1 || die_usage "zoe not found: $ZOE_BIN"

case "$DEADLINE_IN" in ''|*[!0-9]*) die_usage "--deadline-in must be a non-negative integer" ;; esac
case "$DEADLINE_GUARD" in ''|*[!0-9]*) die_usage "--deadline-guard must be a non-negative integer" ;; esac

# 预算反推：调用方该给的是"本回合还剩多少秒"，不是"想让脚本跑多久"。后者常被拍成
# 一个超过回合时长的数，于是脚本还没跑完回合就结束了——连 [stop] 都来不及写，下一段
# 只能从"我以为它跑到哪"开始猜。
EFFECTIVE_MAX=0
BUDGET_SOURCE="unbounded"
if [ "$DEADLINE_IN" -gt 0 ]; then
  available=$((DEADLINE_IN - DEADLINE_GUARD))
  [ "$available" -lt 0 ] && available=0
  EFFECTIVE_MAX=$available
  BUDGET_SOURCE="deadline-in"
  if [ "$MAX_SECONDS" -gt 0 ] && [ "$MAX_SECONDS" -lt "$available" ]; then
    EFFECTIVE_MAX=$MAX_SECONDS
    BUDGET_SOURCE="max-seconds"
  fi
elif [ "$MAX_SECONDS" -gt 0 ]; then
  EFFECTIVE_MAX=$MAX_SECONDS
  BUDGET_SOURCE="max-seconds"
fi
log "[budget] requested=${MAX_SECONDS}s deadline_in=${DEADLINE_IN}s guard=${DEADLINE_GUARD}s effective=${EFFECTIVE_MAX}s source=$BUDGET_SOURCE"

# 小于 MIN_WINDOW 的窗口一次 status+watch 都跑不完：启动只会消耗预算并留下"运行过"
# 的假象。直接给出续期单，让下一回合用完整窗口跑，而不是在这里空转。
if [ "$DEADLINE_IN" -gt 0 ] && [ "$EFFECTIVE_MAX" -lt "$MIN_WINDOW" ]; then
  log "[budget] window too small (${EFFECTIVE_MAX}s < ${MIN_WINDOW}s): not starting"
  emit_stop BUDGET_EXHAUSTED 0
  exit 0
fi

# 落盘目录必须存在：`>> "$EVENTS"` 在目录缺失时只让重定向失败，而脚本没有 errexit，
# 结果是游标照常前进、事件被静默丢掉——那正是"宁可重放也不丢"的反面。
for f in "$EVENTS" "$CURSOR_FILE" "$WATCH_ERR"; do
  case "$f" in */*) mkdir -p -- "$(dirname -- "$f")" 2>/dev/null || true ;; esac
done
: >>"$EVENTS" 2>/dev/null || die_usage "cannot write events file: $EVENTS"

# 展示游标只服务"这一轮打印过了没有"：进程内临时目录，退出即丢弃，
# 绝不写进任务状态库或 progress.json（那会制造第二事实源）。
if [ "$WITH_LOG" -eq 1 ]; then
  if LOG_STATE=$(mktemp -d 2>/dev/null); then
    :
  else
    WITH_LOG=0
    LOG_STATE=""
    log "[log-off] cannot create a temp dir for the display cursor"
  fi
fi
LOG_ERRORS=0

# 轮间快照：只用于回答"这一轮有没有变化"（[tick] changed=N）。它是进程内临时文件，
# 退出即丢弃——不写进任务状态库，也不参与退出码。
SNAP_CUR=$(mktemp 2>/dev/null || true)
SNAP_PREV=$(mktemp 2>/dev/null || true)
if [ -z "$SNAP_CUR" ] || [ -z "$SNAP_PREV" ]; then
  SNAP_CUR=/dev/null
  SNAP_PREV=/dev/null
  TICK_CONTENT=0
fi
trap 'rm -rf "${LOG_STATE:-}" "${SNAP_CUR:-}" "${SNAP_PREV:-}"' EXIT
if [ "$TICK_CONTENT" -eq 1 ] && [ "$WITH_LOG" -ne 1 ]; then
  log "[tick-content] requires --with-log for content; [tick-log] will only carry changed=N"
fi

# 游标：先复用，缺省才初始化。初始化取的是"当前末端"，只在首次运行时发生，
# 所以"第一次启动会跳过启动前的事件"是明确行为，不是缺陷。
if [ -s "$CURSOR_FILE" ]; then
  # 只取第一行：多行（历史追加/手工编辑）拼起来会得到一个"看起来合法"的错游标。
  cur=$(head -1 "$CURSOR_FILE" | tr -d '[:space:]')
fi
if [ -z "$cur" ]; then
  if ! init=$("$ZOE_BIN" watch --project "$PROJECT" --json); then
    log "[error] watch init failed; 游标未建立"
    emit_stop WATCH_ERROR 0
    exit 2
  fi
  cur=$(printf '%s' "$init" | jq -r '.next_cursor // empty') || cur=""
  [ -n "$cur" ] || die_usage "init response has no next_cursor"
  printf '%s\n' "$cur" >"$CURSOR_FILE"
  log "[init] cursor=$cur (首次运行：起点为当前末端)"
fi

human=""
finished=""
errors=0
# 空候选（candidate_sha == base_sha）单独记一份：它仍属"等人工验收"，
# 但"等验收"与"没有内容可验收"要能分开，否则报告里两者长得一样。
EMPTY_CANDIDATES=""

# 追加"新增的"可读进展。$1=task  $2=current_run_id
#
# 规则（四条都是硬要求）：
#   1. 只展示新增：首次无游标 ⇒ 展示窗口尾部一次，此后只输出新事件；无新事件不补行；
#   2. run 切换 / 日志回绕 ⇒ 丢弃旧游标重新定位（游标无法自证来自哪个 run/日志）；
#   3. 读取失败只记 `[log-error]`，游标不动，不改变退出码，连续 3 次关闭本功能；
#   4. 游标与日志名绑定：本函数固定读 `--log agent`；若将来把日志名参数化，换日志必须
#      丢弃旧游标——cursor 只编码 run/generation/offset，无法自证来自哪个日志文件。
emit_log() {
  local t=$1 run_id=$2 curf cur out rc err rotated reset nxt
  curf="$LOG_STATE/$t.cursor"
  cur=""
  [ -f "$curf" ] && cur=$(head -1 "$curf" 2>/dev/null | tr -d '[:space:]')
  if [ -n "$cur" ] && [ -n "$run_id" ] && [ "${cur%%:*}" != "$run_id" ]; then
    cur=""
  fi

  err="$LOG_STATE/err"
  if [ -n "$cur" ]; then
    out=$("$ZOE_BIN" task logs "$t" --log agent --json --after "$cur" \
      --tail-bytes "$LOG_BYTES" 2>"$err")
  else
    out=$("$ZOE_BIN" task logs "$t" --log agent --json --tail-bytes "$LOG_BYTES" 2>"$err")
  fi
  rc=$?

  # 旧 runtime（不认识 --after）时软兜底关闭：argparse 的退出码是 2，与
  # INPUT_INCOMPLETE 同码，只能看 stderr 才能区分，绝不能把两者混为一谈。
  if [ "$rc" -ne 0 ] && grep -q 'unrecognized arguments' "$err" 2>/dev/null; then
    WITH_LOG=0
    log "[log-off] runtime 不接受 task logs --after：已关闭 --with-log（其余监控照常）"
    return 0
  fi
  if [ "$rc" -ne 0 ] || ! printf '%s' "$out" | jq -e . >/dev/null 2>&1; then
    LOG_ERRORS=$((LOG_ERRORS + 1))
    log "[log-error] $t 读取失败（不影响监控与退出码）"
    if [ "$LOG_ERRORS" -ge 3 ]; then
      WITH_LOG=0
      log "[log-off] 日志读取连续失败，已关闭 --with-log"
    fi
    return 0
  fi
  LOG_ERRORS=0

  # 日志被截断/替换：不报错，也不把整份日志当成"新进展"重新播一遍。
  # 丢弃旧游标 ⇒ 下一轮按窗口重新初始化一次（S8-B2 规则 2）。响应里的 reset_cursor
  # （offset 0）不写回去：那会从新文件**开头**开始播，而不是"最近发生了什么"。
  rotated=$(printf '%s' "$out" | jq -r '.rotated // false')
  if [ "$rotated" = "true" ]; then
    rm -f "$curf"
    return 0
  fi

  # 只展示"可读进展"：说话（text）与动作（tool）。record/raw 不是"没有输出"，
  # 但它们不构成可读进展，所以不进 `[log]` 行。
  lines=$(printf '%s' "$out" | jq -r --arg t "$t" '
      .events[]? | select(.kind == "text" or .kind == "tool")
      | (if .kind == "text" then "[log] \($t) 说：\(.text)"
         else "[log] \($t) 动：\(.name) \(.target // "")  (过程观察，非成功证据)" end)' \
    | tail -n "$LOG_LINES")
  if [ -n "$lines" ]; then
    printf '%s\n' "$lines"
    # 给 [tick-log] 用：最后一条可读进展。它仍然只是过程观察，不是成功证据。
    LAST_LOG=$(printf '%s\n' "$lines" | awk 'NF' | tail -n 1)
  fi

  # 只有解析成功才推进展示游标：读取失败绝不当成"没有新日志"。
  nxt=$(printf '%s' "$out" | jq -r '.next_cursor // empty')
  [ -n "$nxt" ] && printf '%s' "$nxt" >"$curf"
  return 0
}

while :; do
  rounds=$((rounds + 1))

  # 0) 预算（单调时钟）：与 --max-rounds 取先到者，退出码仍是 0。
  if [ "$EFFECTIVE_MAX" -gt 0 ] && [ "$(elapsed_seconds)" -ge "$EFFECTIVE_MAX" ]; then
    log "[stop] max seconds reached (effective=${EFFECTIVE_MAX}s source=$BUDGET_SOURCE elapsed=$(elapsed_seconds)s rounds=$rounds cur=$cur)"
    emit_stop BUDGET_EXHAUSTED 0
    exit 0
  fi

  # 1) 权威状态：终止判断只看这里。
  alive=0
  need_human=0
  phases=""
  runs=""
  alive_list=""
  alive_runs=""
  # 本批静默最长的仍在跑目标（只用于展示，不参与 alive/need_human/退出码）。
  quiet_max=-1
  quiet_task=""
  : >"$SNAP_CUR" 2>/dev/null || true
  for t in $TARGETS; do
    case " $finished " in *" $t "*) continue ;; esac
    # state / block_code / phase / run 一次读出：`INPUT_REQUIRED` 是 block_code，
    # 不是 state，只看 state 永远匹不到它（那会让"等回答"和普通 BLOCKED 混在一起）。
    # phase 与 run 只是**展示**：phase 长时间不变是正常的，"阶段没变"不是卡住。
    # 终止判断必须读**对账之后**的状态：`task status` 不带 `--refresh` 时 supervisor
    # 中途死亡的任务会永远停在 RUNNING，监控于是耗光预算也报不出"进程没了"。
    # `--refresh` 失败（例如旧运行器不认这个开关）时退回只读查询，不因此判失败。
    if ! row=$("$ZOE_BIN" task status "$t" --json --refresh 2>/dev/null \
        | jq -r '"\(.state // "")\u001f\(.block_code // "")\u001f\(.phase // "")\u001f\(.current_run_id // "")\u001f\(.base_sha // "")\u001f\(.candidate_sha // "")\u001f\(.empty_candidate // false)\u001f\(.progress.quiet_seconds // "")"'); then
      row=$("$ZOE_BIN" task status "$t" --json 2>/dev/null \
        | jq -r '"\(.state // "")\u001f\(.block_code // "")\u001f\(.phase // "")\u001f\(.current_run_id // "")\u001f\(.base_sha // "")\u001f\(.candidate_sha // "")\u001f\(.empty_candidate // false)\u001f\(.progress.quiet_seconds // "")"') || row=""
    fi
    # 八个字段一次读出：手工 ${row%%\t*} 拆八次，漏掉一个就会把后面的值整体错位，
    # 而错位的表现是"状态看起来正常"——比报错难查得多。
    # 分隔符必须是**非空白**字符（\037 = unit separator）：IFS 里只有空白字符时，
    # `read` 会把连续分隔符当成一个，空字段（例如没有 block_code）就被吞掉，
    # 后面所有值跟着左移一位——正是"看起来正常"的那种错。
    st=""; block=""; phase=""; run_id=""; base_sha=""; cand_sha=""; empty_flag=""; quiet=""
    IFS_SEP=$(printf '\037')
    IFS="$IFS_SEP" read -r st block phase run_id base_sha cand_sha empty_flag quiet <<EOF
$row
EOF
    # 轮间指纹：state|block|phase|run|candidate。读不到时记 unreadable，让"读不到"
    # 本身也算一次变化，而不是安静地保持不变。
    printf '%s\t%s|%s|%s|%s|%s\n' "$t" "${st:-unreadable}" "$block" "$phase" "$run_id" "$cand_sha" >>"$SNAP_CUR"
    # 逗号分隔（S8-B1 的格式）：字段之间用空格，列表元素之间用逗号，
    # 宿主按逗号切分即可，不会把 "T2:verify" 当成独立的字段。
    [ -n "$phase" ] && phases="${phases:+$phases,}$t:$phase"
    [ -n "$run_id" ] && runs="${runs:+$runs,}$t:$run_id"
    if [ -z "$st" ]; then
      # 读不到就报出来，不能当作"仍在运行"——那会让脚本永远不退出。
      log "[warn] status unreadable: $t"
      alive=1
      continue
    fi
    case "$st" in
      DONE|CANCELLED)
        finished="$finished $t"
        log "[final] $t $st"
        ;;
      # REVIEW_READY 是"等人工验收"，不是终态，也不是"还在跑"：既不结束循环，
      # 也不能装作它会自己前进。
      REVIEW_READY)
        need_human=$((need_human + 1))
        # 零候选：worker 一个字都没改，但任务照样会走到 REVIEW_READY，而且证据里
        # 的 PASS 只是"基线本来就能过"。优先用运行时的 `empty_candidate`（权威），
        # 老版本没有该字段时退回比较两个**非空** SHA：两个空 SHA 表示"还没验证"，
        # 不能判等。
        empty="0"
        if [ "$empty_flag" = "true" ]; then
          empty="1"
        elif [ -n "$cand_sha" ] && [ -n "$base_sha" ] && [ "$cand_sha" = "$base_sha" ]; then
          empty="1"
        fi
        case " $human " in
          *" $t "*) ;;
          *)
            human="$human $t"
            if [ "$empty" = "1" ]; then
              EMPTY_CANDIDATES="${EMPTY_CANDIDATES:+$EMPTY_CANDIDATES,}$t"
              log "[needs-human] $t REVIEW_READY 但 empty_diff=true（candidate_sha == base_sha）无改动可验收"
            else
              log "[needs-human] $t REVIEW_READY 等人工验收"
            fi
            ;;
        esac
        ;;
      BLOCKED|PAUSED)
        need_human=$((need_human + 1))
        label=$st
        [ "$block" = "INPUT_REQUIRED" ] && label="$st/INPUT_REQUIRED（等回答）"
        case " $human " in
          *" $t "*) ;;
          *) human="$human $t"; log "[needs-human] $t $label" ;;
        esac
        ;;
      *)
        # 仍在跑：连同当前 run 一起登记（两条平行列表，按位置对应）。
        # 不用关联数组：POSIX 可移植，macOS 自带 bash 3.2 也能跑。
        alive=1
        alive_list="${alive_list:+$alive_list }$t"
        alive_runs="${alive_runs:+$alive_runs }${run_id:--}"
        # 静默最长者：quiet_seconds 是观测事实（round 到毫秒），取整数部分比较；
        # 缺失或非数字时**不参与**比较，而不是当成 0（那会让"读不到"冒充"很安静"）。
        case "$quiet" in
          ''|*[!0-9.]*) ;;
          *)
            quiet_int=${quiet%%.*}
            [ -n "$quiet_int" ] || quiet_int=0
            if [ "$quiet_int" -gt "$quiet_max" ]; then
              quiet_max=$quiet_int
              quiet_task=$t
            fi
            ;;
        esac
        ;;
    esac
  done

  if [ "$alive" -eq 0 ]; then
    if [ "$need_human" -eq 0 ]; then
      log "[done] all targets final (rounds=$rounds)"
      emit_stop ALL_TERMINAL 1
      exit 0
    fi
    log "[pause] remaining targets need a human:$human"
    emit_stop HUMAN_REQUIRED 0
    exit 10
  fi

  # 2) 检查点：没有事件时也要有一行，否则"仍在监控"无法被验证。
  # `quiet=` 只回答"谁最久没输出"，不是健康度：静默变长不等于卡住，读不到时不报 quiet。
  quiet_text="none"
  [ -n "$quiet_task" ] && quiet_text="$quiet_task:$quiet_max"
  # changed= 是本轮相对上一轮的**状态指纹变化数**（新增任务算变化）。它不解释原因，
  # 只回答"这一轮有没有新东西"——宿主可以据此决定要不要展开 digest，而不是每轮都展开。
  # 用 FILENAME==ARGV[1] 而不是 NR==FNR：第一个文件为空时，NR==FNR 对第二个文件的
  # 第一行也成立，那一行会被当成"旧快照"吞掉，首轮于是永远报 changed=0。
  changed=$(awk -F'\t' '
    FILENAME == ARGV[1] { prev[$1] = $2; next }
    { if (!($1 in prev) || prev[$1] != $2) n++ }
    END { print n + 0 }
  ' "$SNAP_PREV" "$SNAP_CUR" 2>/dev/null) || changed=0
  cp "$SNAP_CUR" "$SNAP_PREV" 2>/dev/null || true
  LAST_LOG=""
  log "[tick] round=$rounds cur=$cur alive=$alive need_human=$need_human human=${human:-none} phases=${phases:-none} runs=${runs:-none} quiet=$quiet_text changed=$changed"

  # 2.5) 可读进展：每个仍在跑的目标，每轮最多一次 CLI 调用 + ≤ --log-bytes 字节。
  if [ "$WITH_LOG" -eq 1 ]; then
    pending_runs=$alive_runs
    for t in $alive_list; do
      [ "$WITH_LOG" -eq 1 ] || break
      rid=${pending_runs%% *}
      if [ "$rid" = "$pending_runs" ]; then pending_runs=""; else pending_runs=${pending_runs#* }; fi
      [ "$rid" = "-" ] && rid=""
      emit_log "$t" "$rid"
    done
  fi

  # 2.6) 可选的"带内容检查点"：默认关，因为它与 --with-log 是同一份日志读取。
  # 单独一行、独立前缀：下游按 `[tick]` grep 的既有解析不受影响。
  if [ "$TICK_CONTENT" -eq 1 ]; then
    last="none"
    # 去掉 `[log]` 前缀：这一行本身已经带 `[tick-log]`，保留会变成双重标签。
    [ -n "$LAST_LOG" ] && last=$(printf '%s' "$LAST_LOG" | sed 's/^\[log\] //' | cut -c1-120)
    log "[tick-log] round=$rounds changed=$changed last=$last"
  fi

  # 3) 消费事件：先落盘，再推进游标。
  tmp=$(mktemp)
  if ! "$ZOE_BIN" watch --project "$PROJECT" --jsonl --after "$cur" --max-events 200 \
      >"$tmp" 2>"$WATCH_ERR"; then
    errors=$((errors + 1))
    log "[error] watch failed (${errors}/${MAX_ERRORS}): $(tr '\n' ' ' <"$WATCH_ERR" | cut -c1-200)"
    rm -f "$tmp"
    if [ "$errors" -ge "$MAX_ERRORS" ]; then
      log "[abort] watch unusable (cur=$cur); 修可达性后从游标文件续跑"
      emit_stop WATCH_ERROR 0
      exit 11
    fi
    sleep "$INTERVAL"
    continue
  fi
  nxt=$(tail -1 "$tmp" | jq -r '.next_cursor // empty') || nxt=""
  if [ -z "$nxt" ]; then
    # meta 行缺失/不可解析：这一页不能算消费成功，游标保持不动。
    errors=$((errors + 1))
    log "[error] meta line missing or unparsable (${errors}/${MAX_ERRORS})"
    rm -f "$tmp"
    if [ "$errors" -ge "$MAX_ERRORS" ]; then
      log "[abort] cannot read cursor from watch output (cur=$cur); 从游标文件续跑"
      emit_stop WATCH_ERROR 0
      exit 11
    fi
    sleep "$INTERVAL"
    continue
  fi
  # 末行是 meta（心跳/游标），丢掉；其余是事件。
  # 落盘失败时游标**不动**：宁可下一轮重放这一页，也不能"游标前进了、事件没了"
  # （PowerShell 版已经这样处理，两处必须同语义）。
  if ! sed '$d' "$tmp" >>"$EVENTS" 2>/dev/null; then
    errors=$((errors + 1))
    log "[error] cannot append events (${errors}/${MAX_ERRORS}): $EVENTS"
    rm -f "$tmp"
    if [ "$errors" -ge "$MAX_ERRORS" ]; then
      log "[abort] events file not writable (cur=$cur); 修好后再从游标文件续跑"
      emit_stop WATCH_ERROR 0
      exit 11
    fi
    sleep "$INTERVAL"
    continue
  fi
  cur="$nxt"
  printf '%s\n' "$cur" >"$CURSOR_FILE"
  rm -f "$tmp"
  errors=0

  if [ "$MAX_ROUNDS" -gt 0 ] && [ "$rounds" -ge "$MAX_ROUNDS" ]; then
    log "[stop] max rounds reached (rounds=$rounds cur=$cur)"
    emit_stop BUDGET_EXHAUSTED 0
    exit 0
  fi

  sleep "$INTERVAL"
done
