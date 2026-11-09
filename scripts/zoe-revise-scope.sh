#!/usr/bin/env bash
# zoe-revise-scope.sh — 只改 `allowed_paths` 的 `task revise` 薄入口（v1.6）
#
# 为什么需要它
# ------------
# `SCOPE_VIOLATION` 之后，范围来自哪里决定**唯一**可用的解法，两者不可替换：
#
#   * `scope_source=spec`  —— `task_scope` 只在 create/revise 时重算。改项目配置 +
#     `rebind` 会更新 `policy_revision`（闸门放行），却**不动** `task_scope`，下一轮
#     必然再撞同一个越界；而且 `revise` 之前先 resume 等于白烧一次付费尝试。
#   * `scope_source=project` —— 改项目配置 → `project register` → `task rebind`。
#
# 现场的做法是第三种：`cancel` + 从零重派，把 agent 已经写好的代码当成废料。本脚本
# 让"放宽 spec 范围"变成一条命令，并且**复用工作区**：runtime 发现这次修订只改了
# `allowed_paths` 时会直接进入 `verify`（重新判定那棵树），不再跑一次 agent。
#
# 职责边界（与 zoe-resume.sh 同一纪律）
# -------------------------------------
#   * `preview` 只读状态、算出新 spec、落盘请求文件，**不提交**；用户看过之后才 `apply`。
#   * `apply` 只把**给定文件原样**提交，并用 `self_sha256` 核对"要提交的还是用户看过
#     的那一份"——手改 `expected_version` 会被拦下。
#   * 它不决定"该不该修订"，不猜 `scope_source`，不改项目配置，不做范围语义推断：
#     那些是运行时与交付策略的职责。`scope_source != spec` 时直接退出，并给出正确的
#     另一条路。
#
# 退出码（稳定，宿主可分支）
# --------------------------
#   0  成功（preview 落盘 / apply 已提交）
#   2  用法或依赖错误（缺 --project/--task、缺 jq、找不到 spec、参数形态不对）
#   3  前置条件不满足，**未生成 / 未提交**：state 不可修订 / run 未收口 /
#      scope_source=project（应走 register+rebind）/ 请求文件不是本脚本生成的形状 /
#      apply 撞 STATE_CONFLICT（版本已前进，重新 preview）
#   4  运行时拒绝且不属于上面几种（原样打印 error.code，不重试、不自动补救）
#
# 依赖：jq、可执行的 zoe（`ZOE_BIN` 覆盖）。macOS 自带 bash 3.2 可跑。
#
# 用法
# ----
#   bash <skill-dir>/scripts/zoe-revise-scope.sh preview --project P --task T \
#     [--add-path docs] [--add-path "tests/test_x.py"]... [--drop-path a/b.py] \
#     [--reason TEXT] [--authorization-ref R] [--home DIR] [--out DIR]
#   bash <skill-dir>/scripts/zoe-revise-scope.sh apply --request-file F [--json]

set -u
set -o pipefail

ZOE_BIN=${ZOE_BIN:-zoe}

usage() {
  cat <<'EOF'
Usage:
  zoe-revise-scope.sh preview --project P --task T [options]
      --add-path P          要加进 spec allowed_paths 的路径（可重复）
      --drop-path P         要从 spec allowed_paths 去掉的路径（可重复）
      --reason TEXT         写进请求的 reason（给人看的短句）
      --authorization-ref R 缺省取任务冻结配置的 authorization_ref
      --home DIR            状态库根（默认 $ZOE_HOME 或 ~/.local/share/zoe）
      --out DIR             请求文件目录（默认 .zoe/<P>/requests）
    → 只落盘"新 spec + 请求文件"并打印范围差异，**不提交**

  zoe-revise-scope.sh apply --request-file F [--json]
    → 原样提交该文件；打印 state / phase / spec_revision / task_scope
    → phase=verify 表示复用了工作区（没有第二次 agent 费用）

退出码：0 成功 / 2 用法依赖 / 3 前置条件不满足（未生成未提交）/ 4 运行时拒绝。
环境变量：ZOE_BIN（默认 zoe）、ZOE_HOME（默认 ~/.local/share/zoe）。
EOF
}

die() {  # $1=exit code $2=message
  printf '[error] %s\n' "$2" >&2
  exit "$1"
}

note() { printf '%s\n' "$*"; }

need_jq() {
  command -v jq >/dev/null 2>&1 || die 2 "jq is required"
}

default_home() {
  if [ -n "${ZOE_HOME:-}" ]; then
    printf '%s' "$ZOE_HOME"
    return 0
  fi
  printf '%s/.local/share/zoe' "$HOME"
}

new_request_id() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen | tr '[:upper:]' '[:lower:]'
    return 0
  fi
  printf '%s-%s-%s' "$(date +%s)" "$$" "${RANDOM:-0}"
}

sha_cmd() {
  if command -v shasum >/dev/null 2>&1; then
    printf 'shasum -a 256'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf 'sha256sum'
  else
    die 2 "no sha256 tool (shasum / sha256sum)"
  fi
}

# 空输入必须变成 `[]`：`jq -R` 对空字符串不产生输出，直接把它交给 `--argjson`
# 会得到 "invalid JSON text"，报错点还会误导到"构建新 spec"那一步。
csv_to_json() {
  if [ -z "${1:-}" ]; then
    printf '[]'
    return 0
  fi
  printf '%s' "$1" | jq -R -c 'split(",") | map(select(length > 0))'
}

# --------------------------------------------------------------------------- #
# preview
# --------------------------------------------------------------------------- #
cmd_preview() {
  PROJECT=""
  TASK=""
  ADD_PATHS=""
  DROP_PATHS=""
  REASON=""
  AUTH_REF=""
  HOME_DIR=""
  OUT=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --project) PROJECT=${2:-}; shift 2 ;;
      --task) TASK=${2:-}; shift 2 ;;
      --add-path) ADD_PATHS="$ADD_PATHS${ADD_PATHS:+,}${2:-}"; shift 2 ;;
      --drop-path) DROP_PATHS="$DROP_PATHS${DROP_PATHS:+,}${2:-}"; shift 2 ;;
      --reason) REASON=${2:-}; shift 2 ;;
      --authorization-ref) AUTH_REF=${2:-}; shift 2 ;;
      --home) HOME_DIR=${2:-}; shift 2 ;;
      --out) OUT=${2:-}; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) die 2 "unknown argument: $1" ;;
    esac
  done
  [ -n "$PROJECT" ] || die 2 "--project is required"
  [ -n "$TASK" ] || die 2 "--task is required"
  [ -n "$ADD_PATHS$DROP_PATHS" ] || die 2 "give at least one --add-path or --drop-path"
  need_jq
  [ -n "$HOME_DIR" ] || HOME_DIR=$(default_home)
  [ -n "$OUT" ] || OUT=".zoe/$PROJECT/requests"

  status=$("$ZOE_BIN" task status "$TASK" --json --refresh 2>/dev/null) \
    || die 4 "task status failed for $TASK"
  printf '%s' "$status" | jq -e . >/dev/null 2>&1 || die 4 "task status returned non-JSON"

  state=$(printf '%s' "$status" | jq -r '.state // ""')
  version=$(printf '%s' "$status" | jq -r '.row_version // empty')
  revision=$(printf '%s' "$status" | jq -r '.spec_revision // empty')
  scope_source=$(printf '%s' "$status" | jq -r '.scope_source // ""')
  project_of_task=$(printf '%s' "$status" | jq -r '.project_id // ""')

  [ -n "$version" ] || die 3 "task record has no row_version; cannot build expected_version"
  [ -n "$revision" ] || die 3 "task record has no spec_revision"
  [ "$project_of_task" = "$PROJECT" ] || die 3 "task $TASK belongs to ${project_of_task:-<unknown>}, not $PROJECT"

  case "$state" in
    READY|PAUSED|BLOCKED|REVIEW_READY) ;;
    *) die 3 "state=$state is not revisable (only READY / PAUSED / BLOCKED / REVIEW_READY)" ;;
  esac
  # 范围来自项目时，revise 改不动它：`_resolve_task_scope` 读的是 spec 里的
  # `allowed_paths`，没有该键就继续沿用项目范围。此时正确動作是 register + rebind。
  if [ "$scope_source" != "spec" ]; then
    die 3 "scope_source=${scope_source:-<unknown>}：这个任务的生效范围来自项目配置，改 spec 不会改变它。正确路径：改项目 allowed_paths → \`project register\` → \`task rebind\`。"
  fi

  if [ -z "$AUTH_REF" ]; then
    # 与 zoe-resume.sh 同源：任务冻结的是**当时**的授权引用。
    AUTH_REF=$(printf '%s' "$status" | jq -r '.config.authorization_ref // ""')
  fi
  [ -n "$AUTH_REF" ] || die 3 "no authorization_ref in the task config; pass --authorization-ref explicitly"

  spec_dir="$HOME_DIR/tasks/$TASK"
  spec_file="$spec_dir/spec-$revision.json"
  [ -f "$spec_file" ] || die 2 "frozen spec not found: $spec_file（--home 是否指对了？）"

  add_json=$(csv_to_json "$ADD_PATHS") || die 2 "cannot parse --add-path"
  drop_json=$(csv_to_json "$DROP_PATHS") || die 2 "cannot parse --drop-path"

  request_id=$(new_request_id) || die 2 "cannot generate a request id"
  mkdir -p "$OUT" || die 2 "cannot create $OUT"

  new_spec="$OUT/spec-$TASK-rev$((revision + 1))-$request_id.json"
  # 只改 `.text`（真相）与 `.document`（同一份内容的解析视图），其余字段原样保留：
  # `verification_semantics` / `contract_version` 是冻结标记，脚本无权改写。
  # 注意：`|=` 会把 `.` 绑到**旧值**，所以 `.document |= (.text | fromjson)` 里的
  # `.text` 是 `null`（旧的 document 上没有 text）——必须先 `as` 绑定派生值再赋值。
  jq --argjson add "$add_json" --argjson drop "$drop_json" '
      (.text | fromjson) as $doc
      | ($doc | .allowed_paths = (
            ((.allowed_paths // []) + $add)
            | unique
            | map(select(. as $p | $drop | index($p) | not))
          )) as $newdoc
      | .text = ($newdoc | tojson)
      | .document = $newdoc
    ' "$spec_file" >"$new_spec" || die 2 "cannot build the new spec"

  scope_n=$(jq -r '.document.allowed_paths | length' "$new_spec")
  [ "$scope_n" != "0" ] || die 3 "修订后的 allowed_paths 为空：运行时拒绝空范围（有意的：空范围等于\"哪都不能写\"）"

  old_scope=$(printf '%s' "$status" | jq -c '.task_scope // []')
  new_scope=$(jq -c '.document.allowed_paths' "$new_spec")

  body=$(jq -S -n \
    --arg request_id "$request_id" \
    --arg task "$TASK" \
    --arg project "$PROJECT" \
    --arg auth "$AUTH_REF" \
    --arg spec "$new_spec" \
    --arg reason "$REASON" \
    --argjson version "$version" \
    '{
       schema_version: 2,
       request_id: $request_id,
       task_id: $task,
       project_id: $project,
       expected_version: $version,
       authorization_ref: $auth,
       reason: (if $reason == "" then "widen the scope the spec declared too narrowly" else $reason end),
       spec_file: $spec
     }') || die 2 "cannot build the request body"

  sha=$(printf '%s' "$body" | $(sha_cmd) | awk '{print $1}') || die 2 "cannot hash the request"
  req_file="$OUT/revise-$TASK-$request_id.json"
  printf '%s' "$body" | jq --arg sum "$sha" '. + {self_sha256: $sum}' >"$req_file" \
    || die 2 "cannot write $req_file"

  note "[preview] task=$TASK project=$PROJECT state=$state row_version=$version spec_revision=$revision"
  note "[preview] scope_source=spec（只有 revise 能改变它）"
  note "[preview] task_scope: $old_scope"
  note "[preview]      →      $new_scope"
  note "[preview] new spec=$new_spec"
  note "[preview] request=$req_file"
  note "[preview] 这不是提交。确认范围无误后再运行："
  note "          bash $(basename "$0") apply --request-file $req_file"
}

# --------------------------------------------------------------------------- #
# apply
# --------------------------------------------------------------------------- #
cmd_apply() {
  REQ=""
  JSON_OUT=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --request-file) REQ=${2:-}; shift 2 ;;
      --json) JSON_OUT=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die 2 "unknown argument: $1" ;;
    esac
  done
  [ -n "$REQ" ] || die 2 "--request-file is required"
  [ -f "$REQ" ] || die 2 "request file not found: $REQ"
  need_jq

  task=$(jq -r '.task_id // ""' "$REQ")
  want=$(jq -r '.self_sha256 // ""' "$REQ")
  [ -n "$task" ] || die 3 "request file has no task_id; not produced by this script"
  [ -n "$want" ] || die 3 "request file has no self_sha256; not produced by this script"

  # 摘要只覆盖"除 self_sha256 以外的内容"，与 preview 写入时**同一口径**：
  # preview 哈希的是 `jq -S -n` 重建出的规范文本，所以这里也只能删掉那一个字段
  # 再规范化，不能顺手删 task_id / project_id（那会让摘要覆盖一个更小的对象，
  # 于是"文件没改"也会报 mismatch）。
  stripped=$(jq -S 'del(.self_sha256)' "$REQ") || die 3 "cannot canonicalise the request file"
  got=$(printf '%s' "$stripped" | $(sha_cmd) | awk '{print $1}')
  [ "$got" = "$want" ] || die 3 "request file was modified after preview (sha256 mismatch); re-run preview"

  # 原样提交：不重建、不改 id、不改载荷。
  out=$("$ZOE_BIN" task revise "$task" --request-file "$REQ" 2>&1)
  code=$?
  if [ "$code" -ne 0 ]; then
    err_code=$(printf '%s' "$out" | jq -r '.error.code // ""' 2>/dev/null)
    printf '%s\n' "$out" >&2
    case "$err_code" in
      STATE_CONFLICT) die 3 "STATE_CONFLICT：版本已前进（重新运行 preview）" ;;
      SPEC_CHANGED)
        # 冻结记录声明的契约版本低于当前运行时（例如 v2 任务在 v3 运行时上修订）。
        # 这不是范围问题，重跑 preview 也不会好：先把 spec 迁移到当前 schema_version。
        die 3 "SPEC_CHANGED：冻结 spec 的契约版本落后于当前运行时（升级后遗留的任务）。这不是范围问题——先把 spec 迁移到当前 schema_version，再重跑 preview"
        ;;
      "") die 4 "task revise failed with exit $code and no JSON error envelope" ;;
      *) die 4 "task revise refused: $err_code" ;;
    esac
  fi

  if [ "$JSON_OUT" -eq 1 ]; then
    printf '%s\n' "$out"
  else
    # 响应是 mutation 回执（api_version / operation_id / row_version /
    # recommended_action），不带 state/phase——那两个字段要问 `task status`。
    # 不要在这里拼一个"看起来像状态"的推测，那会让宿主误以为已经拿到终态。
    printf '%s' "$out" | jq -r --arg task "$task" '
      "[apply] task=\(.task_id) row_version=\(.row_version // "?") action=\(.recommended_action // "start")",
      "[apply] 下一步：`task status \($task) --json` 看 phase；phase=verify 表示复用了工作区（无第二次 agent 费用），然后 `task start \($task)`。"'
  fi
}

main() {
  [ $# -gt 0 ] || { usage; exit 2; }
  action=$1
  shift
  case "$action" in
    preview) cmd_preview "$@" ;;
    apply) cmd_apply "$@" ;;
    -h|--help) usage; exit 0 ;;
    *) die 2 "unknown action: $action (preview | apply)" ;;
  esac
}

main "$@"
