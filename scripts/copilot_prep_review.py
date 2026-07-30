#!/usr/bin/env python3

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path
from typing import Any
from urllib import error, parse, request

SCRIPT_VERSION = 4
DEFAULT_TTL_SECONDS = 15 * 60
ROOT_DOCS = ("AGENTS.md", "CLAUDE.md", "GEMINI.md", "README.md", "CONTRIBUTING.md")
GENERIC_RULE_NAMES = {
    "clean-history.mdc",
    "deliberate-execution.mdc",
    "pre-push-gates.mdc",
    "pr-lifecycle.mdc",
    "rigor-and-tone.mdc",
}
GATE_KEYWORDS = ("fmt", "format", "lint", "test", "verify", "validate", "check", "unit")
DOMAIN_GLOBS = (
    "*.md",
    "*.mdc",
    "docs/**/*.md",
    "docs/**/*.mdx",
    "docs/**/*.txt",
    "hack/**/*.md",
)
STOP_WORDS = {
    "adds",
    "and",
    "aware",
    "azure",
    "client",
    "clients",
    "does",
    "existing",
    "following",
    "for",
    "from",
    "into",
    "layer",
    "only",
    "operations",
    "pull",
    "request",
    "review",
    "thin",
    "this",
    "that",
    "the",
    "their",
    "these",
    "util",
    "using",
    "what",
    "with",
    "wrapper",
    "wrappers",
}
PR_CONVERSATION_MAX_UNRESOLVED = 4
PR_CONVERSATION_MAX_RESOLVED = 2
LOW_SIGNAL_BOT_MESSAGES = {
    "approved",
    "automated review lgtm",
    "lgtm",
    "looks good to me",
}


def now_epoch() -> int:
    return int(time.time())


def command_exists(name: str) -> bool:
    from shutil import which

    return which(name) is not None


def run_command(argv: list[str], cwd: str | None = None, timeout: int = 20) -> dict[str, Any]:
    try:
        completed = subprocess.run(
            argv,
            cwd=cwd,
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )
    except FileNotFoundError:
        return {"ok": False, "code": None, "stdout": "", "stderr": f"{argv[0]} not found"}
    except subprocess.TimeoutExpired:
        return {"ok": False, "code": None, "stdout": "", "stderr": f"command timed out: {' '.join(argv)}"}

    return {
        "ok": completed.returncode == 0,
        "code": completed.returncode,
        "stdout": completed.stdout,
        "stderr": completed.stderr,
    }


def normalize_text(text: str) -> str:
    return text.replace("\r\n", "\n").replace("\r", "\n")


def trim_lines(text: str, max_lines: int = 8, max_chars: int = 900) -> str:
    text = normalize_text(text).strip()
    if not text:
        return ""

    lines = [line.rstrip() for line in text.splitlines() if line.strip()]
    lines = lines[:max_lines]
    joined = "\n".join(lines)
    if len(joined) > max_chars:
        joined = joined[: max_chars - 1].rstrip() + "..."
    return joined


def compact_text(text: str, max_chars: int = 240) -> str:
    normalized = normalize_text(text)
    normalized = re.sub(r"```.*?```", " ", normalized, flags=re.S)
    normalized = re.sub(r"`([^`]+)`", r"\1", normalized)
    normalized = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", normalized)
    normalized = re.sub(r"https?://\S+", "", normalized)
    normalized = re.sub(r"\s+", " ", normalized).strip()
    if len(normalized) > max_chars:
        normalized = normalized[: max_chars - 1].rstrip() + "..."
    return normalized


def first_existing(paths: list[Path]) -> Path | None:
    for path in paths:
        if path.exists():
            return path
    return None


def parse_github_pr_url(url: str) -> dict[str, Any]:
    parsed = parse.urlparse(url)
    if parsed.scheme not in {"http", "https"}:
        raise ValueError("PR URL must start with http:// or https://")
    if parsed.netloc.lower() != "github.com":
        raise ValueError("Only github.com PR URLs are supported")

    parts = [part for part in parsed.path.split("/") if part]
    if len(parts) < 4 or parts[2] != "pull":
        raise ValueError("Expected a GitHub pull request URL like https://github.com/owner/repo/pull/123")

    try:
        number = int(parts[3])
    except ValueError as exc:
        raise ValueError("Pull request number must be numeric") from exc

    return {
        "url": f"https://github.com/{parts[0]}/{parts[1]}/pull/{number}",
        "owner": parts[0],
        "repo": parts[1],
        "number": number,
        "owner_repo": f"{parts[0]}/{parts[1]}",
    }


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="replace")


def parse_export_file(path: Path) -> dict[str, str]:
    if not path.exists():
        return {}

    values: dict[str, str] = {}
    for raw_line in read_text(path).splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue

        match = re.match(r"^(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$", line)
        if not match:
            continue

        key = match.group(1)
        value = match.group(2).strip()
        if (value.startswith('"') and value.endswith('"')) or (value.startswith("'") and value.endswith("'")):
            value = value[1:-1]
        values[key] = value

    return values


def git_email() -> str | None:
    out = run_command(["git", "config", "--global", "user.email"])
    if not out["ok"]:
        return None

    value = out["stdout"].strip()
    return value or None


def jira_base_from_urls(urls: list[str]) -> str | None:
    for url in urls:
        parsed = parse.urlparse(url)
        if parsed.scheme and parsed.netloc:
            return f"{parsed.scheme}://{parsed.netloc}"
    return None


def discover_jira_config(jira_urls: list[str]) -> dict[str, Any]:
    env = os.environ
    token_file_values = parse_export_file(Path.home() / ".config" / ".jira_token")
    fallback_values = parse_export_file(Path.home() / ".jira_token")

    token = env.get("JIRA_TOKEN") or env.get("JIRA_API_TOKEN")
    token_source = "env" if token else None
    if not token:
        token = token_file_values.get("JIRA_TOKEN") or token_file_values.get("JIRA_API_TOKEN")
        token_source = "token-file" if token else None
    if not token:
        token = fallback_values.get("JIRA_TOKEN") or fallback_values.get("JIRA_API_TOKEN")
        token_source = "fallback-token-file" if token else None

    base = env.get("JIRA_BASE_URL") or token_file_values.get("JIRA_BASE_URL") or fallback_values.get("JIRA_BASE_URL")
    base_source = "env-or-file" if base else None
    if not base:
        base = jira_base_from_urls(jira_urls)
        base_source = "jira-url" if base else None

    user = env.get("JIRA_EMAIL") or env.get("JIRA_USER")
    user_source = "env" if user else None
    if not user:
        user = token_file_values.get("JIRA_EMAIL") or token_file_values.get("JIRA_USER")
        user_source = "token-file" if user else None
    if not user:
        user = fallback_values.get("JIRA_EMAIL") or fallback_values.get("JIRA_USER")
        user_source = "fallback-token-file" if user else None
    if not user:
        user = git_email()
        user_source = "git-config" if user else None

    return {
        "token": token,
        "token_source": token_source,
        "base": base.rstrip("/") if base else None,
        "base_source": base_source,
        "user": user,
        "user_source": user_source,
    }


def path_display(path: Path, repo_root: Path | None = None) -> str:
    if repo_root:
        try:
            return str(path.relative_to(repo_root))
        except ValueError:
            pass
    return str(path)


def short_excerpt(path: Path, keywords: list[str] | None = None) -> str:
    text = read_text(path)
    lines = normalize_text(text).splitlines()
    if not keywords:
        return trim_lines("\n".join(lines[:10]))

    lowered = [keyword.lower() for keyword in keywords]
    matched: list[str] = []
    for line in lines:
        candidate = line.strip()
        if not candidate:
            continue
        lower = candidate.lower()
        if any(keyword in lower for keyword in lowered):
            matched.append(candidate)
        if len(matched) >= 8:
            break

    if matched:
        return trim_lines("\n".join(matched))
    return trim_lines("\n".join(lines[:10]))


def safe_glob(root: Path, pattern: str) -> list[Path]:
    try:
        return sorted([path for path in root.glob(pattern) if path.is_file()])
    except OSError:
        return []


def repo_metadata(repo_root: Path | None) -> tuple[dict[str, Any], list[str]]:
    if not repo_root:
        return {
            "root": None,
            "branch": None,
            "remote": None,
            "owner_repo": None,
            "has_git": False,
        }, ["Local repo context unavailable: no repo root was provided."]

    git_dir = repo_root / ".git"
    if not git_dir.exists():
        return {
            "root": str(repo_root),
            "branch": None,
            "remote": None,
            "owner_repo": None,
            "has_git": False,
        }, [f"Local repo context degraded: {repo_root} is not a git checkout."]

    remote = run_command(["git", "-C", str(repo_root), "remote", "get-url", "origin"])
    branch = run_command(["git", "-C", str(repo_root), "branch", "--show-current"])
    remote_value = remote["stdout"].strip() if remote["ok"] else None
    branch_value = branch["stdout"].strip() if branch["ok"] else None
    owner_repo = None

    if remote_value:
        match = re.search(r"github\.com[:/](?P<owner>[^/]+)/(?P<repo>[^/.]+)", remote_value)
        if match:
            owner_repo = f"{match.group('owner')}/{match.group('repo')}"

    return {
        "root": str(repo_root),
        "branch": branch_value or None,
        "remote": remote_value,
        "owner_repo": owner_repo,
        "has_git": True,
    }, []


def select_repo_documents(repo_root: Path | None, keywords: list[str]) -> list[dict[str, Any]]:
    if not repo_root:
        return []

    results: list[dict[str, Any]] = []
    for filename in ROOT_DOCS:
        path = repo_root / filename
        if path.exists():
            results.append(
                {
                    "path": path_display(path, repo_root),
                    "provenance": "repo-doc",
                    "excerpt": short_excerpt(path, keywords),
                }
            )

    for path in safe_glob(repo_root, ".cursor/rules/**/*.mdc"):
        results.append(
            {
                "path": path_display(path, repo_root),
                "provenance": "repo-rule",
                "excerpt": short_excerpt(path, keywords),
            }
        )

    return results


def repo_needles(owner_repo: str | None, repo_root: Path | None) -> list[str]:
    needles: set[str] = set()
    if owner_repo:
        needles.add(owner_repo.lower())
        repo_name = owner_repo.split("/")[-1].lower()
        needles.add(repo_name)
        needles.add(repo_name.replace("_", "-"))
    if repo_root:
        needles.add(repo_root.name.lower())
        needles.add(repo_root.name.lower().replace("_", "-"))
    return sorted(needle for needle in needles if len(needle) >= 4)


def is_repo_specific_rule(text: str, path_name: str, owner_repo: str | None, repo_root: Path | None) -> bool:
    repo_name = owner_repo.split("/")[-1].lower() if owner_repo else (repo_root.name.lower() if repo_root else None)
    text_lower = text.lower()
    path_lower = path_name.lower()

    if repo_name and repo_name in path_lower:
        return True

    strong_markers = []
    if repo_name:
        strong_markers.extend(
            [
                f"globs: **/{repo_name}/",
                f"applies when working in azure/{repo_name}",
                f"working in `azure/{repo_name}`",
                f"reviewing azure/{repo_name}",
            ]
        )

    return any(marker in text_lower for marker in strong_markers if marker)


def select_user_rules(owner_repo: str | None, repo_root: Path | None, keywords: list[str]) -> list[dict[str, Any]]:
    rules_root = Path.home() / ".cursor" / "rules"
    if not rules_root.exists():
        return []

    needles = repo_needles(owner_repo, repo_root)
    results: list[dict[str, Any]] = []

    for path in sorted(rules_root.glob("*.mdc")):
        include = path.name in GENERIC_RULE_NAMES
        if not include:
            text = read_text(path).lower()
            path_name = path.name.lower()
            include = is_repo_specific_rule(text, path_name, owner_repo, repo_root)
        if not include:
            continue

        results.append(
            {
                "path": str(path),
                "provenance": "user-rule",
                "excerpt": short_excerpt(path, keywords or needles),
            }
        )

    return results


def derive_keywords(pr_meta: dict[str, Any]) -> list[str]:
    title = pr_meta.get("title") or ""
    body = pr_meta.get("body") or ""
    file_paths = " ".join(pr_meta.get("files") or [])
    text = f"{title}\n{body}\n{file_paths}"

    jira_keys = re.findall(r"\b[A-Z]{2,10}-\d+\b", text)
    words = re.findall(r"[A-Za-z][A-Za-z0-9-]{3,}", text)
    keywords: list[str] = []
    seen: set[str] = set()

    for key in jira_keys + words:
        normalized = key.lower()
        if normalized in seen:
            continue
        if normalized in STOP_WORDS:
            continue
        if normalized.isdigit():
            continue
        seen.add(normalized)
        keywords.append(key)
        if len(keywords) >= 12:
            break

    return keywords


def domain_context(repo_root: Path | None, keywords: list[str], excluded_paths: set[str]) -> list[dict[str, Any]]:
    if not repo_root or not keywords:
        return []

    candidates: dict[str, dict[str, Any]] = {}
    lowered = [keyword.lower() for keyword in keywords]
    scanned = 0

    for pattern in DOMAIN_GLOBS:
        for path in safe_glob(repo_root, pattern):
            rel_path = path_display(path, repo_root)
            if rel_path in excluded_paths:
                continue
            scanned += 1
            if scanned > 400:
                break

            text = read_text(path)
            lower_text = text.lower()
            score = sum(1 for keyword in lowered if keyword in lower_text)
            if score == 0:
                continue

            candidates[rel_path] = {
                "path": rel_path,
                "provenance": "domain-doc",
                "score": score,
                "excerpt": short_excerpt(path, keywords),
            }
        if scanned > 400:
            break

    ranked = sorted(candidates.values(), key=lambda item: (-item["score"], item["path"]))
    return [{k: v for k, v in item.items() if k != "score"} for item in ranked[:5]]


PREFERRED_MAKE_TARGET_SCORES = {
    "fmt": 120,
    "lint": 110,
    "lint-go": 115,
    "validate-imports": 115,
    "validate-gh-actions": 105,
    "validate-go": 120,
    "validate-go-action": 110,
    "unit-test-go": 120,
    "test-go": 125,
    "test-python": 95,
    "go-verify": 90,
}


def iter_makefile_logical_lines(text: str) -> list[str]:
    logical_lines: list[str] = []
    pending = ""

    for raw_line in text.splitlines():
        line = raw_line.rstrip()
        if pending:
            pending += line.lstrip()
        else:
            pending = line

        if pending.endswith("\\"):
            pending = pending[:-1].rstrip() + " "
            continue

        logical_lines.append(pending)
        pending = ""

    if pending:
        logical_lines.append(pending)

    return logical_lines


def parse_make_prerequisites(text: str) -> list[str]:
    prereq_text = text.split(";", 1)[0].strip()
    prerequisites: list[str] = []
    for token in re.split(r"\s+", prereq_text):
        if not token or token == "|":
            continue
        if re.match(r"^[A-Za-z0-9_.-]+$", token):
            prerequisites.append(token)
    return prerequisites


def parse_make_targets(makefile_path: Path) -> dict[str, dict[str, Any]]:
    text = read_text(makefile_path)
    parsed: dict[str, dict[str, Any]] = {}

    for raw_line in iter_makefile_logical_lines(text):
        match = re.match(r"^([A-Za-z0-9_.-]+):(.*?)(?:\s+##\s*(.*))?$", raw_line)
        if not match:
            continue

        target = match.group(1)
        remainder = match.group(2)
        description = (match.group(3) or "").strip()
        if target in parsed or remainder.startswith("="):
            continue

        parsed[target] = {
            "command": f"make {target}",
            "source": "Makefile",
            "note": description or "relevant Makefile target",
            "score": PREFERRED_MAKE_TARGET_SCORES.get(target, 10),
            "prerequisites": parse_make_prerequisites(remainder),
        }

    return parsed


def infer_pr_focuses(pr_meta: dict[str, Any] | None) -> set[str]:
    if not pr_meta:
        return set()

    focuses: set[str] = set()
    for path in pr_meta.get("files") or []:
        lowered = path.lower()
        if lowered.endswith(".go") or lowered.endswith(".mod") or lowered.endswith(".sum"):
            focuses.add("go")
        if lowered.endswith(".py") or lowered.startswith("python/"):
            focuses.add("python")
        if lowered.startswith(".github/"):
            focuses.add("gh-actions")
        if lowered.startswith("portal/") or lowered.endswith((".js", ".jsx", ".ts", ".tsx", ".css", ".scss")):
            focuses.add("frontend")

    return focuses


def make_target_tags(target: str, item: dict[str, Any]) -> set[str]:
    lowered = f"{target} {item.get('note', '')}".lower()
    tags: set[str] = set()

    if target == "fmt":
        tags.update({"generic", "go"})
    if any(token in lowered for token in ("go", "golangci", "imports", "module", "gomod")):
        tags.add("go")
    if any(token in lowered for token in ("python", "azdev")):
        tags.add("python")
    if "gh-actions" in lowered or "github actions" in lowered:
        tags.add("gh-actions")
    if any(token in lowered for token in ("portal", "frontend", "npm")):
        tags.add("frontend")
    if "e2e" in lowered:
        tags.add("e2e")
    if "release" in lowered:
        tags.add("release")

    return tags


def make_target_score(target: str, item: dict[str, Any]) -> int:
    exact = PREFERRED_MAKE_TARGET_SCORES.get(target)
    if exact is not None:
        return exact

    lowered = f"{target} {item.get('note', '')}".lower()
    if target.endswith(".test") or "release" in lowered or "e2e" in lowered or "coverpkg" in lowered:
        return 0
    if target.startswith("validate-"):
        return 80
    if target.startswith("unit-test-"):
        return 80
    if target.startswith("test-"):
        return 75
    if target.startswith("lint-"):
        return 70
    if "verify" in lowered:
        return 85

    return 0


def target_matches_focus(tags: set[str], focuses: set[str]) -> bool:
    if not focuses:
        return True
    if "release" in tags or "e2e" in tags:
        return False
    if "generic" in tags:
        return True
    return bool(tags & focuses)


def reachable_make_targets(parsed_targets: dict[str, dict[str, Any]], start: str) -> set[str]:
    seen: set[str] = set()
    stack = list(parsed_targets.get(start, {}).get("prerequisites") or [])

    while stack:
        target = stack.pop()
        if target in seen:
            continue
        seen.add(target)
        if target in parsed_targets:
            stack.extend(parsed_targets[target].get("prerequisites") or [])

    return seen


def make_command_target(command: str) -> str | None:
    match = re.fullmatch(r"make\s+([A-Za-z0-9_.-]+)", command.strip())
    if not match:
        return None
    return match.group(1)


def dedupe_subsumed_make_commands(
    items: list[dict[str, str]], parsed_targets: dict[str, dict[str, Any]], gate_targets: set[str] | None = None
) -> list[dict[str, str]]:
    selected: list[dict[str, str]] = []
    suppressed: set[str] = set()
    if gate_targets is None:
        gate_targets = {
            name
            for name, item in parsed_targets.items()
            if any(keyword in f"{name} {item.get('note', '')}".lower() for keyword in GATE_KEYWORDS)
        }

    for item in items:
        target = make_command_target(item["command"])
        if target and target in suppressed:
            continue

        selected.append(item)

        if target and target in parsed_targets:
            for dependency in reachable_make_targets(parsed_targets, target):
                if dependency in gate_targets:
                    suppressed.add(dependency)

    return selected


def extract_make_targets(makefile_path: Path, pr_meta: dict[str, Any] | None = None) -> tuple[list[dict[str, str]], dict[str, dict[str, Any]]]:
    parsed_targets = parse_make_targets(makefile_path)
    pr_focuses = infer_pr_focuses(pr_meta)
    gate_targets = []

    for target, item in parsed_targets.items():
        score = make_target_score(target, item)
        if score <= 0:
            continue
        tags = make_target_tags(target, item)
        if not target_matches_focus(tags, pr_focuses):
            continue
        item["score"] = score
        item["tags"] = sorted(tags)
        gate_targets.append(item)

    gate_target_names = {make_command_target(item["command"]) for item in gate_targets if make_command_target(item["command"])}
    for item in gate_targets:
        target = make_command_target(item["command"])
        subsumed_targets = reachable_make_targets(parsed_targets, target) & gate_target_names if target else set()
        item["effective_score"] = item["score"] + len(subsumed_targets) * 20

    ranked = sorted(gate_targets, key=lambda item: (-item["effective_score"], -item["score"], item["command"]))
    deduped = dedupe_subsumed_make_commands(
        [{k: v for k, v in item.items() if k not in {"score", "effective_score", "prerequisites", "tags"}} for item in ranked],
        parsed_targets,
        gate_target_names,
    )
    return deduped[:10], parsed_targets


def looks_like_command(text: str) -> bool:
    prefixes = (
        "make ",
        "go ",
        "python ",
        "python3 ",
        "npm ",
        "pnpm ",
        "yarn ",
        "cargo ",
        "pytest ",
        "tox ",
        "azdev ",
        "docker ",
        "podman ",
        "gh ",
    )
    stripped = text.strip()
    return stripped.startswith(prefixes)


def rule_commands(items: list[dict[str, Any]]) -> list[dict[str, str]]:
    commands: list[dict[str, str]] = []
    seen: set[str] = set()

    for item in items:
        excerpt = item.get("excerpt") or ""
        for command in re.findall(r"`([^`]+)`", excerpt):
            normalized = command.strip()
            lowered = normalized.lower()
            if not normalized or lowered in seen:
                continue
            if not looks_like_command(normalized):
                continue
            if not any(keyword in lowered for keyword in GATE_KEYWORDS):
                continue

            seen.add(lowered)
            commands.append(
                {
                    "command": normalized,
                    "source": item["path"],
                    "note": f"referenced by {item['provenance']}",
                }
            )
    return commands


def collect_quality_gates(repo_root: Path | None, items: list[dict[str, Any]], pr_meta: dict[str, Any] | None = None) -> list[dict[str, str]]:
    results: list[dict[str, str]] = []
    seen: set[str] = set()
    parsed_make_targets: dict[str, dict[str, Any]] = {}

    if repo_root:
        makefile_path = repo_root / "Makefile"
        if makefile_path.exists():
            make_items, parsed_make_targets = extract_make_targets(makefile_path, pr_meta)
            for item in make_items:
                if item["command"] not in seen:
                    seen.add(item["command"])
                    results.append(item)

    for item in rule_commands(items):
        if item["command"] not in seen:
            seen.add(item["command"])
            results.append(item)

    if parsed_make_targets:
        results = dedupe_subsumed_make_commands(results, parsed_make_targets)

    return results[:12]


def gh_pr_metadata(pr_url: str) -> tuple[dict[str, Any], list[str]]:
    basic = parse_github_pr_url(pr_url)
    caveats: list[str] = []
    metadata = {
        "url": basic["url"],
        "owner": basic["owner"],
        "repo": basic["repo"],
        "number": basic["number"],
        "owner_repo": basic["owner_repo"],
        "title": None,
        "body": "",
        "author": None,
        "base_ref": None,
        "head_ref": None,
        "files": [],
        "file_stats": [],
        "merge_state": None,
        "review_decision": None,
        "jira_keys": [],
        "jira_urls": [],
    }

    if not command_exists("gh"):
        caveats.append("GitHub enrichment unavailable: `gh` CLI is not installed.")
        return metadata, caveats

    out = run_command(
        [
            "gh",
            "pr",
            "view",
            pr_url,
            "--json",
            "number,title,body,author,baseRefName,headRefName,files,url,mergeStateStatus,reviewDecision",
        ],
        timeout=30,
    )
    if not out["ok"]:
        caveats.append(f"GitHub enrichment unavailable: {out['stderr'].strip() or 'gh pr view failed'}.")
        return metadata, caveats

    payload = json.loads(out["stdout"])
    metadata.update(
        {
            "title": payload.get("title"),
            "body": payload.get("body") or "",
            "author": (payload.get("author") or {}).get("login"),
            "base_ref": payload.get("baseRefName"),
            "head_ref": payload.get("headRefName"),
            "files": [file.get("path") for file in payload.get("files") or [] if file.get("path")],
            "file_stats": [
                {
                    "path": file.get("path"),
                    "additions": file.get("additions"),
                    "deletions": file.get("deletions"),
                    "change_type": file.get("changeType"),
                }
                for file in payload.get("files") or []
                if file.get("path")
            ],
            "merge_state": payload.get("mergeStateStatus"),
            "review_decision": payload.get("reviewDecision"),
        }
    )

    text = f"{metadata['title'] or ''}\n{metadata['body'] or ''}\n{metadata['head_ref'] or ''}"
    metadata["jira_keys"] = sorted(set(re.findall(r"\b[A-Z]{2,10}-\d+\b", text)))
    metadata["jira_urls"] = sorted(set(re.findall(r"https://[^)\s]+/browse/[A-Z]{2,10}-\d+", text)))
    return metadata, caveats


def trim_diff_excerpt(text: str, max_lines: int = 80, max_chars: int = 6000) -> str:
    text = normalize_text(text).strip()
    if not text:
        return ""

    kept: list[str] = []
    for line in text.splitlines():
        if not line.strip():
            continue
        if line.startswith(("diff --git ", "index ", "--- ", "+++ ", "@@ ", "+", "-")):
            kept.append(line.rstrip())
        else:
            kept.append(line.rstrip())
        if len(kept) >= max_lines:
            break

    excerpt = "\n".join(kept)
    if len(excerpt) > max_chars:
        excerpt = excerpt[: max_chars - 1].rstrip() + "..."
    return excerpt


def format_pr_diff_stat(pr_meta: dict[str, Any] | None, max_files: int = 8) -> str:
    file_stats = (pr_meta or {}).get("file_stats") or []
    if not file_stats:
        return ""

    rows = []
    for index, item in enumerate(file_stats, start=1):
        path = item.get("path") or "unknown"
        additions = item.get("additions")
        deletions = item.get("deletions")
        change_type = (item.get("change_type") or "modified").lower()
        rows.append(f"{path} (+{additions or 0}/-{deletions or 0}, {change_type})")
        if index >= max_files:
            remaining = len(file_stats) - index
            if remaining > 0:
                rows.append(f"... plus {remaining} more file(s)")
            break

    return "\n".join(rows)


def gh_pr_diff_context(pr_url: str, pr_meta: dict[str, Any] | None = None) -> tuple[dict[str, str] | None, list[str]]:
    if not command_exists("gh"):
        return None, ["GitHub diff unavailable: `gh` CLI is not installed."]

    context: dict[str, str] = {}
    caveats: list[str] = []

    stat = format_pr_diff_stat(pr_meta)
    if stat:
        context["stat"] = stat

    patch_out = run_command(["gh", "pr", "diff", pr_url, "--color=never"], timeout=30)
    if patch_out["ok"]:
        excerpt = trim_diff_excerpt(patch_out["stdout"])
        if excerpt:
            context["excerpt"] = excerpt
    else:
        caveats.append(f"GitHub diff excerpt unavailable: {patch_out['stderr'].strip() or 'gh pr diff failed'}.")

    return (context or None), caveats


def search_related_prs(pr_meta: dict[str, Any]) -> tuple[list[dict[str, Any]], list[str]]:
    if not command_exists("gh"):
        return [], []

    keys = pr_meta.get("jira_keys") or []
    if not keys:
        return [], []

    related: list[dict[str, Any]] = []
    seen_numbers: set[int] = {pr_meta["number"]}

    for key in keys[:3]:
        out = run_command(
            [
                "gh",
                "api",
                "search/issues",
                "-f",
                f"q=repo:{pr_meta['owner_repo']} is:pr {key}",
                "-f",
                "per_page=5",
            ],
            timeout=30,
        )
        if out["ok"]:
            payload = json.loads(out["stdout"])
            items = payload.get("items") or []
        else:
            fallback = run_command(
                [
                    "gh",
                    "search",
                    "prs",
                    f"{key} repo:{pr_meta['owner_repo']}",
                    "--json",
                    "number,title,url",
                    "--limit",
                    "5",
                ],
                timeout=30,
            )
            if not fallback["ok"]:
                return [], [f"Related PR lookup failed for {key}: {out['stderr'].strip() or fallback['stderr'].strip() or 'gh search failed'}."]
            items = json.loads(fallback["stdout"])

        for item in items:
            number = item.get("number")
            if not isinstance(number, int) or number in seen_numbers:
                continue
            seen_numbers.add(number)
            related.append(
                {
                    "number": number,
                    "title": item.get("title"),
                    "url": item.get("html_url") or item.get("url"),
                    "reason": key,
                }
            )

    return related[:5], []


def empty_pr_conversations() -> dict[str, Any]:
    return {
        "source": "github-review-threads",
        "fetched_via": "graphql",
        "fetched_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "total_threads": 0,
        "unresolved_count": 0,
        "resolved_count": 0,
        "unresolved": [],
        "resolved": [],
    }


def is_bot_login(login: str | None) -> bool:
    if not login:
        return False
    lowered = login.lower()
    return lowered.endswith("[bot]") or lowered in {"codecov", "copilot-pull-request-reviewer"}


def is_low_signal_bot_message(text: str) -> bool:
    lowered = re.sub(r"[^a-z0-9 ]+", "", text.lower()).strip()
    return lowered in LOW_SIGNAL_BOT_MESSAGES


def review_thread_label(path: str | None, start_line: int | None, line: int | None) -> str:
    display_path = path or "unknown-file"
    if isinstance(start_line, int) and isinstance(line, int) and start_line > 0 and line > 0 and start_line != line:
        return f"{display_path}:{start_line}-{line}"
    if isinstance(line, int) and line > 0:
        return f"{display_path}:{line}"
    if isinstance(start_line, int) and start_line > 0:
        return f"{display_path}:{start_line}"
    return display_path


def summarize_review_thread(thread: dict[str, Any]) -> dict[str, Any] | None:
    comments = (((thread.get("comments") or {}).get("nodes")) or [])
    extracted: list[dict[str, Any]] = []

    for comment in comments:
        author = (comment.get("author") or {}).get("login")
        body = compact_text(comment.get("bodyText") or "")
        if not body:
            continue
        extracted.append(
            {
                "author": author,
                "body": body,
                "is_bot": is_bot_login(author),
                "low_signal_bot": is_bot_login(author) and is_low_signal_bot_message(body),
                "url": comment.get("url"),
            }
        )

    actionable = [item for item in extracted if not item["low_signal_bot"]]
    if not actionable:
        return None

    human_first = [item for item in actionable if not item["is_bot"]]
    preferred = human_first or actionable
    first = preferred[0]["body"]
    last = preferred[-1]["body"]
    if len(preferred) == 1 or first == last:
        summary = first
    elif thread.get("isResolved"):
        summary = compact_text(f"{first} Resolved with: {last}")
    else:
        summary = compact_text(f"{first} Latest reply: {last}")

    participants: list[str] = []
    for item in actionable:
        author = item.get("author")
        if author and author not in participants:
            participants.append(author)

    line = thread.get("line") if isinstance(thread.get("line"), int) else None
    start_line = thread.get("startLine") if isinstance(thread.get("startLine"), int) else None

    return {
        "status": "resolved" if thread.get("isResolved") else "unresolved",
        "path": thread.get("path"),
        "line": line,
        "start_line": start_line,
        "label": review_thread_label(thread.get("path"), start_line, line),
        "summary": summary,
        "participants": participants,
        "url": preferred[0].get("url") or actionable[0].get("url"),
        "is_outdated": bool(thread.get("isOutdated")),
        "has_only_bots": not human_first,
    }


def collect_pr_conversations(pr_meta: dict[str, Any]) -> tuple[dict[str, Any], list[str]]:
    conversations = empty_pr_conversations()
    if not command_exists("gh"):
        return conversations, ["PR review thread context unavailable: `gh` CLI is not installed."]

    query = """
query($owner: String!, $repo: String!, $number: Int!) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $number) {
      reviewThreads(first: 40) {
        nodes {
          isResolved
          isOutdated
          path
          line
          startLine
          comments(first: 12) {
            nodes {
              author {
                login
              }
              bodyText
              url
            }
          }
        }
      }
    }
  }
}
""".strip()

    out = run_command(
        [
            "gh",
            "api",
            "graphql",
            "-f",
            f"query={query}",
            "-f",
            f"owner={pr_meta['owner']}",
            "-f",
            f"repo={pr_meta['repo']}",
            "-F",
            f"number={pr_meta['number']}",
        ],
        timeout=30,
    )
    if not out["ok"]:
        return conversations, [f"PR review thread context unavailable: {out['stderr'].strip() or 'gh api graphql failed'}."]

    try:
        payload = json.loads(out["stdout"])
    except json.JSONDecodeError:
        return conversations, ["PR review thread context unavailable: GitHub returned invalid JSON for review threads."]

    raw_threads = (
        ((((payload.get("data") or {}).get("repository") or {}).get("pullRequest") or {}).get("reviewThreads") or {}).get(
            "nodes"
        )
        or []
    )

    summarized: list[dict[str, Any]] = []
    for index, raw_thread in enumerate(raw_threads):
        item = summarize_review_thread(raw_thread)
        if item is not None:
            item["_ordinal"] = index
            summarized.append(item)

    unresolved = [item for item in summarized if item["status"] == "unresolved"]
    resolved = [item for item in summarized if item["status"] == "resolved"]
    unresolved.sort(key=lambda item: (item["is_outdated"], item["has_only_bots"], item["_ordinal"]))
    resolved.sort(key=lambda item: (item["is_outdated"], item["has_only_bots"], item["_ordinal"]))

    for item in summarized:
        item.pop("_ordinal", None)

    conversations.update(
        {
            "total_threads": len(summarized),
            "unresolved_count": len(unresolved),
            "resolved_count": len(resolved),
            "unresolved": unresolved[:PR_CONVERSATION_MAX_UNRESOLVED],
            "resolved": resolved[:PR_CONVERSATION_MAX_RESOLVED],
        }
    )
    return conversations, []


def jira_header_candidates(config: dict[str, Any]) -> list[dict[str, str]]:
    token = config.get("token")
    user = config.get("user")
    if not token:
        return []

    headers: list[dict[str, str]] = []
    if user:
        encoded = base64.b64encode(f"{user}:{token}".encode("utf-8")).decode("ascii")
        headers.append(
            {
                "Authorization": f"Basic {encoded}",
                "Accept": "application/json",
            }
        )
    headers.append(
        {
            "Authorization": f"Bearer {token}",
            "Accept": "application/json",
        }
    )
    return headers


def jira_request_json(url: str, headers: dict[str, str]) -> dict[str, Any]:
    req = request.Request(url, headers=headers, method="GET")
    with request.urlopen(req, timeout=20) as response:
        return json.loads(response.read().decode("utf-8"))


def simplify_linked_issue(link: dict[str, Any], base: str) -> dict[str, Any] | None:
    linked = link.get("outwardIssue") or link.get("inwardIssue") or {}
    if not linked.get("key"):
        return None

    direction = "outward" if link.get("outwardIssue") else "inward"
    relation_key = "outward" if direction == "outward" else "inward"
    fields = linked.get("fields") or {}

    return {
        "key": linked.get("key"),
        "url": f"{base}/browse/{linked.get('key')}",
        "summary": fields.get("summary"),
        "status": ((fields.get("status") or {}).get("name")),
        "issue_type": ((fields.get("issuetype") or {}).get("name")),
        "relation": ((link.get("type") or {}).get(relation_key)),
        "direction": direction,
    }


def fetch_jira_issue(key: str, base: str, headers: dict[str, str]) -> dict[str, Any]:
    payload = jira_request_json(
        f"{base}/rest/api/3/issue/{parse.quote(key)}?fields=summary,status,issuetype,priority,parent,issuelinks",
        headers,
    )
    fields = payload.get("fields") or {}
    parent = fields.get("parent") or {}
    parent_fields = parent.get("fields") or {}

    linked_issues = []
    for link in fields.get("issuelinks") or []:
        simplified = simplify_linked_issue(link, base)
        if simplified:
            linked_issues.append(simplified)

    issue = {
        "key": key,
        "url": f"{base}/browse/{key}",
        "summary": fields.get("summary"),
        "status": ((fields.get("status") or {}).get("name")),
        "issue_type": ((fields.get("issuetype") or {}).get("name")),
        "priority": ((fields.get("priority") or {}).get("name")),
        "parent": None,
        "epic": None,
        "linked_issues": linked_issues[:5],
    }

    if parent.get("key"):
        parent_item = {
            "key": parent.get("key"),
            "url": f"{base}/browse/{parent.get('key')}",
            "summary": parent_fields.get("summary"),
            "status": ((parent_fields.get("status") or {}).get("name")),
            "issue_type": ((parent_fields.get("issuetype") or {}).get("name")),
        }
        issue["parent"] = parent_item
        if parent_item.get("issue_type") == "Epic":
            issue["epic"] = parent_item

    return issue


def enrich_jira(pr_meta: dict[str, Any]) -> tuple[list[dict[str, Any]], list[str]]:
    keys = pr_meta.get("jira_keys") or []
    urls = pr_meta.get("jira_urls") or []
    if not keys:
        return [], []

    config = discover_jira_config(urls)
    if not config.get("token"):
        return [
            {
                "key": key,
                "url": next((url for url in urls if key in url), None),
                "summary": None,
                "status": None,
                "linked_issues": [],
                "parent": None,
                "epic": None,
            }
            for key in keys[:3]
        ], ["Jira refs discovered but not enriched: no Jira token was found in env or the standard token files."]
    if not config.get("base"):
        return [
            {
                "key": key,
                "url": next((url for url in urls if key in url), None),
                "summary": None,
                "status": None,
                "linked_issues": [],
                "parent": None,
                "epic": None,
            }
            for key in keys[:3]
        ], ["Jira refs discovered but not enriched: no Jira base URL was configured or derivable from the PR."]

    results: list[dict[str, Any]] = []
    caveats: list[str] = []
    base = config["base"]
    headers: dict[str, str] | None = None
    auth_errors: list[str] = []

    for candidate in jira_header_candidates(config):
        try:
            jira_request_json(f"{base}/rest/api/3/myself", candidate)
            headers = candidate
            break
        except error.HTTPError as exc:
            auth_errors.append(str(exc.code))
        except Exception as exc:  # noqa: BLE001
            auth_errors.append(type(exc).__name__)

    if headers is None:
        return [
            {
                "key": key,
                "url": next((url for url in urls if key in url), None),
                "summary": None,
                "status": None,
                "linked_issues": [],
                "parent": None,
                "epic": None,
            }
            for key in keys[:3]
        ], [
            "Jira refs discovered but not enriched: authentication failed for all discovered auth modes."
            + (f" Attempts: {', '.join(auth_errors)}." if auth_errors else "")
        ]

    for key in keys[:3]:
        try:
            results.append(fetch_jira_issue(key, base, headers))
        except error.HTTPError as exc:
            caveats.append(f"Jira enrichment failed for {key}: HTTP {exc.code}.")
            results.append(
                {
                    "key": key,
                    "url": next((url for url in urls if key in url), None),
                    "summary": None,
                    "status": None,
                    "linked_issues": [],
                    "parent": None,
                    "epic": None,
                }
            )
        except Exception as exc:  # noqa: BLE001
            caveats.append(f"Jira enrichment failed for {key}: {exc}.")
            results.append(
                {
                    "key": key,
                    "url": next((url for url in urls if key in url), None),
                    "summary": None,
                    "status": None,
                    "linked_issues": [],
                    "parent": None,
                    "epic": None,
                }
            )

    return results, caveats


def cache_key(pr_url: str, repo_root: str | None) -> str:
    payload = {"pr_url": pr_url, "repo_root": repo_root or "", "version": SCRIPT_VERSION}
    return hashlib.sha256(json.dumps(payload, sort_keys=True).encode("utf-8")).hexdigest()


def load_cache(cache_path: Path, ttl_seconds: int) -> dict[str, Any] | None:
    if not cache_path.exists():
        return None

    try:
        payload = json.loads(read_text(cache_path))
    except json.JSONDecodeError:
        return None

    created_at = payload.get("generated_at_epoch")
    if not isinstance(created_at, int):
        return None
    if now_epoch() - created_at > ttl_seconds:
        return None
    payload["cache_hit"] = True
    return payload


def write_cache(cache_path: Path, payload: dict[str, Any]) -> None:
    cache_path.parent.mkdir(parents=True, exist_ok=True)
    cache_path.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")


def build_bundle(pr_url: str, repo_root_arg: str | None) -> dict[str, Any]:
    pr_meta, caveats = gh_pr_metadata(pr_url)
    repo_root = Path(repo_root_arg).expanduser().resolve() if repo_root_arg else None
    repo_info, repo_caveats = repo_metadata(repo_root)
    caveats.extend(repo_caveats)

    keywords = derive_keywords(pr_meta)
    rules_docs = select_repo_documents(repo_root, keywords)
    rules_docs.extend(select_user_rules(repo_info.get("owner_repo"), repo_root, keywords))
    deduped_rules_docs: list[dict[str, Any]] = []
    seen_paths: set[str] = set()
    for item in rules_docs:
        if item["path"] in seen_paths:
            continue
        seen_paths.add(item["path"])
        deduped_rules_docs.append(item)

    pr_diff, diff_caveats = gh_pr_diff_context(pr_url, pr_meta)
    caveats.extend(diff_caveats)
    quality_gates = collect_quality_gates(repo_root, deduped_rules_docs, pr_meta)
    domain = domain_context(repo_root, keywords, set(seen_paths))
    related_prs, related_caveats = search_related_prs(pr_meta)
    caveats.extend(related_caveats)
    pr_conversations, conversation_caveats = collect_pr_conversations(pr_meta)
    caveats.extend(conversation_caveats)
    jira_items, jira_caveats = enrich_jira(pr_meta)
    caveats.extend(jira_caveats)

    if not deduped_rules_docs:
        caveats.append("No repo or user rule files were collected.")
    if repo_root and not quality_gates:
        caveats.append("No validation commands were detected from the local Makefile or collected rules.")
    if repo_root and not domain:
        caveats.append("No local domain-context docs matched the PR title/body keywords.")

    return {
        "cache_hit": False,
        "generated_at_epoch": now_epoch(),
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "keywords": keywords,
        "pr": pr_meta,
        "repo": repo_info,
        "rules_and_docs": deduped_rules_docs[:10],
        "pr_diff": pr_diff,
        "domain_context": domain,
        "quality_gates": quality_gates,
        "related_prs": related_prs,
        "pr_conversations": pr_conversations,
        "jira": jira_items,
        "caveats": caveats,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Collect review context for a GitHub PR.")
    parser.add_argument("pr_url", help="GitHub pull request URL")
    parser.add_argument("--repo-root", help="Local checkout root for deterministic repo context")
    parser.add_argument("--cache-dir", help="Cache directory for collected JSON bundles")
    parser.add_argument("--ttl-seconds", type=int, default=DEFAULT_TTL_SECONDS, help="Fresh-cache TTL in seconds")
    parser.add_argument("--refresh", action="store_true", help="Ignore any fresh cache entry")
    args = parser.parse_args()

    repo_root = str(Path(args.repo_root).expanduser().resolve()) if args.repo_root else None
    cache_dir = Path(args.cache_dir or (Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache")) / "nvim" / "copilot-prep-review"))
    cache_file = cache_dir / f"{cache_key(args.pr_url, repo_root)}.json"

    if not args.refresh:
        cached = load_cache(cache_file, args.ttl_seconds)
        if cached is not None:
            cached["cache_path"] = str(cache_file)
            print(json.dumps(cached, indent=2, sort_keys=True))
            return 0

    try:
        bundle = build_bundle(args.pr_url, repo_root)
    except ValueError as exc:
        print(json.dumps({"error": str(exc)}))
        return 2

    bundle["cache_path"] = str(cache_file)
    write_cache(cache_file, bundle)
    print(json.dumps(bundle, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
