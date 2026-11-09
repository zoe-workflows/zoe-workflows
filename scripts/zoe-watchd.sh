#!/usr/bin/env bash
# zoe-watchd.sh — 会话结束后仍然记录状态的**只读**守护。
#
# 它解决什么问题：`zoe-monitor.sh` 是前台、有界的观察循环，宿主回合结束（或会话关闭）
# 它就没了。于是"我关了窗口之后任务跑到哪了"只能靠回来重查，而重查时早期状态已经
# 被覆盖。本脚本把**观测事实**持续落到两个文件里：
#
#   live.jsonl  只在状态变化时追加一行（谁、变了哪些键、从什么到什么）
#   live.md     覆盖写的当前快照（人读；含 quota_blocked 提示）
#
# 三条硬边界（写进代码，不只是写进文档）：
#   1. **只读**。它只调用 `task status` 与 `task list`；`run_cli` 遇到 start/resume/
#      accept/pause/cancel/group start/group dispatch 会直接以退出码 70 自杀。守护一旦
#      能派发，就成了第二个写者，直接破坏"同一任务同一时刻一个写者"。
#   2. **不替代合并**。合并要审 diff、跑 checks、解冲突，这里只告诉你"谁可能可以合了"。
#   3. **能停**。`stop` 写 stop.request 并等待；pid 锁带陈旧自愈（进程不在了但锁还在，
#      下一次 start 接管）。
#
# 它**不能**做到的：会话关闭后继续推进任务。`nohup` 只能记录，不能行动；无人时真正
# 做事需要宿主定时任务（平台能力），本脚本不提供，也不假装提供。
#
# 用法：
#   bash zoe-watchd.sh start  --project P [--targets "T1 T2"] [--interval 15]
#                             [--max-seconds 3600] [--state-dir DIR] [--no-detach]
#   bash zoe-watchd.sh status --project P [--state-dir DIR] [--json]
#   bash zoe-watchd.sh stop   --project P [--state-dir DIR] [--timeout 15]
#   bash zoe-watchd.sh run    ...（前台循环；start 内部调用，也可用于调试）
#
# 退出码：
#   0  成功（start 表示已就绪；stop 表示已停止）
#   2  用法或依赖错误（缺 jq / 缺 --project / 参数越界）
#   3  已有守护在运行（不会启动第二个）
#   4  守护未能就绪（start 等待首版 live.md 超时；看 run.log）
#   70 守护试图调用写操作（内部不变量被破坏）
#
# 依赖：jq、可执行的 zoe（ZOE_BIN 覆盖）。macOS 自带 bash 3.2 可跑。

set -u
set -o pipefail

ZOE_BIN=${ZOE_BIN:-zoe}
ACTION=${1:-}
[ $# -gt 0 ] && shift

PROJECT=""
TARGETS=""
TARGETS_FILE=""
INTERVAL=15
MAX_SECONDS=3600
STATE_DIR=""
NO_DETACH=0
JSON_OUT=0
TIMEOUT=15
DEBUG_CALLS=0

CALLS=0
STARTED_AT=0
STOP_REASON=""
REFRESH_EVERY=10

usage() {
  cat <<'EOF'
用法: zoe-watchd.sh <start|stop|status|run> --project P [options]

  start   起一个脱离会话的只读守护（nohup），就绪后返回
  stop    请求守护退出；先写 stop.request，超时才发信号
  status  打印守护是否存活、live 文件位置与最后更新时间
  run     前台跑循环（start 内部使用；调试用）

公共选项:
  --project P         项目 ID（必需）
  --state-dir DIR     状态目录（默认 .zoe/watch/<project>）

start/run 选项:
  --targets "T1 T2"   只观察这些任务（缺省取项目内非终态任务，每 10 轮刷新一次）
  --targets-file F    从文件读任务 ID（每行一个，# 注释）
  --interval N        轮询间隔秒数（默认 15，最小 5）
  --max-seconds N     墙钟预算（默认 3600；0 表示不限，必须显式给）
  --no-detach         前台运行（等价 run，便于终端观察）

status 选项:
  --json              输出结构化 JSON

stop 选项:
  --timeout N         等待优雅退出的秒数（默认 15），超时后 TERM→KILL

环境变量: ZOE_BIN（默认 zoe）

边界：只读。只调用 `task status` / `task list`；不 start/resume/accept/pause/cancel，
不合并、不判断完成。会话关闭后它只**记录**，不推进任务。
退出码：0 成功 / 2 用法依赖 / 3 已有守护 / 4 未能就绪 / 70 试图写操作
EOF
}

die() {
  code=$1
  shift
  printf '[error] %s\n' "$*" >&2
  exit "$code"
}

note() { printf '%s\n' "$*" >&2; }

# 所有 CLI 调用都从这里走：既计数，也挡住写操作（边界 1 的运行时保证）。
run_cli() {
  case "${1:-} ${2:-}" in
    "task start"|"task resume"|"task accept"|"task pause"|"task cancel"| \
    "task revise"|"task reassign"|"task rebind"|"group start"|"group dispatch"| \
    "group accept"|"group pause"|"group cancel")
      die 70 "watchd is read-only; refusing to run: $1 $2" ;;
  esac
  CALLS=$((CALLS + 1))
  "$ZOE_BIN" "$@"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --project) PROJECT=${2:-}; shift 2 ;;
    --targets) TARGETS=${2:-}; shift 2 ;;
    --targets-file) TARGETS_FILE=${2:-}; shift 2 ;;
    --interval) INTERVAL=${2:-}; shift 2 ;;
    --max-seconds) MAX_SECONDS=${2:-}; shift 2 ;;
    --state-dir) STATE_DIR=${2:-}; shift 2 ;;
    --no-detach) NO_DETACH=1; shift ;;
    --json) JSON_OUT=1; shift ;;
    --timeout) TIMEOUT=${2:-}; shift 2 ;;
    --debug-calls) DEBUG_CALLS=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die 2 "unknown argument: $1" ;;
  esac
done

case "$ACTION" in
  start|stop|status|run) ;;
  ''|-h|--help) usage; exit 0 ;;
  *) usage >&2; die 2 "unknown action: $ACTION" ;;
esac

[ -n "$PROJECT" ] || die 2 "--project is required"
case "$INTERVAL" in ''|*[!0-9]*) die 2 "--interval must be a positive integer" ;; esac
[ "$INTERVAL" -ge 5 ] || die 2 "--interval must be >= 5"
case "$MAX_SECONDS" in ''|*[!0-9]*) die 2 "--max-seconds must be 0 or a positive integer" ;; esac
case "$TIMEOUT" in ''|*[!0-9]*) die 2 "--timeout must be a positive integer" ;; esac
[ -z "$STATE_DIR" ] && STATE_DIR=".zoe/watch/$PROJECT"
command -v jq >/dev/null 2>&1 || die 2 "jq is required"
command -v "$ZOE_BIN" >/dev/null 2>&1 || die 2 "zoe not found: $ZOE_BIN"

LOCK="$STATE_DIR/lock"
LIVE_MD="$STATE_DIR/live.md"
LIVE_JSONL="$STATE_DIR/live.jsonl"
SNAPSHOT="$STATE_DIR/snapshot.json"
STOP_FILE="$STATE_DIR/stop.request"
RUN_LOG="$STATE_DIR/run.log"

# --------------------------------------------------------------------------- #
# 锁                                                                          #
# --------------------------------------------------------------------------- #

# pid 活着**且**命令行里确实是本脚本：只看 kill -0 会把复用的 PID 当成自己的守护，
# 于是"锁永远不会陈旧"，下一次永远起不来。
alive_owner() {
  pid=$1
  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  cmd=$(ps -p "$pid" -o command= 2>/dev/null || true)
  case "$cmd" in
    *zoe-watchd.sh*) return 0 ;;
    *) return 1 ;;
  esac
}

lock_holder() { cat "$LOCK/pid" 2>/dev/null || true; }

write_lock() {
  mkdir -p "$LOCK" || return 1
  printf '%s\n' "$1" >"$LOCK/pid" || return 1
  printf '%s\n' "$STARTED_AT" >"$LOCK/started_at" || return 1
  printf '%s\n' "$PROJECT" >"$LOCK/project" || return 1
}

# 接管只重试一次：反复删锁会把"两个 start 同时接管"变成一个活锁。
acquire_lock() {
  mkdir -p "$STATE_DIR" || die 2 "cannot create state dir: $STATE_DIR"
  STARTED_AT=$(date +%s)
  if mkdir "$LOCK" 2>/dev/null; then
    write_lock "$1" || die 2 "cannot write lock"
    return 0
  fi
  holder=$(lock_holder)
  if alive_owner "$holder"; then
    note "[busy] watchd already running (pid=$holder)"
    return 3
  fi
  note "[heal] stale lock taken over (pid=${holder:-none})"
  rm -rf "$LOCK"
  mkdir "$LOCK" 2>/dev/null || die 3 "another starter won the lock race"
  write_lock "$1" || die 2 "cannot write lock"
  return 0
}

release_lock() {
  holder=$(lock_holder)
  [ "$holder" = "$$" ] && rm -rf "$LOCK"
}

# --------------------------------------------------------------------------- #
# 目标集合                                                                    #
# --------------------------------------------------------------------------- #

targets_from_file() {
  [ -n "$TARGETS_FILE" ] || return 0
  [ -f "$TARGETS_FILE" ] || die 2 "targets file not found: $TARGETS_FILE"
  sed -e 's/#.*//' "$TARGETS_FILE" | tr '\n' ' '
}

refresh_targets() {
  from_file=$(targets_from_file)
  TARGETS="$TARGETS $from_file"
  if [ -n "${TARGETS// /}" ]; then
    TARGETS=$(printf '%s\n' $TARGETS | awk 'NF && !seen[$0]++' | tr '\n' ' ')
    return 0
  fi
  # 缺省集合每次刷新都重查：新派发的任务也要进视野，否则守护只盯着启动那一刻。
  if run_cli task list --project "$PROJECT" --json >"$STATE_DIR/list.json" 2>/dev/null; then
    TARGETS=$(jq -r '.[]? | select(.project_id == $p)
                     | select(.state != "DONE" and .state != "CANCELLED")
                     | .task_id' --arg p "$PROJECT" "$STATE_DIR/list.json" 2>/dev/null | tr '\n' ' ')
  fi
  [ -n "${TARGETS// /}" ] || note "[warn] no active tasks in project: $PROJECT"
}

# --------------------------------------------------------------------------- #
# 一轮                                                                        #
# --------------------------------------------------------------------------- #

# 裁剪成"变化可见"的最小集合。指纹与 live.jsonl 都用同一份字段，避免两处口径漂移。
#
# 结果写文件而不是 echo：`$(read_status)` 会把它放进子 shell，`run_cli` 里的
# 写操作断言（die 70）就只能杀掉那个子 shell，主循环会继续跑——"只读"的保证
# 不能依赖命令替换的退出码。
read_status() {
  task=$1
  if ! run_cli task status "$task" --json --refresh >"$STATE_DIR/status.json" 2>/dev/null; then
    if ! run_cli task status "$task" --json >"$STATE_DIR/status.json" 2>/dev/null; then
      return 1
    fi
  fi
  jq -e . "$STATE_DIR/status.json" >/dev/null 2>&1 || return 1
  jq -c '{
      task_id: .task_id,
      title: (.title // ""),
      state: (.state // "unknown"),
      phase: (.phase // null),
      block_code: (.block_code // null),
      candidate_sha: (.candidate_sha // null),
      validated_sha: (.validated_sha // null),
      run_id: (.current_run_id // null),
      empty_candidate: (if .empty_candidate == true then true else false end),
      scope_source: (.scope_source // null),
      quiet_seconds: (if (.progress // null) == null then null else .progress.quiet_seconds end),
      log_bytes: (if (.progress // null) == null then null else .progress.bytes end),
      process_state: (.progress.process_state // null),
      observations_stale: (if .progress.observations_stale == true then true else false end)
    }' "$STATE_DIR/status.json" >"$STATE_DIR/row.json" 2>/dev/null || return 1
  [ -s "$STATE_DIR/row.json" ] || return 1
}

# 上一轮的同一任务行；没有就返回空（新任务 = 全部变化）。
previous_row() {
  task=$1
  [ -f "$SNAPSHOT" ] || return 0
  jq -c --arg t "$task" '[.tasks[]? | select(.task_id == $t)][0] // empty' "$SNAPSHOT" 2>/dev/null
}

changed_keys() {
  old=$1
  new=$2
  if [ -z "$old" ] || [ "$old" = "null" ]; then
    printf '["new"]'
    return 0
  fi
  jq -n -c --argjson a "$old" --argjson b "$new" '
    (($a | keys_unsorted) + ($b | keys_unsorted) | unique)
    | map(. as $k | select($a[$k] != $b[$k]) | $k)
  ' 2>/dev/null || printf '["unknown"]'
}

one_round() {
  round=$1
  now=$(date +%s)
  : >"$STATE_DIR/rows.ndjson"
  : >"$STATE_DIR/changes.ndjson"
  unreadable=0
  quota_blocked=0

  for task in $TARGETS; do
    if ! read_status "$task"; then
      unreadable=$((unreadable + 1))
      note "[warn] status unreadable: $task"
      continue
    fi
    row=$(cat "$STATE_DIR/row.json")
    old=$(previous_row "$task" || true)
    keys=$(changed_keys "$old" "$row")
    printf '%s\n' "$row" >>"$STATE_DIR/rows.ndjson"
    if [ "$keys" != "[]" ]; then
      jq -n -c --argjson ts "$now" --arg project "$PROJECT" \
             --argjson change "$keys" --argjson to "$row" \
             --argjson from "$( [ -n "$old" ] && printf '%s' "$old" || printf 'null' )" \
        '{ts: $ts, project: $project, task_id: $to.task_id,
          change: $change, from: $from, to: $to}' \
        >>"$STATE_DIR/changes.ndjson" 2>/dev/null
    fi
    if [ "$(printf '%s' "$row" | jq -r '.block_code // ""')" = "QUOTA_EXHAUSTED" ]; then
      quota_blocked=1
    fi
  done

  # 变化先落 jsonl 再更新快照：顺序反了会在中途崩溃时丢一条变化（与 monitor 的
  # "事件先落盘再推进游标"同一条理由）。
  if [ -s "$STATE_DIR/changes.ndjson" ]; then
    cat "$STATE_DIR/changes.ndjson" >>"$LIVE_JSONL"
  fi
  jq -s --argjson ts "$now" --arg project "$PROJECT" \
        --argjson round "$round" --argjson unreadable "$unreadable" \
        --argjson quota "$quota_blocked" \
    '{api_version: 1, project_id: $project, updated_at: $ts, round: $round,
      unreadable: $unreadable, quota_blocked: ($quota == 1), tasks: .}' \
    "$STATE_DIR/rows.ndjson" >"$STATE_DIR/snapshot.tmp" 2>/dev/null \
    && mv "$STATE_DIR/snapshot.tmp" "$SNAPSHOT"

  render_md "$round" "$now" "$unreadable" "$quota_blocked"
  return 0
}

render_md() {
  round=$1
  now=$2
  unreadable=$3
  quota_blocked=$4
  tmp="$STATE_DIR/live.md.tmp"
  {
    printf '# zoe watchd · %s\n\n' "$PROJECT"
    printf '守护 pid=%s · 启动 %s · 更新 %s（每 %ss，预算 %s）\n\n' \
      "$$" "$(stamp "$STARTED_AT")" "$(stamp "$now")" "$INTERVAL" \
      "$( [ "$MAX_SECONDS" -eq 0 ] && printf '不限' || printf '%ss' "$MAX_SECONDS" )"
    printf '> **只读守护**：只调用 `task status` / `task list`，不 start/resume/accept、不合并。\n'
    printf '> 它记录"现在是什么状态"，不判断"是否成功"；验收仍看 `task report` 与验收记录。\n\n'
    if [ "$quota_blocked" -eq 1 ]; then
      printf '## quota_blocked\n\n'
      printf '检测到 `QUOTA_EXHAUSTED`：项目级闸门生效，`start`/`resume` 会被拒绝。\n\n'
      printf -- '- 处置：等 `details.quota_reset_at`（或换账号）后 `project quota clear --project %s --why "..."`；\n' "$PROJECT"
      printf -- '- **不要 `resume` 试探额度**：要么被闸门拒绝，要么真的启动一次 Agent；\n'
      printf -- '- 已有成果不丢：worktree 与 handoff 原地保留（`task handoff show`）。\n\n'
    fi
    if [ "$unreadable" -gt 0 ]; then
      printf '> %s 个目标状态不可读（不等于失败，也不等于还在跑）。\n\n' "$unreadable"
    fi
    if [ -s "$SNAPSHOT" ]; then
      jq -r '
        def dur: if . == null then "-" elif . < 60 then "\(.|floor)s"
                 elif . < 3600 then "\((. / 60)|floor)m"
                 else "\((. / 3600)|floor)h" end;
        def kb: if . == null then "-" else "\((. / 1024)|floor)KB" end;
        def sha: if . == null then "-" else .[0:12] end;
        .tasks[] |
        "### \(.title // .task_id) `\(.task_id)`\n",
        "- \(.state) · \(.phase // "?") · 静默 \(.quiet_seconds | dur) · 日志 \(.log_bytes | kb)",
        "- run `\(.run_id // "-")` · 候选 \(.candidate_sha | sha) · 已验证 \(.validated_sha | sha)",
        ( if .block_code != null then "- 阻断：`\(.block_code)`" else empty end ),
        ( if .empty_candidate then "- empty_candidate：候选与 base 相同，无可交付改动" else empty end ),
        ( if .observations_stale then "- 观测已过期（监控进程失联，需重新对账，不是任务失败）" else empty end ),
        ""
      ' "$SNAPSHOT"
    fi
    printf '<!-- zoe-watchd project=%s pid=%s round=%s updated_at=%s -->\n' \
      "$PROJECT" "$$" "$round" "$now"
  } >"$tmp" 2>/dev/null && mv "$tmp" "$LIVE_MD"
}

stamp() {
  date -r "$1" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -d "@$1" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || printf '%s' "$1"
}

# --------------------------------------------------------------------------- #
# 循环                                                                        #
# --------------------------------------------------------------------------- #

cleanup() {
  reason=${STOP_REASON:-signal}
  if [ -f "$LIVE_MD" ]; then
    printf '\n> 守护已停止（reason=%s，%s）。历史变化见 `%s`。\n' \
      "$reason" "$(stamp "$(date +%s)")" "$LIVE_JSONL" >>"$LIVE_MD" 2>/dev/null
  fi
  release_lock
}

cmd_run() {
  # start 在 detach 之前无法知道子进程 pid，所以锁里先写 pending；run 启动后
  # 把自己写成 owner。已有具体 holder（不是 pending、也不是自己）时拒绝：那是
  # 第二个守护。
  own=$(lock_holder)
  if [ -n "$own" ] && [ "$own" != "pending" ] && [ "$own" != "$$" ]; then
    die 3 "another watchd owns the lock (holder=$own)"
  fi
  [ -d "$LOCK" ] || die 3 "no lock; start it with: $0 start --project $PROJECT"
  printf '%s\n' "$$" >"$LOCK/pid" 2>/dev/null || die 3 "cannot write lock owner"
  STARTED_AT=$(cat "$LOCK/started_at" 2>/dev/null || date +%s)
  trap 'STOP_REASON=${STOP_REASON:-term}; cleanup; exit 0' INT TERM
  trap 'cleanup' EXIT
  note "[start] project=$PROJECT pid=$$ interval=${INTERVAL}s max=${MAX_SECONDS}s dir=$STATE_DIR"
  refresh_targets
  round=0
  while :; do
    round=$((round + 1))
    now=$(date +%s)
    if [ -f "$STOP_FILE" ]; then
      STOP_REASON=stop_requested
      rm -f "$STOP_FILE"
      note "[stop] stop.request observed"
      cleanup
      trap - EXIT
      exit 0
    fi
    if [ "$MAX_SECONDS" -gt 0 ] && [ $((now - STARTED_AT)) -ge "$MAX_SECONDS" ]; then
      STOP_REASON=budget_exhausted
      note "[stop] max-seconds reached"
      cleanup
      trap - EXIT
      exit 0
    fi
    if [ "$round" -gt 1 ] && [ $(( (round - 1) % REFRESH_EVERY )) -eq 0 ]; then
      refresh_targets
    fi
    one_round "$round"
    [ "$DEBUG_CALLS" -eq 1 ] && note "[calls] round=$round calls=$CALLS"
    sleep "$INTERVAL"
  done
}

# --------------------------------------------------------------------------- #
# start / stop / status                                                       #
# --------------------------------------------------------------------------- #

cmd_start() {
  holder=$(lock_holder)
  if alive_owner "$holder"; then
    note "[busy] watchd already running (pid=$holder); see $LIVE_MD"
    exit 3
  fi
  # 预占锁；忙碌时 acquire_lock 返回 3，必须原样退出——吞掉返回码就会起第二个守护。
  acquire_lock "pending" || exit 3
  if [ ! -d "$LOCK" ]; then
    die 3 "cannot acquire lock: $LOCK"
  fi
  mkdir -p "$STATE_DIR"
  : >"$RUN_LOG"
  args=(--project "$PROJECT" --interval "$INTERVAL" --max-seconds "$MAX_SECONDS"
        --state-dir "$STATE_DIR")
  [ -n "$TARGETS" ] && args+=(--targets "$TARGETS")
  [ -n "$TARGETS_FILE" ] && args+=(--targets-file "$TARGETS_FILE")
  [ "$DEBUG_CALLS" -eq 1 ] && args+=(--debug-calls)
  nohup "$0" run "${args[@]}" >>"$RUN_LOG" 2>&1 &
  child=$!
  printf '%s\n' "$child" >"$LOCK/pid"
  printf '%s\n' "$(date +%s)" >"$LOCK/started_at"
  printf '%s\n' "$PROJECT" >"$LOCK/project"

  # AC1：第一版必须在 30 秒内出现，否则 start 不假装成功。
  waited=0
  while [ "$waited" -lt 30 ]; do
    if [ -f "$LIVE_MD" ]; then
      printf '[ready] pid=%s live=%s jsonl=%s\n' "$child" "$LIVE_MD" "$LIVE_JSONL"
      [ "$DEBUG_CALLS" -eq 1 ] && note "[calls] start_wait=${waited}s"
      return 0
    fi
    if ! alive_owner "$child"; then
      break
    fi
    sleep 1
    waited=$((waited + 1))
  done
  note "[error] watchd did not produce live.md within ${waited}s"
  tail -n 20 "$RUN_LOG" 2>/dev/null >&2 || true
  exit 4
}

cmd_stop() {
  holder=$(lock_holder)
  if ! alive_owner "$holder"; then
    # 进程不在但锁还在：这就是"陈旧锁"，stop 也应该能收拾。
    if [ -d "$LOCK" ]; then
      note "[heal] removing stale lock (pid=${holder:-none})"
      rm -rf "$LOCK"
    fi
    note "[stopped] no running watchd"
    return 0
  fi
  mkdir -p "$STATE_DIR"
  : >"$STOP_FILE"
  waited=0
  while [ "$waited" -lt "$TIMEOUT" ]; do
    if ! alive_owner "$holder"; then
      rm -rf "$LOCK"
      printf '[stopped] pid=%s\n' "$holder"
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
  done
  note "[warn] graceful stop timed out; sending TERM to $holder"
  kill -TERM "$holder" 2>/dev/null || true
  waited=0
  while [ "$waited" -lt 5 ]; do
    alive_owner "$holder" || { rm -rf "$LOCK"; printf '[stopped] pid=%s (term)\n' "$holder"; return 0; }
    sleep 1
    waited=$((waited + 1))
  done
  note "[warn] still alive; sending KILL to $holder"
  kill -KILL "$holder" 2>/dev/null || true
  sleep 1
  if alive_owner "$holder"; then
    die 4 "cannot stop watchd pid=$holder"
  fi
  rm -rf "$LOCK"
  printf '[stopped] pid=%s (kill)\n' "$holder"
}

cmd_status() {
  holder=$(lock_holder)
  running=0
  alive_owner "$holder" && running=1
  updated=""
  [ -f "$LIVE_MD" ] && updated=$(stat -f %m "$LIVE_MD" 2>/dev/null || stat -c %Y "$LIVE_MD" 2>/dev/null || true)
  lines=0
  [ -f "$LIVE_JSONL" ] && lines=$(wc -l <"$LIVE_JSONL" 2>/dev/null | tr -d ' ')
  quota=0
  if [ -f "$SNAPSHOT" ]; then
    jq -e '.quota_blocked == true' "$SNAPSHOT" >/dev/null 2>&1 && quota=1
  fi
  if [ "$JSON_OUT" -eq 1 ]; then
    jq -n --arg project "$PROJECT" --arg dir "$STATE_DIR" --arg pid "${holder:-}" \
          --argjson running "$running" --argjson lines "$lines" --argjson quota "$quota" \
          --arg updated "${updated:-}" \
      '{api_version: 1, project_id: $project, running: ($running == 1), pid: (if $pid == "" then null else ($pid|tonumber?) end),
        state_dir: $dir, live_md: ($dir + "/live.md"), live_jsonl: ($dir + "/live.jsonl"),
        jsonl_lines: $lines, last_update_epoch: (if $updated == "" then null else ($updated|tonumber) end),
        quota_blocked: ($quota == 1)}'
    return 0
  fi
  if [ "$running" -eq 1 ]; then
    printf 'running pid=%s\n' "$holder"
  else
    printf 'stopped\n'
  fi
  printf 'state_dir=%s\nlive_md=%s\nlive_jsonl=%s\nlines=%s\n' "$STATE_DIR" "$LIVE_MD" "$LIVE_JSONL" "$lines"
  [ "$quota" -eq 1 ] && printf 'quota_blocked=true\n'
  return 0
}

case "$ACTION" in
  start)
    if [ "$NO_DETACH" -eq 1 ]; then
      acquire_lock "pending" || exit $?
      cmd_run
    else
      cmd_start
    fi
    ;;
  run)
    cmd_run
    ;;
  stop)
    cmd_stop
    ;;
  status)
    cmd_status
    ;;
esac

if [ "$DEBUG_CALLS" -eq 1 ]; then
  printf '[calls] total=%s\n' "$CALLS" >&2
fi
