#!/usr/bin/env python3
"""Benchmark RTK compaction for CopilotChat's live shell-review path.

This mirrors the runtime behavior in `lua/copilotchat_runtime.lua`:
1. Run a shell command and capture stdout.
2. Write the captured stdout to a temporary file.
3. If `rtk` is available, run `rtk cat <tempfile>`.
4. Treat the compacted payload as trimmed RTK stderr plus RTK stdout, because
   that is what the live CopilotChat shell workflow returns to chat.

The goal is to measure the part RTK actually changes: shell command output after
capture, not the deterministic review-prep bundle.
"""

from __future__ import annotations

import argparse
import math
import os
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Sequence


REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_COMMANDS = [
    "git status --short --branch",
    "git diff --stat HEAD~10..HEAD",
    "git log --oneline --decorate -n 20",
    r'rg -n "CopilotChat|rtk|review|shell" README.md docs lua tests scripts',
]


@dataclass
class Measure:
    lines: int
    chars: int
    rough_tokens_chars_div_4: int


@dataclass
class Result:
    command: str
    exit_code: int
    raw: Measure
    compacted: Measure | None
    rtk_status: str
    stderr_note: str | None = None


def parse_args(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Benchmark RTK compaction on review-style shell commands."
    )
    parser.add_argument(
        "commands",
        nargs="*",
        help="Shell commands to benchmark. If omitted, a built-in review-style set is used.",
    )
    parser.add_argument(
        "--cwd",
        default=str(REPO_ROOT),
        help="Working directory for commands. Defaults to the repo root.",
    )
    parser.add_argument(
        "--shell",
        dest="shell_path",
        default=None,
        help="Shell binary used to run commands. Defaults to $SHELL or /bin/sh.",
    )
    parser.add_argument(
        "--require-rtk",
        action="store_true",
        help="Exit non-zero instead of degrading gracefully when RTK is not installed.",
    )
    return parser.parse_args(argv)


def effective_shell(explicit: str | None) -> str:
    if explicit:
        return explicit
    env_shell = os.environ.get("SHELL")
    if env_shell and Path(env_shell).exists():
        return env_shell
    return "/bin/sh"


def measure_text(text: str) -> Measure:
    lines = len(text.splitlines()) if text else 0
    chars = len(text)
    return Measure(
        lines=lines,
        chars=chars,
        rough_tokens_chars_div_4=math.ceil(chars / 4) if chars else 0,
    )


def format_measure(measure: Measure | None) -> str:
    if measure is None:
        return "n/a"
    return (
        f"{measure.lines:>5} lines  "
        f"{measure.chars:>7} chars  "
        f"{measure.rough_tokens_chars_div_4:>6} tok~"
    )


def run_command(command: str, cwd: Path, shell_path: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [shell_path, "-lc", command],
        cwd=cwd,
        text=True,
        capture_output=True,
        check=False,
    )


def compact_with_rtk(raw_stdout: str, cwd: Path, rtk_path: str) -> tuple[str, str]:
    with tempfile.NamedTemporaryFile(
        mode="w",
        encoding="utf-8",
        prefix="copilotchat-rtk-",
        delete=False,
    ) as handle:
        handle.write(raw_stdout)
        temp_path = Path(handle.name)

    try:
        out = subprocess.run(
            [rtk_path, "cat", str(temp_path)],
            cwd=cwd,
            text=True,
            capture_output=True,
            check=False,
        )
    finally:
        temp_path.unlink(missing_ok=True)

    if out.returncode != 0:
        raise RuntimeError(out.stderr.strip() or f"rtk exited with {out.returncode}")

    parts = []
    stderr = out.stderr.strip()
    if stderr:
        parts.append(stderr)
    if out.stdout:
        parts.append(out.stdout)
    return ("\n".join(parts) if parts else raw_stdout), stderr or ""


def benchmark_command(command: str, cwd: Path, shell_path: str, rtk_path: str | None) -> Result:
    completed = run_command(command, cwd, shell_path)
    raw_stdout = completed.stdout or ""
    raw_measure = measure_text(raw_stdout)

    if completed.returncode != 0:
        note = completed.stderr.strip() or "command exited non-zero"
        return Result(
            command=command,
            exit_code=completed.returncode,
            raw=raw_measure,
            compacted=None,
            rtk_status="command_failed",
            stderr_note=note,
        )

    if not rtk_path:
        return Result(
            command=command,
            exit_code=0,
            raw=raw_measure,
            compacted=None,
            rtk_status="rtk_missing",
            stderr_note="RTK not found on PATH; raw output shown only.",
        )

    try:
        compacted_text, rtk_stderr = compact_with_rtk(raw_stdout, cwd, rtk_path)
    except Exception as exc:  # noqa: BLE001
        return Result(
            command=command,
            exit_code=0,
            raw=raw_measure,
            compacted=raw_measure,
            rtk_status="rtk_failed_fallback",
            stderr_note=f"RTK compaction failed; live workflow would fall back to raw output: {exc}",
        )

    note = f"RTK stderr included in compacted payload: {rtk_stderr}" if rtk_stderr else None
    return Result(
        command=command,
        exit_code=0,
        raw=raw_measure,
        compacted=measure_text(compacted_text),
        rtk_status="rtk_ok",
        stderr_note=note,
    )


def print_header(cwd: Path, shell_path: str, rtk_path: str | None, using_defaults: bool) -> None:
    print("RTK live shell-review benchmark")
    print(f"repo root: {REPO_ROOT}")
    print(f"command cwd: {cwd}")
    print(f"shell: {shell_path}")
    print(f"rtk: {rtk_path or 'not installed'}")
    print(f"command set: {'built-in review commands' if using_defaults else 'custom'}")
    print()
    print("Raw metrics measure captured command stdout.")
    print("Compacted metrics measure the exact RTK return payload used by CopilotChat: trimmed RTK stderr plus RTK stdout.")
    print("Token proxy is a rough estimate: chars / 4, rounded up.")
    print()


def print_result(index: int, result: Result) -> None:
    print(f"[{index}] {result.command}")
    print(f"  exit code: {result.exit_code}")
    print(f"  raw:       {format_measure(result.raw)}")
    print(f"  compacted: {format_measure(result.compacted)}")
    print(f"  status:    {result.rtk_status}")

    if result.compacted and result.raw.chars:
        char_delta = result.compacted.chars - result.raw.chars
        pct = (char_delta / result.raw.chars) * 100
        print(f"  delta:     {char_delta:+} chars ({pct:+.1f}%)")

    if result.stderr_note:
        print(f"  note:      {result.stderr_note}")
    print()


def print_summary(results: Sequence[Result]) -> None:
    total_raw_chars = sum(item.raw.chars for item in results)
    total_raw_lines = sum(item.raw.lines for item in results)
    total_raw_tokens = sum(item.raw.rough_tokens_chars_div_4 for item in results)

    compacted_results = [item for item in results if item.compacted is not None]
    total_compacted_chars = sum(item.compacted.chars for item in compacted_results if item.compacted)
    total_compacted_lines = sum(item.compacted.lines for item in compacted_results if item.compacted)
    total_compacted_tokens = sum(
        item.compacted.rough_tokens_chars_div_4 for item in compacted_results if item.compacted
    )

    print("Summary")
    print(f"  raw total:       {total_raw_lines} lines  {total_raw_chars} chars  {total_raw_tokens} tok~")
    if compacted_results:
        print(
            "  compacted total: "
            f"{total_compacted_lines} lines  {total_compacted_chars} chars  {total_compacted_tokens} tok~"
        )
        if total_raw_chars:
            delta = total_compacted_chars - total_raw_chars
            pct = (delta / total_raw_chars) * 100
            print(f"  delta total:     {delta:+} chars ({pct:+.1f}%)")
    else:
        print("  compacted total: n/a")


def main(argv: Sequence[str]) -> int:
    args = parse_args(argv)
    cwd = Path(args.cwd).resolve()
    shell_path = effective_shell(args.shell_path)
    rtk_path = shutil.which("rtk")

    if not cwd.exists():
        print(f"error: cwd does not exist: {cwd}", file=sys.stderr)
        return 2

    if args.require_rtk and not rtk_path:
        print("error: `rtk` is not installed or not on PATH.", file=sys.stderr)
        print("tip: rerun without --require-rtk to benchmark raw output only.", file=sys.stderr)
        return 2

    commands = list(args.commands or DEFAULT_COMMANDS)
    print_header(cwd, shell_path, rtk_path, using_defaults=not args.commands)

    results = [benchmark_command(command, cwd, shell_path, rtk_path) for command in commands]
    for index, result in enumerate(results, start=1):
        print_result(index, result)

    print_summary(results)

    if any(result.rtk_status == "command_failed" for result in results):
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
