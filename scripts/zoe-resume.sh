#!/usr/bin/env bash
# zoe-resume.sh — 恢复请求的**两段式**薄入口（v1.5.2 §S2）
#
# 职责边界（脚本纪律 §4.3）：
#   * `preview` 只构造请求并落盘，不提交、不改任务；
#   * `apply` 只把**给定文件原样**提交给 `zoe task resume`，不重建请求、不改版本；
#     它先用文件自身的 `self_sha256` 核对"要提交的还是用户看过的那一份"——手改
#     `expected_version` 是最危险的一处改动，必须在校验层被拦下；
#   * 它不决定"该不该 resume"，不实现状态校验/错误码映射/配置解析/授权逻辑
#     —— 那些是运行时的职责，这里只做"读一次、看一眼、拼一个文件"。
#
# 为什么是两段：
#   1. `task resume` 的请求体是**四要素 + 幂等哈希**
#      （schema_version / request_id / expected_version / authorization_ref），
#      幂等键是 digest([action, task, request])：**同一个 request_id 改了载荷**
#      会得到 REQUEST_CONFLICT，而不是"重试"。
#   2. 所以要区分两种"重来"：
#      同一请求传输失败/响应丢失 → 保留原 request_id 与原载荷**重放**（`apply`
#      同一个文件，幂等）；确实是一次新意图（版本前进后重来）→ **重新 preview**，
#      生成新 request_id。
#   3. `expected_version` 必须取**这次** `status --refresh` 的 `row_version`：
#      复用上一轮输出，等于拿旧认知去撞乐观并发控制。
#
# 退出码（稳定，宿主可分支）：
#   0  成功（preview 落盘 / apply 已提交）
#   2  用法或依赖错误（缺 --project/--task、缺 jq、zoe 不可用、参数形态不对）
#   3  前置条件不满足，**未生成/未提交**：
#      state 不可恢复 / block_code=INPUT_REQUIRED（先 task answer）/
#      block_code=PROCESS_UNKNOWN（先对账）/ apply 撞 STATE_CONFLICT（版本已前进，
#      重跑 preview）/ 请求文件不是本脚本生成的形状
#   4  运行时拒绝且不属于上面可分支的几种（打印原始 error.code；不重试、不自动补救）
#
# 用法：
#   bash <skill-dir>/scripts/zoe-resume.sh preview --project P --task T \
#     [--strategy auto|workspace] [--reason TEXT] [--authorization-ref R] [--out DIR]
#   bash <skill-dir>/scripts/zoe-resume.sh apply --request-file F [--json]
#
# 预览不会自动提交：`apply` 必须在**用户看过** preview 的输出之后才运行。

set -u
set -o pipefail

ZOE_BIN=${ZOE_BIN:-zoe}

usage() {
  cat <<'EOF'
Usage:
  zoe-resume.sh preview --project P --task T [options]
      --strategy S          auto(默认) / workspace
      --reason TEXT         写进请求的 reason（给人看的短句）
      --authorization-ref R 缺省取任务冻结配置的 authorization_ref
      --out DIR             请求文件目录（默认 .zoe/<P>/requests）
    → 只落盘请求文件 + 打印摘要（state/block_code/row_version/strategy），**不提交**

  zoe-resume.sh apply --request-file F [--json]
    → 原样提交该文件（不改 id、不改载荷）；打印返回的 state/row_version
    → STATE_CONFLICT：提示"版本已前进，重跑 preview"，**不自动改用新版本**

退出码：0 成功 / 2 用法依赖 / 3 前置条件不满足（未生成未提交）/ 4 运行时拒绝。
环境变量：ZOE_BIN（默认 zoe）。
EOF
}

die() {  # $1=exit code $2=message
  printf '[error] %s\n' "$2" >&2
  exit "$1"
}

note() { printf '%s\n' "$*"; }

need_jq() {
  command -v jq >/dev/null 2>&1 || die 2 "jq is required"
  command -v "$ZOE_BIN" >/dev/null 2>&1 || die 2 "zoe not found: $ZOE_BIN"
}

# 摘要工具：两段式要求 `apply` 能判断"文件还是 preview 写的那一份"。
need_sha() {
  if command -v sha256sum >/dev/null 2>&1; then
    SHA_CMD="sha256sum"
  elif command -v shasum >/dev/null 2>&1; then
    SHA_CMD="shasum -a 256"
  else
    die 2 "need sha256sum or shasum to bind the request file to what gets submitted"
  fi
}

# 摘要口径两侧一致：`jq -S` 稳定键序 + 命令替换去掉尾部换行。
sha_of_text() {  # $1=canonical text
  printf '%s' "$1" | $SHA_CMD | awk '{print $1}'
}

new_request_id() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen | tr '[:upper:]' '[:lower:]'
    return 0
  fi
  # 没有 uuidgen 也要有可用的幂等键：时间戳 + pid + 随机数足以避免碰撞，
  # 而且它只在本机的一次请求里用一次。
  printf '%s-%s-%s' "$(date +%s)" "$$" "${RANDOM:-0}"
}

# 读一次权威状态：`--refresh` 会先对账再返回，版本号因此是"现在"的。
read_status() {  # $1=task ; 输出一行 JSON，失败返回非零
  "$ZOE_BIN" task status "$1" --json --refresh 2>/dev/null
}

# --------------------------------------------------------------------------- #
# preview                                                                     #
# --------------------------------------------------------------------------- #
cmd_preview() {
  PROJECT=""
  TASK=""
  STRATEGY="auto"
  REASON=""
  AUTH_REF=""
  OUT=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --project) PROJECT=${2:-}; shift 2 ;;
      --task) TASK=${2:-}; shift 2 ;;
      --strategy) STRATEGY=${2:-}; shift 2 ;;
      --reason) REASON=${2:-}; shift 2 ;;
      --authorization-ref) AUTH_REF=${2:-}; shift 2 ;;
      --out) OUT=${2:-}; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) die 2 "unknown argument: $1" ;;
    esac
  done
  [ -n "$PROJECT" ] || die 2 "--project is required"
  [ -n "$TASK" ] || die 2 "--task is required"
  case "$STRATEGY" in
    auto|workspace) ;;
    *) die 2 "--strategy must be auto or workspace (native is not implemented)" ;;
  esac
  need_jq
  [ -n "$OUT" ] || OUT=".zoe/$PROJECT/requests"

  status=$(read_status "$TASK") || die 4 "task status failed for $TASK"
  printf '%s' "$status" | jq -e . >/dev/null 2>&1 || die 4 "task status returned non-JSON"

  # 闸门逐条判，**先判再落盘**：前置条件不满足时不留一个"看起来能提交"的文件。
  state=$(printf '%s' "$status" | jq -r '.state // ""')
  block=$(printf '%s' "$status" | jq -r '.block_code // ""')
  version=$(printf '%s' "$status" | jq -r '.row_version // empty')
  project_of_task=$(printf '%s' "$status" | jq -r '.project_id // ""')

  [ -n "$version" ] || die 3 "task record has no row_version; cannot build expected_version"
  [ "$project_of_task" = "$PROJECT" ] || die 3 "task $TASK belongs to ${project_of_task:-<unknown>}, not $PROJECT"

  case "$state" in
    READY|PAUSED|BLOCKED) ;;
    *) die 3 "state=$state is not resumable (only READY / PAUSED / BLOCKED)" ;;
  esac
  if [ "$block" = "INPUT_REQUIRED" ]; then
    die 3 "block_code=INPUT_REQUIRED：先用 \`zoe task answer\` 回答待答问题；直接 resume 会重跑而没有答案"
  fi
  if [ "$block" = "PROCESS_UNKNOWN" ]; then
    die 3 "block_code=PROCESS_UNKNOWN：先对账并 \`zoe task recover TASK --confirm-stop\`；观测不到旧写者不是放行条件"
  fi

  if [ -z "$AUTH_REF" ]; then
    # 任务记录冻结的是**当时**的授权引用：用项目当前配置会撞 AUTH_REQUIRED。
    AUTH_REF=$(printf '%s' "$status" | jq -r '.config.authorization_ref // ""')
  fi
  [ -n "$AUTH_REF" ] || die 3 "no authorization_ref in the task config; pass --authorization-ref explicitly"

  request_id=$(new_request_id) || die 2 "cannot generate a request id"
  need_sha
  mkdir -p "$OUT" || die 2 "cannot create $OUT"
  file="$OUT/resume-$TASK-$request_id.json"

  body=$(jq -S -n \
    --arg request_id "$request_id" \
    --arg task "$TASK" \
    --arg project "$PROJECT" \
    --arg auth "$AUTH_REF" \
    --arg strategy "$STRATEGY" \
    --arg reason "$REASON" \
    --argjson version "$version" \
    '{
       schema_version: 1,
       request_id: $request_id,
       task_id: $task,
       project_id: $project,
       expected_version: $version,
       authorization_ref: $auth,
       authorized_actions: ["execute"],
       strategy: $strategy,
       reason: (if $reason == "" then "resume after interruption" else $reason end)
     }') || die 2 "cannot build the request body"
  # 文件自身的摘要：`apply` 用它判断"要提交的还是用户看过的那一份"。少了这一步，
  # 手改一个 `expected_version` 也能通过，而那正是最危险的一处改动。
  sum=$(sha_of_text "$body")
  printf '%s' "$body" | jq --arg sum "$sum" '. + {self_sha256: $sum}' >"$file" \
    || die 2 "cannot write $file"

  note "[preview] task=$TASK project=$PROJECT state=$state block=${block:-none} row_version=$version strategy=$STRATEGY"
  note "[preview] request=$file"
  note "[preview] 这不是提交。确认摘要无误后再运行："
  note "          bash $(basename "$0") apply --request-file $file"
  return 0
}

# --------------------------------------------------------------------------- #
# apply                                                                       #
# --------------------------------------------------------------------------- #
cmd_apply() {
  REQUEST_FILE=""
  JSON=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --request-file) REQUEST_FILE=${2:-}; shift 2 ;;
      --json) JSON=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die 2 "unknown argument: $1" ;;
    esac
  done
  [ -n "$REQUEST_FILE" ] || die 2 "--request-file is required"
  [ -f "$REQUEST_FILE" ] || die 2 "request file not found: $REQUEST_FILE"
  need_jq
  need_sha
  printf '%s' "$(cat "$REQUEST_FILE")" | jq -e . >/dev/null 2>&1 \
    || die 3 "$REQUEST_FILE is not valid JSON"

  task=$(jq -r '.task_id // ""' "$REQUEST_FILE")
  [ -n "$task" ] || die 3 "$REQUEST_FILE has no task_id (only files written by \`preview\` are accepted)"

  # 文件没被改过：摘要只覆盖"除 self_sha256 以外的内容"，与 preview 写入时同口径。
  stored=$(jq -r '.self_sha256 // ""' "$REQUEST_FILE")
  [ -n "$stored" ] || die 3 "$REQUEST_FILE has no self_sha256 (only files written by \`preview\` are accepted)"
  stripped=$(jq -S 'del(.self_sha256)' "$REQUEST_FILE") || die 3 "$REQUEST_FILE cannot be canonicalised"
  [ "$stored" = "$(sha_of_text "$stripped")" ] \
    || die 3 "请求文件在 preview 后被修改过（self_sha256 不匹配）；重跑 preview，不要手改 expected_version"

  # 原样提交：不重建、不改 id、不改载荷。运行时仍会在锁内重算幂等哈希，
  # 因此"同一文件重放"返回同一结果，而"改了载荷再用同一 id"是 REQUEST_CONFLICT。
  if ! out=$("$ZOE_BIN" task resume "$task" --request-file "$REQUEST_FILE" 2>&1); then
    printf '%s\n' "$out" >&2
    code=$(printf '%s' "$out" | jq -r '.error.code // ""' 2>/dev/null || true)
    case "$code" in
      STATE_CONFLICT)
        die 3 "STATE_CONFLICT：版本已前进（或被别处推进）。重跑 preview 生成新请求；**不要**手改 expected_version"
        ;;
      REQUEST_CONFLICT)
        die 3 "REQUEST_CONFLICT：这个 request_id 已被不同的载荷用过。新意图必须新请求（重新 preview）"
        ;;
      PROCESS_UNKNOWN)
        die 3 "PROCESS_UNKNOWN：旧写者不可观测，先对账并 task recover --confirm-stop"
        ;;
      INPUT_REQUIRED)
        die 3 "INPUT_REQUIRED：先用 task answer 回答待答问题"
        ;;
      *)
        die 4 "runtime refused the request${code:+ ($code)}"
        ;;
    esac
  fi

  if [ "$JSON" -eq 1 ]; then
    printf '%s\n' "$out"
    return 0
  fi
  printf '%s' "$out" | jq -r '"[apply] task=\(.task_id // "?") state=\(.state // "?") block=\(.block_code // "none") row_version=\(.row_version // "?") run=\(.current_run_id // "-")"' 2>/dev/null \
    || printf '%s\n' "$out"
  return 0
}

main() {
  [ $# -gt 0 ] || { usage >&2; exit 2; }
  action=$1
  shift
  case "$action" in
    preview) cmd_preview "$@" ;;
    apply) cmd_apply "$@" ;;
    -h|--help|help) usage; exit 0 ;;
    *) die 2 "unknown action: $action (use preview or apply)" ;;
  esac
}

main "$@"
