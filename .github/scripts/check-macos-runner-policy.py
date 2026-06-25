#!/usr/bin/env python3
"""Fail if Workbench macOS workflows use moving runners or skip Xcode setup."""

from __future__ import annotations

import glob
import re
import sys
from pathlib import Path


RUNS_ON_RE = re.compile(r"^\s*runs-on\s*:\s*(.*)$")
JOBS_RE = re.compile(r"^(?P<indent>\s*)jobs\s*:\s*(?:#.*)?$")
MAPPING_KEY_RE = re.compile(r"^(?P<indent>\s*)(?P<name>[A-Za-z0-9_-]+)\s*:\s*(?:#.*)?$")
XCODE_STEP_RE = re.compile(r"^\s*-\s*name\s*:\s*['\"]?Select newest Xcode['\"]?\s*$")
MACOS_14_RE = re.compile(r"(^|[^A-Za-z0-9_-])macos-14([^A-Za-z0-9_-]|$)")
MACOS_LATEST_RE = re.compile(r"(^|[^A-Za-z0-9_-])macos-latest([^A-Za-z0-9_-]|$)")
MACOS_RUNNER_RE = re.compile(r"(^|[^A-Za-z0-9_-])(macos-[A-Za-z0-9_-]+)([^A-Za-z0-9_-]|$)")


def strip_quotes(value: str) -> str:
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in {"'", '"'}:
        return value[1:-1]
    return value


def workflow_texts() -> list[tuple[Path, str]]:
    paths = sorted(
        Path(path)
        for pattern in (".github/workflows/*.yml", ".github/workflows/*.yaml")
        for path in glob.glob(pattern)
    )
    return [(path, path.read_text(encoding="utf-8")) for path in paths]


def indent_width(line: str) -> int:
    return len(line) - len(line.lstrip(" "))


def collect_job_blocks(text: str) -> list[tuple[str, list[str]]]:
    lines = text.splitlines()
    jobs_start: int | None = None
    jobs_indent = 0
    for i, line in enumerate(lines):
        match = JOBS_RE.match(line)
        if match:
            jobs_start = i
            jobs_indent = len(match.group("indent"))
            break
    if jobs_start is None:
        return []

    job_indent: int | None = None
    for line in lines[jobs_start + 1 :]:
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        indent = indent_width(line)
        if indent <= jobs_indent:
            break
        if MAPPING_KEY_RE.match(line):
            job_indent = indent
            break
    if job_indent is None:
        return []

    blocks: list[tuple[str, list[str]]] = []
    current_name: str | None = None
    current_lines: list[str] = []
    for line in lines[jobs_start + 1 :]:
        if line.strip() and indent_width(line) <= jobs_indent:
            break
        match = MAPPING_KEY_RE.match(line)
        if match and len(match.group("indent")) == job_indent:
            if current_name is not None:
                blocks.append((current_name, current_lines))
            current_name = match.group("name")
            current_lines = [line]
        elif current_name is not None:
            current_lines.append(line)

    if current_name is not None:
        blocks.append((current_name, current_lines))
    return blocks


def runs_on_value(block: list[str], index: int) -> str:
    line = block[index]
    value = strip_quotes(RUNS_ON_RE.match(line).group(1))
    if value:
        return value

    # Support YAML list form:
    # runs-on:
    #   - macos-14
    #   - xlarge
    parent_indent = len(line) - len(line.lstrip(" "))
    parts: list[str] = []
    for child in block[index + 1 :]:
        if not child.strip():
            continue
        child_indent = len(child) - len(child.lstrip(" "))
        if child_indent <= parent_indent:
            break
        stripped = child.strip()
        if stripped.startswith("- "):
            parts.append(strip_quotes(stripped[2:]))
    return " ".join(parts)


def main() -> int:
    failures: list[str] = []
    macos_jobs = 0

    for path, text in workflow_texts():
        for match in MACOS_RUNNER_RE.finditer(text):
            runner = match.group(2)
            if runner != "macos-14":
                failures.append(f"{path}: {runner} is forbidden; pin macOS jobs to macos-14")

        for job_name, block in collect_job_blocks(text):
            runs_on = ""
            for i, line in enumerate(block):
                if RUNS_ON_RE.match(line):
                    runs_on = runs_on_value(block, i)
                    break
            if not runs_on:
                continue

            if MACOS_LATEST_RE.search(runs_on):
                failures.append(f"{path}:{job_name}: runs-on uses moving macos-latest")
            if "macos-" in runs_on and not MACOS_14_RE.search(runs_on):
                failures.append(f"{path}:{job_name}: macOS runner must be macos-14, got {runs_on!r}")
            block_text = "\n".join(block)
            expression_macos_14 = "${{" in runs_on and MACOS_14_RE.search(block_text)
            if MACOS_14_RE.search(runs_on) or expression_macos_14:
                macos_jobs += 1
                xcode_steps = sum(1 for line in block if XCODE_STEP_RE.match(line))
                if xcode_steps != 1:
                    failures.append(
                        f"{path}:{job_name}: expected exactly one 'Select newest Xcode' step, "
                        f"found {xcode_steps}"
                    )

    if failures:
        for failure in failures:
            print(f"::error::{failure}", file=sys.stderr)
        return 1
    print(f"macOS runner policy ok: {macos_jobs} macos-14 jobs")
    return 0


if __name__ == "__main__":
    sys.exit(main())
