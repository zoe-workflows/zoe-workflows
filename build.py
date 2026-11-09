#!/usr/bin/env python3
"""Skill package tooling: audit the host skill tree and pack the release ZIP.

The repository root *is* the skill. The runner (``zoe-runtime``) lives in its own
repository and is installed separately, so nothing here executes or imports a
Zoe runtime: this file only audits and archives the host-facing files.

The archive is built from a **whitelist**, never an exclusion list. A new
experiment, backup or design note therefore cannot leak into a distribution by
being added to the tree — it simply is not listed.

Usage::

    python3 build.py --check   # audit the skill tree (CI gate)
    python3 build.py --pack    # write dist/zoe-workflows.zip
"""
from __future__ import annotations

import argparse
import json
import re
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent
DIST = ROOT / "dist"

#: Distribution surface. Distribution rule, not an installer: there is no
#: destination logic anywhere in this repository.
WHITELIST = (
    "SKILL.md",
    "README.md",
    "LICENSE",
    "runtime-requirements.json",
    "references",
    "scripts",
)

#: Top-level directory inside the ZIP. Hosts place this directory as-is.
ARCHIVE_ROOT = "zoe-workflows"

#: Files the skill cannot work without. Checked individually so a renamed or
#: dropped reference fails the gate instead of shrinking the package silently.
REQUIRED_FILES = (
    "SKILL.md",
    "README.md",
    "LICENSE",
    "runtime-requirements.json",
    "references/cli-contract.md",
    "references/runtime-contract.md",
    "references/spec-template.md",
    # config-friction v5 §B8: copy-ready structured drafts. They carry
    # ``<FILL:...>`` markers that validation refuses, so an unfinished draft
    # cannot reach an agent; losing them silently is the failure mode found in
    # the v4 review.
    "references/spec.example.json",
    "references/create-request.example.json",
    # preflight/attest/monitor v2 §S7：`route` 块要求 routing.mode=auto，与最小
    # 示例的 explicit 项目互斥，所以单独一份模板。放进 REQUIRED_FILES 是因为
    # 丢了这个文件，宿主只能凭记忆拼 `route`，而拼错会被 INPUT_INCOMPLETE 拒。
    "references/create-request.routed.example.json",
    "references/worker-prompt.md",
    "references/recovery-policy.md",
    "references/delivery-policy.md",
    # 2026-11-06 渐进披露：监控的异常分支（--with-log / empty_reason / 空候选 / 续期算法 /
    # watchd / 无脚本等价协议）从 SKILL.md 第 6 步移到这份手册。丢了它，SKILL.md 里的
    # 内联链接就指向空文件，宿主遇到异常分支只能凭记忆判断——那正是"预算到期当完成"、
    # "日志静默当卡死"的来源。
    "references/monitoring-playbook.md",
    # 2026-11-06 内容精简：模型身份三层、`model_aliases` 登记、`cost_class` 与 probe 的代价
    # 从 SKILL.md 移到这份手册。它们只在登记/标定/撞 MODEL_MISMATCH 时才需要，但一旦需要
    # 就是"降档关掉身份要求""凭名字像就填别名"这类误判的来源，丢了它只剩五条纪律摘要。
    "references/model-identity.md",
    "references/report-template.md",
    "references/handoff-template.md",
    "references/decomposition-patterns.md",
    # v1.3 task-group delivery: a group cannot be planned, driven or reported
    # without these three, and a silently shrunken package is worse than a
    # failed build.
    "references/group-plan-schema.md",
    "references/group-delivery.md",
    "references/group-report-template.md",
    # v1.4 design-conformance review: the host cannot produce a valid
    # `group review` submission without the rubric and the output contract.
    "references/design-review-rubric.md",
    # v1.5.0 授权边界：三档示例。默认只给"一个模型 + 显式白名单"，多模型与
    # 高级字段各自独立，避免"为了演示多模型先要求填十几个字段"。
    "references/project-profile.example.json",
    "references/project-profile.multi-model.example.json",
    "references/project-profile.advanced.example.json",
    "scripts/zoe.sh",
    "scripts/zoe.cmd",
    "scripts/zoe.ps1",
    # v1.5.1 监控模板：观察与推进是两件事。脚本不在包里，宿主只能靠"复制一段
    # 门禁文档里的 bash"来监控，而那段 bash 曾经有三处会静默丢事件/空转的缺陷。
    "scripts/zoe-monitor.sh",
    # 监控协议不只一种实现：Windows 宿主没有 bash/jq，靠"照抄一段 sh"无法落地，
    # 于是它要么不监控，要么把窗口到期当完成。`.ps1` 与 `.sh` 同语义（游标先读后写、
    # 事件先落盘再推进、退出码 0/2/10/11 一致），只是换了实现。
    "scripts/zoe-monitor.ps1",
    # v1.5.2 两段式入口：`task resume` 与 `project attest` 的请求都是"四要素 + 幂等
    # 哈希"，手拼 `expected_version` / `request_id` 会撞 STATE_CONFLICT 或
    # REQUEST_CONFLICT。丢脚本 = 宿主退回手抄，而手抄正是这两个缺陷的来源。
    "scripts/zoe-resume.sh",
    "scripts/zoe-attest.sh",
    # v1.5.3 批量派发：`task start <TASK> --request-file <F>` 的主体来自 argv、
    # 幂等键来自文件，两者可以静默错配（实测 t9a-start 打到了 T9d 上）。丢了这个
    # 脚本，宿主只能回到手写循环 + 手抄请求，那正是 REQUEST_CONFLICT 的来源。
    "scripts/zoe-batch-start.sh",
    # v1.6 可观测性：一版摘要原本需要 N 次 status + N 次 logs，宿主于是退化成
    # "只报状态、不报内容"。丢了这个脚本，SKILL 的"进度拍"就没有可执行的落点。
    "scripts/zoe-digest.sh",
    # v1.6 会话之外的可观测性：monitor 是前台、有界循环，会话关闭即消失。丢了
    # watchd，"我关窗口之后跑到哪了"只能回来重查，而早期状态已被覆盖。它只读，
    # 唯一会做的事是写 live.md/live.jsonl。
    "scripts/zoe-watchd.sh",
    # v1.6 范围修订：`SCOPE_VIOLATION` 之后"范围来自 spec 还是项目配置"决定唯一解法。
    # scope_source=spec 时改配置 + rebind 不动 task_scope，下一轮必然再撞同一个越界；
    # 而现场做法是 cancel + 重派，把已写好的工作区当废料。丢了这个脚本，宿主只能手拼
    # `task revise`（expected_version / request_id 手抄，正是 STATE_CONFLICT 的来源）。
    "scripts/zoe-revise-scope.sh",
)

#: Keys the runtime parser requires. Duplicating the parse here keeps a broken
#: requirements file from being shipped by a Skill PR that never ran the runner.
REQUIREMENT_KEYS = {
    "package": str,
    "command": str,
    "min_version": str,
    "max_version_exclusive": str,
    "api_version": int,
    "protocol_revision": int,
}

#: Directories that belong to the runner repository. Their presence here means a
#: split was undone by a stray copy, not that the audit is too strict.
RUNNER_DIRS = ("src", "tests", "schemas")

#: Structure budgets (2026-11-06). ``SKILL.md`` is loaded whole by the host on
#: every turn, so unbounded growth buries the rules that must not be missed:
#: the review that introduced these numbers measured 78,058 chars / 982 lines,
#: with the monitoring step alone at 24,063 chars and **zero** sub-headings
#: between two ``##`` levels. The gate covers only ``SKILL.md`` and its steps;
#: ``references/`` has historical debt that should not go red all at once.
SIZE_BUDGET = 38_000        # whole SKILL.md
STEP_BUDGET = 9_500         # any single numbered step of 工作步骤
SUBSECTION_BUDGET = 2_500   # any `####` subsection of step 6
STEP6_MIN_SUBSECTIONS = 2   # step 6 must stay sectioned, never a flat blob


def skill_files() -> list[str]:
    """Return the distribution whitelist as sorted POSIX paths."""
    found = []
    for entry in WHITELIST:
        path = ROOT / entry
        if path.is_file():
            found.append(entry)
        elif path.is_dir():
            found.extend(
                child.relative_to(ROOT).as_posix() for child in sorted(path.rglob("*")) if child.is_file()
            )
    return sorted(found)


def check() -> list[str]:
    """Return skill-tree problems; an empty list means the package is shippable."""
    problems = []
    for relative in REQUIRED_FILES:
        if not (ROOT / relative).is_file():
            problems.append("missing: %s" % relative)

    skill = ROOT / "SKILL.md"
    if not skill.is_file():
        problems.append("missing: SKILL.md")
    else:
        text = skill.read_text(encoding="utf-8")
        if not text.startswith("---\n"):
            problems.append("SKILL.md: missing frontmatter")
        else:
            name = re.search(r"^name:\s*(\S+)", text.split("---\n")[1], re.M)
            expected = ARCHIVE_ROOT
            if not name or name.group(1) != expected:
                problems.append("SKILL.md: frontmatter name must be %r" % expected)
        for link in re.findall(r"\]\((references/[^)]+)\)", text):
            if not (ROOT / link).is_file():
                problems.append("SKILL.md: link to missing %s" % link)
        problems.extend(size_problems(text))

    requirements = ROOT / "runtime-requirements.json"
    if requirements.is_file():
        try:
            declared = json.loads(requirements.read_text(encoding="utf-8"))
        except json.JSONDecodeError as exc:
            problems.append("runtime-requirements.json: %s" % exc)
        else:
            for key, kind in REQUIREMENT_KEYS.items():
                if not isinstance(declared.get(key), kind):
                    problems.append(
                        "runtime-requirements.json: %r must be %s" % (key, kind.__name__)
                    )

    # 打包会保留 exec 位；源码树里丢了它则装完也启动不了，所以在这里就判失败。
    for wrapper in (
        "scripts/zoe.sh",
        "scripts/zoe-monitor.sh",
        "scripts/zoe-resume.sh",
        "scripts/zoe-attest.sh",
        "scripts/zoe-batch-start.sh",
        "scripts/zoe-digest.sh",
        # 两个脚本漏在检查表外：源码树里丢了 exec 位，装完就启动不了，
        # 而打包会忠实保留 0644。
        "scripts/zoe-watchd.sh",
        "scripts/zoe-revise-scope.sh",
    ):
        path = ROOT / wrapper
        if path.is_file() and not path.stat().st_mode & 0o111:
            problems.append("%s is not executable" % wrapper)

    for entry in WHITELIST:
        if not (ROOT / entry).exists():
            problems.append("missing: %s" % entry)

    # The split is structural: runner code in the skill repository is a bug even
    # when it is excluded from the archive.
    for entry in RUNNER_DIRS:
        if (ROOT / entry).exists():
            problems.append("runner code in the skill repository: %s/" % entry)
    for path in sorted(ROOT.glob("*.py")):
        if path.name != Path(__file__).name:
            problems.append("unexpected python file in the skill root: %s" % path.name)
    return problems


def _step_spans(text: str) -> list[tuple[str, int, int]]:
    """Return ``(number, start, end)`` for the numbered steps of 工作步骤.

    The slice stops at the task-group heading: its own ``1. …`` list would
    otherwise be parsed as steps 1–5 a second time and produce phantom steps.
    """
    start = text.find("## 工作步骤")
    if start == -1:
        return []
    end = text.find("### 用任务组交付", start)
    if end == -1:
        end = text.find("## 每次输出", start)
    if end == -1:
        end = len(text)
    body = text[start:end]
    marks = list(re.finditer(r"^(\d+)\. \*\*", body, re.M))
    spans = []
    for index, mark in enumerate(marks):
        stop = marks[index + 1].start() if index + 1 < len(marks) else len(body)
        spans.append((mark.group(1), start + mark.start(), start + stop))
    return spans


def size_problems(text: str) -> list[str]:
    """Return budget violations for ``SKILL.md``; empty means within budget.

    The budgets exist because a rule that is buried is a rule that is skipped:
    see the module docstring of ``references/monitoring-playbook.md`` for the
    measurement that motivated the split.
    """
    problems = []
    if len(text) > SIZE_BUDGET:
        problems.append(
            "SKILL.md: %d chars exceeds the %d-char budget" % (len(text), SIZE_BUDGET)
        )
    for number, start, end in _step_spans(text):
        if end - start > STEP_BUDGET:
            problems.append(
                "SKILL.md: step %s is %d chars (budget %d)"
                % (number, end - start, STEP_BUDGET)
            )
        if number != "6":
            continue
        chunk = text[start:end]
        marks = list(re.finditer(r"^   #### ", chunk, re.M))
        if len(marks) < STEP6_MIN_SUBSECTIONS:
            problems.append(
                "SKILL.md: step 6 has %d subsections (need >= %d); keep it sectioned"
                % (len(marks), STEP6_MIN_SUBSECTIONS)
            )
        for index, mark in enumerate(marks):
            stop = marks[index + 1].start() if index + 1 < len(marks) else len(chunk)
            if stop - mark.start() > SUBSECTION_BUDGET:
                problems.append(
                    "SKILL.md: step 6 subsection %r is %d chars (budget %d)"
                    % (
                        chunk[mark.end():].splitlines()[0].strip(),
                        stop - mark.start(),
                        SUBSECTION_BUDGET,
                    )
                )
    return problems


def pack() -> Path:
    """Write ``dist/zoe-workflows.zip`` and return its path."""
    problems = check()
    if problems:
        raise SystemExit("refusing to pack: " + "; ".join(problems))
    DIST.mkdir(parents=True, exist_ok=True)
    target = DIST / ("%s.zip" % ARCHIVE_ROOT)
    with zipfile.ZipFile(target, "w", zipfile.ZIP_DEFLATED) as archive:
        for relative in skill_files():
            source = ROOT / relative
            info = zipfile.ZipInfo.from_file(source, "%s/%s" % (ARCHIVE_ROOT, relative))
            # Preserve the exec bit: a wrapper that loses it cannot be launched.
            info.external_attr = (source.stat().st_mode & 0o777) << 16
            archive.writestr(info, source.read_bytes(), zipfile.ZIP_DEFLATED)
    return target


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="audit the skill tree")
    parser.add_argument("--pack", action="store_true", help="write dist/zoe-workflows.zip")
    args = parser.parse_args(argv)

    if args.check:
        problems = check()
        for problem in problems:
            print(problem, file=sys.stderr)
        return 1 if problems else 0
    if args.pack:
        print("wrote", pack())
        return 0
    parser.print_help()
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
