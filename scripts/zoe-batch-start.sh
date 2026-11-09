#!/usr/bin/env bash
# zoe-batch-start.sh — 批量派发：生成请求 + 按失败码分流 + 逐条落盘结果。
#
# 为什么需要它（而不是"写个 for 循环"）：
#   `task start <TASK>` 的主体（task）来自 argv，幂等键（request_id）来自请求文件。
#   两者可以静默错配：同一份文件配到第二个任务上，返回的是 REQUEST_CONFLICT，
#   而错误体过去既不说被谁占用，也不说该怎么办。手工批次必然走到这一步
#   （实测记录：t8a-start-20261104 → T8f、t8a-start-v2 → T8e、t9a-start → T9d，
#   每个错配都要人再造一个 -v2/-v3 后缀）。
#
# 三条边界，写在这里避免误用：
#   1. 只派发，不判断成败：`start` 返回 accepted 不代表 worker 跑完。
#      "跑完了吗"仍由 `task status --refresh` / `zoe-monitor.sh` 回答。
#   2. 不做"失败就换 id 重试"。失败码决定动作（见 classify 表），
#      REQUEST_CONFLICT 一律不重试——那是在掩盖"文件配错任务"。
#   3. 不猜执行配置：不传 agent_profile，由项目策略与请求决定。
#
# 用法：
#   bash zoe-batch-start.sh --project P --plan plan.json [--out DIR] [--json]
#                           [--wait-slots SECONDS]
#
# plan.json：
#   {"items": [{"task_id": "task-…", "label": "T9a", "strategy": "auto"}]}
#   （也接受裸数组 [...]；label 缺省用 task_id，strategy 缺省 auto）
#
# 输出：
#   <out>/results.jsonl   每个任务一行（NDJSON），stdout 同步打印同样的行
#   <out>/manifest.jsonl  每次实际提交的请求文件与其所属任务（事后核对用）
#   <out>/<T>.start-<row_version>[-<n>].json   请求文件
#
# 退出码：
#   0  全部 dispatched / dispatch_pending
#   2  用法或依赖错误（缺 jq / 缺 --project / plan 不可解析）
#   10 有需要人处理的项（冲突 / 阻塞 / 环境 / 预算 / 状态）
#
# 依赖：jq、可执行的 zoe（ZOE_BIN 覆盖）。不依赖 GNU 工具，macOS 自带 bash 3.2 可跑。

set -u
set -o pipefail

ZOE_BIN=${ZOE_BIN:-zoe}
PROJECT=""
PLAN=""
OUT=""
JSON_OUT=0
WAIT_SLOTS=0
SLOT_POLL_SECONDS=5

usage() {
  cat <<'EOF'
用法: zoe-batch-start.sh --project P --plan plan.json [options]

  --project P        项目 ID（必需）
  --plan F           批量计划 JSON（必需）
  --out DIR          产物目录（默认 .zoe/<project>/batch）
  --json             只输出 NDJSON（stdout 与 results.jsonl 同内容）
  --wait-slots N     SLOT_BUSY 时最多等待 N 秒：每 5s 用**新 request_id** 重试一次
                     （旧 id 已被记为失败，重放只会拿回那条失败记录）
  -h, --help         显示帮助

环境变量：ZOE_BIN（默认 zoe）
退出码：0 全部受理 / 2 用法或依赖 / 10 有需人处理项
EOF
}

die_usage() {
  printf '[error] %s\n' "$1" >&2
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --project) PROJECT=${2:-}; shift 2 ;;
    --plan) PLAN=${2:-}; shift 2 ;;
    --out) OUT=${2:-}; shift 2 ;;
    --json) JSON_OUT=1; shift ;;
    --wait-slots) WAIT_SLOTS=${2:-}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die_usage "unknown argument: $1" ;;
  esac
done

[ -n "$PROJECT" ] || die_usage "--project is required"
[ -n "$PLAN" ] || die_usage "--plan is required"
[ -f "$PLAN" ] || die_usage "plan not found: $PLAN"
case "$WAIT_SLOTS" in ''|*[!0-9]*) die_usage "--wait-slots must be a non-negative integer" ;; esac
[ "$WAIT_SLOTS" -eq 0 ] || [ "$WAIT_SLOTS" -ge "$SLOT_POLL_SECONDS" ] \
  || die_usage "--wait-slots must be 0 or >= $SLOT_POLL_SECONDS"
command -v jq >/dev/null 2>&1 || die_usage "jq is required"
command -v "$ZOE_BIN" >/dev/null 2>&1 || die_usage "zoe not found: $ZOE_BIN"

[ -n "$OUT" ] || OUT=".zoe/$PROJECT/batch"
mkdir -p "$OUT" || die_usage "cannot create output dir: $OUT"
RESULTS="$OUT/results.jsonl"
MANIFEST="$OUT/manifest.jsonl"
: >"$RESULTS" || die_usage "cannot write $RESULTS"
: >"$MANIFEST" || die_usage "cannot write $MANIFEST"

# 计划必须是 `.items[]` 或裸数组；解析失败在启动期就停，不要跑到第三个任务才炸。
ITEMS=$(jq -c 'if type == "object" then (.items // []) elif type == "array" then . else [] end' "$PLAN" 2>/dev/null) \
  || die_usage "plan is not valid JSON: $PLAN"
COUNT=$(printf '%s' "$ITEMS" | jq 'length')
[ "$COUNT" -gt 0 ] || die_usage "plan has no items"

# 8 位随机后缀：uuidgen 最省事，退到 python3，再退到 $RANDOM + 时间。
# 不用纯时间戳：同一秒内四个任务会撞 id，而撞 id 的表现正是 REQUEST_CONFLICT。
rand8() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen | tr -d '-' | cut -c1-8
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c 'import uuid; print(uuid.uuid4().hex[:8])'
  else
    printf '%04x%04x' "$RANDOM" "$RANDOM"
  fi
}

# 一行结果：NDJSON + stdout。字段固定，宿主不必按位置解析。
emit() {
  # $1 label $2 task $3 request_id $4 outcome $5 code $6 detail
  line=$(jq -nc \
    --arg label "$1" --arg task "$2" --arg request_id "$3" \
    --arg outcome "$4" --arg code "$5" --arg detail "$6" \
    '{label:$label, task_id:$task, request_id:$request_id,
      outcome:$outcome, error_code:(if $code == "" then null else $code end),
      detail:(if $detail == "" then null else $detail end)}')
  printf '%s\n' "$line" >>"$RESULTS"
  if [ "$JSON_OUT" -eq 1 ]; then
    printf '%s\n' "$line"
  fi
}

note() {
  [ "$JSON_OUT" -eq 1 ] && return 0
  printf '%s\n' "$*"
}

# 请求体由脚本生成，不做任何"复用上次的文件"：幂等键必须与这次的 task + 载荷匹配。
# $1 task $2 row_version $3 authorization_ref $4 strategy $5 request_id $6 path
write_request() {
  jq -nc \
    --arg request_id "$5" \
    --arg auth "$3" \
    --arg strategy "$4" \
    --argjson version "$2" \
    '{schema_version: 2, request_id: $request_id,
      expected_version: $version, authorization_ref: $auth, strategy: $strategy}' \
    >"$6"
}

NEED_HUMAN=0
OK=0

i=0
while [ "$i" -lt "$COUNT" ]; do
  item=$(printf '%s' "$ITEMS" | jq -c ".[$i]")
  i=$((i + 1))
  task=$(printf '%s' "$item" | jq -r '.task_id // empty')
  label=$(printf '%s' "$item" | jq -r '.label // .task_id // "item"')
  strategy=$(printf '%s' "$item" | jq -r '.strategy // "auto"')
  if [ -z "$task" ]; then
    note "[skip] item $i 没有 task_id"
    emit "$label" "" "" skipped "INPUT_INCOMPLETE" "item has no task_id"
    NEED_HUMAN=1
    continue
  fi

  # 派发前先读一次权威状态（`--refresh` 才能看到"进程已退出"这类对账结论）。
  status=$("$ZOE_BIN" task status "$task" --json --refresh 2>/dev/null)
  if [ -z "$status" ] || ! printf '%s' "$status" | jq -e . >/dev/null 2>&1; then
    note "[fail] $label 读不到状态（不派发：不知道它现在是什么）"
    emit "$label" "$task" "" unreadable "STATE_UNREADABLE" "task status failed"
    NEED_HUMAN=1
    continue
  fi

  state=$(printf '%s' "$status" | jq -r '.state // ""')
  block=$(printf '%s' "$status" | jq -r '.block_code // ""')
  version=$(printf '%s' "$status" | jq -r '.row_version // 0')
  auth=$(printf '%s' "$status" | jq -r '.config.authorization_ref // ""')

  if [ "$block" = "INPUT_REQUIRED" ]; then
    note "[skip] $label 在等回答：先 task answer（start 会重跑 agent 而拿不到答案）"
    emit "$label" "$task" "" skipped "INPUT_REQUIRED" "answer the pending questions first"
    NEED_HUMAN=1
    continue
  fi
  if [ "$block" = "PROCESS_UNKNOWN" ]; then
    note "[skip] $label 执行归属不明：先 task recover --confirm-stop 对账"
    emit "$label" "$task" "" skipped "PROCESS_UNKNOWN" "reconcile before dispatching"
    NEED_HUMAN=1
    continue
  fi
  if [ -z "$state" ]; then
    # status 返回了 JSON 但没有 state：多半是任务不存在（错误体）或记录损坏。
    # 不套用下面的 STATE_CONFLICT 分支，否则会写成"state= 不可派发"这种误导性结论。
    errcode=$(printf '%s' "$status" | jq -r '.error.code // empty' 2>/dev/null)
    note "[fail] ${label} 读不到状态：${errcode:-no state field}"
    emit "$label" "$task" "" unreadable "${errcode:-STATE_UNREADABLE}" \
      "task status returned no state field"
    NEED_HUMAN=1
    continue
  fi
  case "$state" in
    READY|PAUSED|BLOCKED) : ;;
    *)
      note "[skip] $label state=$state 不可派发"
      emit "$label" "$task" "" skipped "STATE_CONFLICT" "state=$state is not resumable"
      NEED_HUMAN=1
      continue
      ;;
  esac
  if [ -z "$auth" ]; then
    note "[fail] $label 任务记录里没有 authorization_ref（配置损坏）"
    emit "$label" "$task" "" failed "AUTH_REQUIRED" "task record has no authorization_ref"
    NEED_HUMAN=1
    continue
  fi

  attempt=1
  # reuse=1 表示"重放上一次那份请求"（同 id、同载荷）。只有 TASK_BUSY 会置位：
  # 它在写 intent 之前就失败，请求行没落地，所以重放等价于第一次提交，
  # 而且同 id 还能让运行时把那 1 秒内的并发重复请求认成 dispatch_pending。
  reuse=0
  slot_deadline=$(( $(date +%s) + WAIT_SLOTS ))
  while :; do
    if [ "$reuse" -eq 0 ]; then
      request_id="$task-start-$(date +%Y%m%d)-$(rand8)"
      file="$OUT/$task.start-$version-$attempt.json"
      write_request "$task" "$version" "$auth" "$strategy" "$request_id" "$file" \
        || die_usage "cannot write request file: $file"
      # manifest 是"文件属于哪个任务"的独立证据：错配时能立刻指出来。
      jq -nc --arg file "$file" --arg task "$task" --arg request_id "$request_id" \
        '{request_file:$file, task_id:$task, request_id:$request_id,
          expected_version:($version|tonumber), attempt:($attempt|tonumber)}' \
        --argjson version "$version" --argjson attempt "$attempt" >>"$MANIFEST"
    fi

    out=$("$ZOE_BIN" task start "$task" --request-file "$file" 2>&1)
    rc=$?
    code=$(printf '%s' "$out" | jq -r '.error.code // empty' 2>/dev/null) || code=""

    if [ "$rc" -eq 0 ] && [ -z "$code" ]; then
      dispatch=$(printf '%s' "$out" | jq -r '.dispatch_pending // false' 2>/dev/null)
      if [ "$dispatch" = "true" ]; then
        note "[start] $label 已受理但未确认起进程（dispatch_pending）——由监控跟进"
        emit "$label" "$task" "$request_id" dispatch_pending "" "dispatch_pending=true"
      else
        note "[start] $label 已派发（run=$(printf '%s' "$out" | jq -r '.run_id // "none"')）"
        emit "$label" "$task" "$request_id" dispatched "" ""
      fi
      OK=$((OK + 1))
      break
    fi

    case "$code" in
      TASK_BUSY)
        # 写者锁被占：请求行**没有**写下来，原样重放等价于第一次提交。
        # 同 id 重放还可能自愈成 dispatch_pending（运行时有 1 秒重探），
        # 换成新 id 反而会拿到硬 TASK_BUSY 并制造第二条派发路径。
        if [ "$attempt" -lt 3 ]; then
          attempt=$((attempt + 1))
          reuse=1
          sleep 2
          continue
        fi
        note "[busy] $label 写者锁一直被占：先 status --refresh + task recover 对账，不要起第二个写者"
        emit "$label" "$task" "$request_id" busy "TASK_BUSY" "writer lock held after 3 attempts"
        NEED_HUMAN=1
        break
        ;;
      SLOT_BUSY)
        if [ "$WAIT_SLOTS" -gt 0 ] && [ "$(date +%s)" -lt "$slot_deadline" ]; then
          note "[slot] $label 槽位已满，${SLOT_POLL_SECONDS}s 后换新 id 重试"
          sleep "$SLOT_POLL_SECONDS"
          attempt=$((attempt + 1))
          reuse=0
          continue
        fi
        note "[slot] $label 槽位已满（${code}）。旧 id 已被记为失败，等的应是一条**新**请求"
        emit "$label" "$task" "$request_id" slot_busy "SLOT_BUSY" "active runs reached max_active_tasks"
        NEED_HUMAN=1
        break
        ;;
      REQUEST_CONFLICT)
        # 不重试。这个 id 已经被**另一个载荷**（多半是另一任务的请求文件）占用。
        owner=$(printf '%s' "$out" | jq -r '.error.details.existing.task_id // empty' 2>/dev/null)
        note "[conflict] $label request_id=$request_id 已被占用（task=${owner:-未知}）；不自动换 id"
        emit "$label" "$task" "$request_id" conflict "REQUEST_CONFLICT" \
          "id owned by task=${owner:-unknown}; regenerate instead of retrying"
        NEED_HUMAN=1
        break
        ;;
      STATE_CONFLICT)
        # 版本前进/状态变化：重新读状态再决定，脚本不猜 expected_version。
        note "[state] $label 状态已变（${code}）：重跑 status 后新建请求（本脚本不自动续跑）"
        emit "$label" "$task" "$request_id" state_conflict "STATE_CONFLICT" \
          "re-read status and generate a new request"
        NEED_HUMAN=1
        break
        ;;
      "")
        note "[fail] $label 无法解析返回（exit=${rc}）：$out"
        emit "$label" "$task" "$request_id" failed "" "unparsable response"
        NEED_HUMAN=1
        break
        ;;
      *)
        # ENVIRONMENT_ERROR / POLICY_* / AUTH_* / ALLOWLIST_*：重试没有意义。
        detail=$(printf '%s' "$out" | jq -r '.error.message // empty' 2>/dev/null)
        note "[fail] $label ${code}：$detail"
        emit "$label" "$task" "$request_id" failed "$code" "$detail"
        NEED_HUMAN=1
        break
        ;;
    esac
  done

done

# start 之后必须逐个确认：accepted 只表示受理（SKILL 第 6 步），
# 所以这里再读一次 state，把"没动"与"在跑"分开。
note ""
note "[batch] ok=$OK total=$COUNT results=$RESULTS manifest=$MANIFEST"
note "        下一步：逐条核对 state，再交给监控循环（zoe-monitor.sh）"

if [ "$NEED_HUMAN" -ne 0 ]; then
  exit 10
fi
exit 0
