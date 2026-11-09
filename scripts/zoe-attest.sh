#!/usr/bin/env bash
# zoe-attest.sh — 授权确认的两段式薄入口（v1.5.2 §S7）
#
# 职责边界（脚本纪律 §4.3）：
#   * `preview` 只读地生成一份预览文件 + 打印人可读表格，**不改任何记录**；
#   * `confirm` 先校验"被写入的就是用户看过的那一份"，再把参数**原样**交给
#     `zoe project attest --expect-policy-hash … --expect-profiles …`；
#   * 它**不选 profile**（收窄只能来自用户的表达）、**不代替用户同意**、
#     **不建授权库**（真相仍在运行时的 attest 记录里，预览文件是临时产物）。
#
# 为什么要两段：`--dry-run` 与正式写入之间存在真实窗口（预览 H1、写入时 H2）。
# 运行时的 `--expect-policy-hash` 会在**同一把 control 锁内**重算并比对，不一致
# 就拒绝写入；本脚本负责另一半——证明"预览文件本身没被改过、要确认的集合没有扩张、
# 预览之后配置也没变"，并把这三个结论清楚地报告出来。
#
# 三条纪律（不要弱化）：
#   1. `confirm` 必须带 `--policy-hash`；本脚本**不提供**"不带 hash 直接写"的路径；
#   2. 只有用户明确同意后才能运行 `confirm`；脚本降低手抄成本，不降低同意门槛；
#   3. `--confirm-profiles` 只能是预览集合的**子集**（收窄）；扩张一律拒绝。
#
# 退出码（稳定，宿主可分支）：
#   0  成功（preview 落盘 / confirm 已写入并逐字核对一致）
#   2  用法或依赖错误（缺参数、缺 jq、zoe 不可用、摘要工具不可用）
#   3  预览校验失败，**未写入**：文件被改过 / project 不符 / hash 不符 /
#      集合扩张 / 预览之后配置已变（需要重新 preview 并重新取得同意）
#   4  运行时拒绝（**未写入**）：打印原始 error.code，不重试、不自动改写预览；
#      含 ATTEST_PRECONDITION_FAILED（配置在预览与写入之间变了）
#
# 用法：
#   bash <skill-dir>/scripts/zoe-attest.sh preview --project P [--profiles a,b] [--out F]
#   bash <skill-dir>/scripts/zoe-attest.sh confirm --preview F --policy-hash H \
#     [--confirm-profiles a,b] [--project P] [--json]

set -u
set -o pipefail

ZOE_BIN=${ZOE_BIN:-zoe}

usage() {
  cat <<'EOF'
Usage:
  zoe-attest.sh preview --project P [--profiles a,b] [--out F]
    → 落盘预览文件（policy_hash / confirmed_profiles / execution[] / previous /
      project_id / requested_profiles），打印人可读表格；不改任何记录

  zoe-attest.sh confirm --preview F --policy-hash H [--confirm-profiles a,b] [--project P] [--json]
    → 校验：① 文件未被修改（自身 sha256）② project 一致 ③ hash 逐字相等
            ④ 动作为 execute 且 --confirm-profiles ⊆ 预览集合（不得扩张）
            ⑤ 预览之后 policy_hash 与 execution[] 未变
    → 通过后把预览里的参数原样交给运行时（运行时仍在锁内再比一次）
    → 逐字核对返回的 policy_hash / confirmed_profiles

退出码：0 成功 / 2 用法依赖 / 3 预览校验失败（未写入）/ 4 运行时拒绝（未写入）。
环境变量：ZOE_BIN（默认 zoe）。
EOF
}

die() {  # $1=exit code $2=message
  printf '[error] %s\n' "$2" >&2
  exit "$1"
}

need_tools() {
  command -v jq >/dev/null 2>&1 || die 2 "jq is required"
  command -v "$ZOE_BIN" >/dev/null 2>&1 || die 2 "zoe not found: $ZOE_BIN"
  if command -v sha256sum >/dev/null 2>&1; then
    SHA_CMD="sha256sum"
  elif command -v shasum >/dev/null 2>&1; then
    SHA_CMD="shasum -a 256"
  else
    die 2 "need sha256sum or shasum to bind the preview file to what gets written"
  fi
}

# 摘要口径必须两侧一致：都先把 JSON 交给 `jq -S`（键序稳定），再用命令替换
# 去掉**尾部换行**，最后算 sha256。少这一步，"写的时候有尾换行、读的时候没有"
# 就会得到一个永远失败的完整性校验。
split_ids() {  # $1=comma list → 每行一个 id（去首尾空白、去空项）
  printf '%s' "$1" | tr ',' '\n' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | awk 'NF'
}

sha_of() {  # stdin → hex
  $SHA_CMD | awk '{print $1}'
}

sha_of_text() {  # $1=canonical text（无尾换行）
  printf '%s' "$1" | sha_of
}

# --------------------------------------------------------------------------- #
# preview                                                                     #
# --------------------------------------------------------------------------- #
cmd_preview() {
  PROJECT=""
  PROFILES=""
  OUT=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --project) PROJECT=${2:-}; shift 2 ;;
      --profiles) PROFILES=${2:-}; shift 2 ;;
      --out) OUT=${2:-}; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) die 2 "unknown argument: $1" ;;
    esac
  done
  [ -n "$PROJECT" ] || die 2 "--project is required"
  need_tools

  if [ -n "$PROFILES" ]; then
    out=$("$ZOE_BIN" project attest --project "$PROJECT" --profiles "$PROFILES" --dry-run --json 2>&1) \
      || { printf '%s\n' "$out" >&2; die 4 "project attest --dry-run failed"; }
  else
    out=$("$ZOE_BIN" project attest --project "$PROJECT" --dry-run --json 2>&1) \
      || { printf '%s\n' "$out" >&2; die 4 "project attest --dry-run failed"; }
  fi
  printf '%s' "$out" | jq -e . >/dev/null 2>&1 || die 4 "project attest returned non-JSON"

  # requested_profiles：**脚本请求的**集合（没给 --profiles 时等于运行时给出的
  # confirmed_profiles）。confirm 只能在这个集合里收窄。
  if [ -n "$PROFILES" ]; then
    requested=$(split_ids "$PROFILES" | jq -R . | jq -s .)
  else
    requested=$(printf '%s' "$out" | jq '.confirmed_profiles')
  fi

  body=$(printf '%s' "$out" | jq -S \
    --argjson requested "$requested" \
    --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{
       kind: "zoe-attest-preview",
       api_version: 1,
       generated_at: $generated_at,
       project_id: .project_id,
       policy_hash: .policy_hash,
       policy_revision: .policy_revision,
       scope: .scope,
       scope_note: .scope_note,
       requested_profiles: $requested,
       confirmed_profiles: .confirmed_profiles,
       execution: .execution,
       previous: .previous,
       requested_actions: ["execute"]
     }') || die 4 "cannot build the preview document"
  sum=$(sha_of_text "$body")
  [ -n "$sum" ] || die 2 "cannot compute sha256"

  [ -n "$OUT" ] || OUT=".zoe/$PROJECT/attest"
  mkdir -p "$(dirname "$OUT")" 2>/dev/null || true
  printf '%s' "$body" | jq --arg sum "$sum" '. + {self_sha256: $sum}' >"$OUT" \
    || die 2 "cannot write $OUT"

  # 人可读表格：用户要"原样看到 execution[]"，不能只给一个摘要。
  printf '[preview] project=%s\n' "$(printf '%s' "$body" | jq -r '.project_id')"
  printf '[preview] policy_hash=%s\n' "$(printf '%s' "$body" | jq -r '.policy_hash')"
  printf '[preview] policy_revision=%s  scope=%s\n' \
    "$(printf '%s' "$body" | jq -r '.policy_revision')" \
    "$(printf '%s' "$body" | jq -r '.scope')"
  printf '[preview] confirmed_profiles=%s\n' \
    "$(printf '%s' "$body" | jq -r '.confirmed_profiles | join(",")')"
  printf '[preview] execution:\n'
  printf '%s' "$body" | jq -r '
    .execution[]? | "  - profile=\(.profile_id // "?") adapter=\(.adapter_id // "?") backend=\(.backend // "?") model=\(.model // "-") permission=\(.permission_profile // "-") cost=\(.cost_class // "-") unresolved=\(.model_unresolved // false)"'
  previous_hash=$(printf '%s' "$body" | jq -r '.previous.policy_hash // ""')
  if [ -n "$previous_hash" ]; then
    if [ "$previous_hash" = "$(printf '%s' "$body" | jq -r '.policy_hash')" ]; then
      printf '[preview] previous: 同一摘要（曾确认过这份配置）\n'
    else
      printf '[preview] previous: **配置已变更**（旧摘要 %s）\n' "$previous_hash"
    fi
  else
    printf '[preview] previous: 无记录（首次确认）\n'
  fi
  printf '[preview] 文件=%s\n' "$OUT"
  printf '[preview] 这不是写入。用户明确同意后运行：\n'
  printf '          bash %s confirm --preview %s --policy-hash %s\n' \
    "$(basename "$0")" "$OUT" "$(printf '%s' "$body" | jq -r '.policy_hash')"
  return 0
}

# --------------------------------------------------------------------------- #
# confirm                                                                     #
# --------------------------------------------------------------------------- #
cmd_confirm() {
  PREVIEW=""
  POLICY_HASH=""
  CONFIRM_PROFILES=""
  PROJECT=""
  JSON=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --preview) PREVIEW=${2:-}; shift 2 ;;
      --policy-hash) POLICY_HASH=${2:-}; shift 2 ;;
      --confirm-profiles) CONFIRM_PROFILES=${2:-}; shift 2 ;;
      --project) PROJECT=${2:-}; shift 2 ;;
      --json) JSON=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die 2 "unknown argument: $1" ;;
    esac
  done
  [ -n "$PREVIEW" ] || die 2 "--preview is required"
  [ -f "$PREVIEW" ] || die 2 "preview file not found: $PREVIEW"
  # 纪律 1：没有 hash 就没有确认。这里不是"可选的防错位"，而是"确认的对象"。
  [ -n "$POLICY_HASH" ] || die 2 "--policy-hash is required (the value shown by preview)"
  need_tools

  printf '%s' "$(cat "$PREVIEW")" | jq -e . >/dev/null 2>&1 \
    || die 3 "$PREVIEW is not valid JSON"

  # ① 文件未被修改：脚本写入时记下自身摘要，confirm 时重算。
  stored=$(jq -r '.self_sha256 // ""' "$PREVIEW")
  [ -n "$stored" ] || die 3 "$PREVIEW has no self_sha256 (only files written by \`preview\` are accepted)"
  stripped=$(jq -S 'del(.self_sha256)' "$PREVIEW") || die 3 "$PREVIEW cannot be canonicalised"
  recomputed=$(sha_of_text "$stripped")
  [ "$stored" = "$recomputed" ] || die 3 "预览文件在生成后被修改过（self_sha256 不匹配）；重新 preview"

  file_kind=$(jq -r '.kind // ""' "$PREVIEW")
  [ "$file_kind" = "zoe-attest-preview" ] || die 3 "$PREVIEW is not an attest preview document"

  # ② project 一致：本次要写入的项目必须就是文件里的项目。
  file_project=$(jq -r '.project_id // ""' "$PREVIEW")
  [ -n "$file_project" ] || die 3 "preview has no project_id"
  if [ -n "$PROJECT" ] && [ "$PROJECT" != "$file_project" ]; then
    die 3 "预览是 $file_project 的，本次要写入 $PROJECT；重新 preview"
  fi
  PROJECT=$file_project

  # ③ hash 逐字相等（不是前缀、不是 revision 短摘要）。
  file_hash=$(jq -r '.policy_hash // ""' "$PREVIEW")
  [ "$file_hash" = "$POLICY_HASH" ] || die 3 "--policy-hash 与预览文件里的 policy_hash 不一致"

  # ④ 收窄可以，扩张不行：`--confirm-profiles` 必须是预览集合的子集。
  if [ -n "$CONFIRM_PROFILES" ]; then
    wanted=$(split_ids "$CONFIRM_PROFILES" | jq -R . | jq -s .)
    [ "$(printf '%s' "$wanted" | jq 'length')" -gt 0 ] || die 3 "--confirm-profiles 为空"
    extra=$(jq -n --argjson want "$wanted" --slurpfile file "$PREVIEW" \
      '($file[0].requested_profiles // []) as $have | ($want - $have)')
    [ "$(printf '%s' "$extra" | jq 'length')" -eq 0 ] \
      || die 3 "--confirm-profiles 扩张了预览集合（不允许）：$(printf '%s' "$extra" | jq -r 'join(",")')"
    target_ids=$wanted
  else
    target_ids=$(jq -c '.requested_profiles // []' "$PREVIEW")
  fi
  target_list=$(printf '%s' "$target_ids" | jq -r 'join(",")')

  # ④' 动作未变：这份预览是为 `execute` 做的。为别的动作做的文件不能拿来确认，
  #     否则"用户看过的那份表"描述的就不是本次要写入的操作。
  actions=$(jq -r '.requested_actions // [] | join(",")' "$PREVIEW")
  [ "$actions" = "execute" ] \
    || die 3 "预览记录的 requested_actions（${actions:-空}）不是 execute；重新 preview"

  # ⑤ 预览之后配置没变：重跑一次 dry-run，比对 project_hash / execution / 集合。
  #    运行时在写入锁内还会再比一次（--expect-policy-hash），这里先给一个能读的
  #    结论，避免"点了确认才发现配置变了"。
  if [ -n "$target_list" ]; then
    now=$("$ZOE_BIN" project attest --project "$PROJECT" --profiles "$target_list" --dry-run --json 2>&1) \
      || { printf '%s\n' "$now" >&2; die 4 "dry-run re-check failed"; }
  else
    now=$("$ZOE_BIN" project attest --project "$PROJECT" --dry-run --json 2>&1) \
      || { printf '%s\n' "$now" >&2; die 4 "dry-run re-check failed"; }
  fi
  printf '%s' "$now" | jq -e . >/dev/null 2>&1 || die 4 "dry-run re-check returned non-JSON"
  now_hash=$(printf '%s' "$now" | jq -r '.policy_hash // ""')
  if [ "$now_hash" != "$file_hash" ]; then
    die 3 "预览之后配置已变（policy_hash ${file_hash} → ${now_hash}）；重新 preview 并重新取得同意"
  fi
  # ⑤ 只比**本次要写入的那一组**：`execution[]` 是按 `--profiles` 收窄后返回的，
  #    直接拿「预览时 a,b 的 execution」比「收窄到 a 之后的 execution」会把正常的
  #    收窄误判成"配置变了"——收窄是允许的动作，不是漂移。
  now_exec=$(printf '%s' "$now" | jq -S '.execution')
  file_exec=$(jq -S --argjson want "$target_ids" \
    '[.execution[]? | select(.profile_id as $p | $want | index($p))]' "$PREVIEW")
  [ "$now_exec" = "$file_exec" ] \
    || die 3 "预览之后 execution[] 变了（profile/endpoint/权限档/model 之一）；重新 preview 并重新展示"

  # 全部通过 → 把预览里的参数原样交给运行时；运行时在锁内再比一次。
  if [ -n "$target_list" ]; then
    decision=$("$ZOE_BIN" project attest --project "$PROJECT" --profiles "$target_list" \
      --expect-policy-hash "$file_hash" --expect-profiles "$target_list" --json 2>&1) \
      || {
        printf '%s\n' "$decision" >&2
        die 4 "runtime refused the attestation (未写入)；按上面的 error.code 处理，不要重试同一份预览"
      }
  else
    decision=$("$ZOE_BIN" project attest --project "$PROJECT" \
      --expect-policy-hash "$file_hash" --json 2>&1) \
      || {
        printf '%s\n' "$decision" >&2
        die 4 "runtime refused the attestation (未写入)；按上面的 error.code 处理，不要重试同一份预览"
      }
  fi
  printf '%s' "$decision" | jq -e . >/dev/null 2>&1 || die 4 "attest returned non-JSON"

  # 逐字核对：写入的必须就是用户看过的那一份。
  wrote_hash=$(printf '%s' "$decision" | jq -r '.policy_hash // ""')
  [ "$wrote_hash" = "$file_hash" ] \
    || die 3 "写入返回的 policy_hash（${wrote_hash}）与预览不一致；视为**未确认**，重新展示并重新确认"
  wrote_profiles=$(printf '%s' "$decision" | jq -r '.confirmed_profiles // [] | join(",")')
  if [ -n "$target_list" ] && [ "$wrote_profiles" != "$target_list" ]; then
    die 3 "写入返回的 confirmed_profiles（${wrote_profiles}）与本次确认的集合（${target_list}）不一致"
  fi

  if [ "$JSON" -eq 1 ]; then
    printf '%s\n' "$decision"
    return 0
  fi
  printf '[confirm] project=%s policy_hash=%s\n' "$PROJECT" "$wrote_hash"
  printf '[confirm] confirmed_profiles=%s\n' "$wrote_profiles"
  printf '[confirm] wrote=%s path=%s\n' \
    "$(printf '%s' "$decision" | jq -r '.wrote')" \
    "$(printf '%s' "$decision" | jq -r '.path // "-"')"
  return 0
}

main() {
  [ $# -gt 0 ] || { usage >&2; exit 2; }
  action=$1
  shift
  case "$action" in
    preview) cmd_preview "$@" ;;
    confirm) cmd_confirm "$@" ;;
    -h|--help|help) usage; exit 0 ;;
    *) die 2 "unknown action: $action (use preview or confirm)" ;;
  esac
}

main "$@"
