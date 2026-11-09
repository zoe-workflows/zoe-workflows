#!/usr/bin/env bash
# Zoe skill wrapper: locate the runtime, enforce the compatibility gate, forward.
#
# The gate lives *inside* the call path on purpose. A documented "run preflight
# first" step would be optional in practice; this sequence is not:
#
#   1. resolve one absolute runtime (ZOE_BIN -> ZOE_SRC -> zoe on PATH)
#   2. run `capabilities --check-requirements <skill>/runtime-requirements.json`
#   3. on rejection print RUNTIME_INCOMPATIBLE and exit non-zero
#   4. otherwise run the user request through the *same* resolved runtime
#
# Exit codes: 0 success, 5 incompatible runtime, 126 runtime not found/not
# executable. ``--version`` and ``--which`` skip the gate: they are how a user
# diagnoses a rejected runtime.
#
# Error documents go to **stdout**, the same channel the runtime itself uses
# (`cli.py` prints both success and failure through one `output()`); a wrapper
# that moved errors to stderr would force every host to merge two streams.
set -uo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
skill_root="$(cd -- "$script_dir/.." && pwd)"
requirements="$skill_root/runtime-requirements.json"
hint="Fix with one of: pipx install zoe-runtime | pipx upgrade zoe-runtime | ZOE_BIN=/abs/path/to/zoe | ZOE_SRC=/abs/path/to/zoe-runtime"

# JSON string escaping without jq. A path or an upstream message may contain a
# quote or a backslash, and printing it raw produces a JSON document the host
# cannot parse — which is worse than the error it was reporting.
json_escape() {
  # $1 可能是多行（运行器的 traceback 就是多行）。JSON 字符串里的裸换行会让
  # 文档解析失败——而"运行器坏了"正是宿主最需要读到这份文档的时刻。
  # 做法：逐行把行尾换成字面量 \n，再删掉真实换行，最后去掉末尾那个。
  printf '%s' "$1" \
    | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/\\t/g' -e 's/\r/\\r/g' -e 's/$/\\n/' \
    | tr -d '\n' \
    | sed -e 's/\\n$//'
}

emit_error() {
  # $1 code, $2 message, $3 exit code
  #
  # 通道必须与运行器一致：运行器的结构化错误走 **stdout**（`cli.py` 用同一个
  # `output()` 打印成功与失败），包装器若改用 stderr，宿主就得合并两路流才能
  # 拿到一个可解析的文档。透明的包装器不改通道。
  printf '{"error":{"code":"%s","message":"%s","hint":"%s"}}\n' \
    "$(json_escape "$1")" "$(json_escape "$2")" "$(json_escape "$hint")"
  exit "$3"
}

zoe_how=""
zoe_path=""

resolve_runtime() {
  if [[ -n "${ZOE_BIN:-}" ]]; then
    if [[ "$ZOE_BIN" != /* || ! -f "$ZOE_BIN" || ! -x "$ZOE_BIN" ]]; then
      emit_error RUNTIME_NOT_EXECUTABLE \
        "ZOE_BIN must be a trusted absolute executable path" 126
    fi
    zoe_how="ZOE_BIN"
    zoe_path="$ZOE_BIN"
    return 0
  fi
  # Explicit source binding. An installed package never loads code from a source
  # tree that merely happens to sit above the wrapper.
  if [[ -n "${ZOE_SRC:-}" ]]; then
    if [[ "$ZOE_SRC" != /* || ! -f "$ZOE_SRC/src/__main__.py" ]]; then
      emit_error RUNTIME_NOT_FOUND \
        "ZOE_SRC must be the absolute path of a zoe-runtime checkout containing src/__main__.py" 126
    fi
    if ! command -v python3 >/dev/null 2>&1; then
      emit_error RUNTIME_NOT_FOUND "ZOE_SRC needs python3 on PATH" 126
    fi
    zoe_how="ZOE_SRC"
    zoe_path="$ZOE_SRC"
    return 0
  fi
  local found
  if found="$(command -v zoe 2>/dev/null)" && [[ -n "$found" ]]; then
    zoe_how="PATH"
    zoe_path="$found"
    return 0
  fi
  emit_error RUNTIME_NOT_FOUND \
    "zoe runtime not found on this host (this skill ships no runtime)" 126
}

# Run the resolved runtime. Both the gate and the user request go through this
# function so they can never diverge onto different binaries.
run_runtime() {
  case "$zoe_how" in
    ZOE_SRC) env PYTHONPATH="$zoe_path" python3 -m src "$@" ;;
    *) "$zoe_path" "$@" ;;
  esac
}

resolve_runtime

# Read-only diagnostics stay available even when the gate would reject the
# runtime: the user needs them to see what was resolved and why it failed.
case "${1:-}" in
  --which)
    printf '{"which":"%s","source":"%s","requirements":"%s","skill":"%s"}\n' \
      "$(json_escape "$zoe_path")" "$zoe_how" \
      "$(json_escape "$requirements")" "$(json_escape "$skill_root")"
    exit 0
    ;;
  --version)
    run_runtime "$@"
    exit $?
    ;;
esac

if [[ ! -f "$requirements" ]]; then
  emit_error RUNTIME_REQUIREMENTS_MISSING \
    "packaged skill is missing runtime-requirements.json; reinstall the skill" 126
fi

# The runtime parses its own requirements file: the skill must not depend on jq,
# python one-liners or any other undeclared parser.
if ! gate_out="$(run_runtime capabilities --check-requirements "$requirements" 2>&1)"; then
  version="$(run_runtime --version 2>/dev/null | head -n 1)"
  # 区分"版本窗口不符"和"运行器自己坏了"：把 import 失败/语法错误报成
  # RUNTIME_INCOMPATIBLE 会让用户一直去升级一个根本无法启动的解释器。
  case "$gate_out" in
    *Traceback*|*"No module named"*|*SyntaxError*|*"cannot import"*)
      printf '{"error":{"code":"RUNTIME_BROKEN","message":"zoe runtime at %s cannot run its own preflight","details":{"runtime_version":"%s","source":"%s","output":"%s"},"hint":"%s"}}\n' \
        "$(json_escape "$zoe_path")" "$(json_escape "$version")" "$zoe_how" "$(json_escape "$gate_out")" "$(json_escape "$hint")"
      exit 126
      ;;
  esac
  printf '{"error":{"code":"RUNTIME_INCOMPATIBLE","message":"zoe runtime at %s does not satisfy %s","details":{"runtime_version":"%s","source":"%s","requirements":"%s"},"hint":"%s"}}\n' \
    "$(json_escape "$zoe_path")" "$(json_escape "$requirements")" "$(json_escape "$version")" "$zoe_how" "$(json_escape "$requirements")" "$(json_escape "$hint")"
  exit 5
fi

run_runtime "$@"
exit $?
