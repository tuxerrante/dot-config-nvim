from __future__ import annotations

import json
import tempfile
import textwrap
import unittest
from unittest import mock
from pathlib import Path

from scripts import copilot_prep_review


class CollectQualityGatesTests(unittest.TestCase):
    def make_repo(self, makefile_text: str) -> Path:
        tempdir = tempfile.TemporaryDirectory()
        self.addCleanup(tempdir.cleanup)
        repo_root = Path(tempdir.name)
        (repo_root / "Makefile").write_text(textwrap.dedent(makefile_text), encoding="utf-8")
        return repo_root

    def test_collect_quality_gates_suppresses_real_make_dependencies(self) -> None:
        repo_root = self.make_repo(
            """
            fmt: ## format files
            validate-go: ## validate Go sources
            unit-test-go: ## run focused Go unit tests
            test-go: validate-go unit-test-go ## full Go validation pipeline
            """
        )

        gates = copilot_prep_review.collect_quality_gates(repo_root, [])

        self.assertEqual(
            gates,
            [
                {
                    "command": "make test-go",
                    "source": "Makefile",
                    "note": "full Go validation pipeline",
                },
                {
                    "command": "make fmt",
                    "source": "Makefile",
                    "note": "format files",
                },
            ],
        )

    def test_collect_quality_gates_keeps_similar_targets_without_dependency_edge(self) -> None:
        repo_root = self.make_repo(
            """
            validate-go: ## validate Go sources
            unit-test-go: ## run focused Go unit tests
            test-go: ## smoke Go entrypoints only
            """
        )

        gates = copilot_prep_review.collect_quality_gates(repo_root, [])

        self.assertEqual(
            gates,
            [
                {
                    "command": "make test-go",
                    "source": "Makefile",
                    "note": "smoke Go entrypoints only",
                },
                {
                    "command": "make unit-test-go",
                    "source": "Makefile",
                    "note": "run focused Go unit tests",
                },
                {
                    "command": "make validate-go",
                    "source": "Makefile",
                    "note": "validate Go sources",
                },
            ],
        )

    def test_collect_quality_gates_suppresses_validate_go_action_children(self) -> None:
        repo_root = self.make_repo(
            """
            validate-imports: ## validate imports
            validate-lint-go-fix: ## verify lint-go-fix leaves no diff
            validate-gh-actions: ## validate pinned GitHub actions
            validate-go-action: validate-imports validate-lint-go-fix validate-gh-actions ## validate composite Go action gate
            """
        )

        gates = copilot_prep_review.collect_quality_gates(repo_root, [])

        self.assertEqual(
            gates,
            [
                {
                    "command": "make validate-go-action",
                    "source": "Makefile",
                    "note": "validate composite Go action gate",
                },
            ],
        )

    def test_collect_quality_gates_filters_noisy_keyword_matches(self) -> None:
        repo_root = self.make_repo(
            """
            fmt: ## format files
            lint-go: ## lint go
            validate-imports: ## validate imports
            validate-lint-go-fix: ## verify lint-go-fix leaves no diff
            validate-gh-actions: ## validate pinned GitHub actions
            validate-go-action: validate-imports validate-lint-go-fix validate-gh-actions ## validate action-compatible Go checks
            validate-go: validate-go-action ## validate Go sources
            unit-test-go: ## run focused Go unit tests
            unit-test-go-coverpkg: ## run focused Go unit tests with coverpkg
            test-go: generate build-all validate-go lint-go unit-test-go ## full Go validation pipeline
            go-verify: go-tidy ## verify go modules
            check-release: ## validate release tag shape
            e2e.test: ## build e2e binary
            test-e2e: e2e.test ## run end-to-end tests
            """
        )

        gates = copilot_prep_review.collect_quality_gates(repo_root, [])

        self.assertEqual(
            gates,
            [
                {
                    "command": "make test-go",
                    "source": "Makefile",
                    "note": "full Go validation pipeline",
                },
                {
                    "command": "make fmt",
                    "source": "Makefile",
                    "note": "format files",
                },
                {
                    "command": "make go-verify",
                    "source": "Makefile",
                    "note": "verify go modules",
                },
            ],
        )


class GithubDiffContextTests(unittest.TestCase):
    def test_collects_diff_stat_and_excerpt_from_gh(self) -> None:
        patch_output = textwrap.dedent(
            """\
            diff --git a/pkg/foo.go b/pkg/foo.go
            index 1111111..2222222 100644
            --- a/pkg/foo.go
            +++ b/pkg/foo.go
            @@ -1,3 +1,3 @@
            -old line
            +new line
             unchanged
            """
        )
        pr_meta = {
            "file_stats": [
                {
                    "path": "pkg/foo.go",
                    "additions": 1,
                    "deletions": 1,
                    "change_type": "MODIFIED",
                }
            ]
        }

        def fake_run(argv: list[str], cwd: str | None = None, timeout: int = 20) -> dict[str, object]:
            if argv[:3] == ["gh", "pr", "diff"]:
                return {"ok": True, "code": 0, "stdout": patch_output, "stderr": ""}
            raise AssertionError(f"unexpected command: {argv!r}")

        with mock.patch.object(copilot_prep_review, "command_exists", return_value=True), mock.patch.object(
            copilot_prep_review, "run_command", side_effect=fake_run
        ):
            diff, caveats = copilot_prep_review.gh_pr_diff_context(
                "https://github.com/Azure/ARO-RP/pull/5009", pr_meta
            )

        self.assertEqual(caveats, [])
        self.assertEqual(diff["stat"], "pkg/foo.go (+1/-1, modified)")
        self.assertIn("diff --git a/pkg/foo.go b/pkg/foo.go", diff["excerpt"])
        self.assertIn("+new line", diff["excerpt"])


class PrConversationCollectionTests(unittest.TestCase):
    def pr_meta(self) -> dict[str, object]:
        return {
            "url": "https://github.com/Owner/Repo/pull/123",
            "owner": "Owner",
            "repo": "Repo",
            "number": 123,
            "owner_repo": "Owner/Repo",
            "title": "Add prior review discussion prep",
            "body": "Includes refreshed bundle caveats and prompt compaction.",
            "files": {
                "lua/copilotchat_review_prep.lua",
                "scripts/copilot_prep_review.py",
            },
        }

    def test_collects_unresolved_threads_and_caps_resolved_threads(self) -> None:
        graphql_payload = {
            "data": {
                "repository": {
                    "pullRequest": {
                        "reviewThreads": {
                            "nodes": [
                                {
                                    "isResolved": False,
                                    "isOutdated": False,
                                    "path": "lua/copilotchat_review_prep.lua",
                                    "line": 87,
                                    "startLine": None,
                                    "comments": {
                                        "nodes": [
                                            {
                                                "author": {"login": "reviewer-one"},
                                                "bodyText": "Please keep the prior discussion section compact and summary-first.",
                                                "url": "https://github.com/Owner/Repo/pull/123#discussion_r1",
                                            },
                                            {
                                                "author": {"login": "coderabbitai[bot]"},
                                                "bodyText": "Automated review: this may be clearer with a heading rename.",
                                                "url": "https://github.com/Owner/Repo/pull/123#discussion_r2",
                                            },
                                            {
                                                "author": {"login": "author-one"},
                                                "bodyText": "I will trim the wording and keep the section short.",
                                                "url": "https://github.com/Owner/Repo/pull/123#discussion_r3",
                                            },
                                        ]
                                    },
                                },
                                {
                                    "isResolved": False,
                                    "isOutdated": False,
                                    "path": "scripts/copilot_prep_review.py",
                                    "line": 1218,
                                    "startLine": None,
                                    "comments": {
                                        "nodes": [
                                            {
                                                "author": {"login": "reviewer-two"},
                                                "bodyText": "If cached data is reused, call out that the review thread snapshot may be stale.",
                                                "url": "https://github.com/Owner/Repo/pull/123#discussion_r4",
                                            }
                                        ]
                                    },
                                },
                                {
                                    "isResolved": True,
                                    "isOutdated": False,
                                    "path": "tests/copilotchat_review_prep.lua",
                                    "line": 301,
                                    "startLine": None,
                                    "comments": {
                                        "nodes": [
                                            {
                                                "author": {"login": "reviewer-three"},
                                                "bodyText": "Please add a focused stale-cache rendering test so we do not regress this caveat.",
                                                "url": "https://github.com/Owner/Repo/pull/123#discussion_r5",
                                            },
                                            {
                                                "author": {"login": "author-one"},
                                                "bodyText": "Added a targeted stale-cache rendering assertion in the Lua test file.",
                                                "url": "https://github.com/Owner/Repo/pull/123#discussion_r6",
                                            },
                                        ]
                                    },
                                },
                                {
                                    "isResolved": True,
                                    "isOutdated": False,
                                    "path": "docs/copilotchat-review-prep.md",
                                    "line": 198,
                                    "startLine": None,
                                    "comments": {
                                        "nodes": [
                                            {
                                                "author": {"login": "reviewer-four"},
                                                "bodyText": "Document that only inline review threads are included, not the full PR conversation.",
                                                "url": "https://github.com/Owner/Repo/pull/123#discussion_r7",
                                            },
                                            {
                                                "author": {"login": "author-one"},
                                                "bodyText": "Updated the limitation note in the docs.",
                                                "url": "https://github.com/Owner/Repo/pull/123#discussion_r8",
                                            },
                                        ]
                                    },
                                },
                                {
                                    "isResolved": True,
                                    "isOutdated": False,
                                    "path": "README.md",
                                    "line": 92,
                                    "startLine": None,
                                    "comments": {
                                        "nodes": [
                                            {
                                                "author": {"login": "reviewer-five"},
                                                "bodyText": "Mention the reviewThreads GraphQL dependency somewhere visible.",
                                                "url": "https://github.com/Owner/Repo/pull/123#discussion_r9",
                                            },
                                            {
                                                "author": {"login": "author-one"},
                                                "bodyText": "Added a short GraphQL availability caveat.",
                                                "url": "https://github.com/Owner/Repo/pull/123#discussion_r10",
                                            },
                                        ]
                                    },
                                },
                                {
                                    "isResolved": True,
                                    "isOutdated": False,
                                    "path": "lua/plugins/copilot.lua",
                                    "line": 289,
                                    "startLine": None,
                                    "comments": {
                                        "nodes": [
                                            {
                                                "author": {"login": "github-actions[bot]"},
                                                "bodyText": "Automated review: LGTM.",
                                                "url": "https://github.com/Owner/Repo/pull/123#discussion_r11",
                                            }
                                        ]
                                    },
                                },
                            ]
                        }
                    }
                }
            }
        }
        issue_comments_payload = [
            {
                "user": {"login": "reviewer-top"},
                "body": "Please include the earlier top-level PR context too because some reviewer rationale only lived in issuecomment discussion.",
                "html_url": "https://github.com/Owner/Repo/pull/123#issuecomment-1",
            },
            {
                "user": {"login": "author-one"},
                "body": "Updated docs and tests.",
                "html_url": "https://github.com/Owner/Repo/pull/123#issuecomment-2",
            },
            {
                "user": {"login": "reviewer-context"},
                "body": "The limitation statement still matters: keep standalone review bodies excluded, but carry over the high-signal top-level PR comments that explain prior context and cache expectations.",
                "html_url": "https://github.com/Owner/Repo/pull/123#issuecomment-3",
            },
            {
                "user": {"login": "reviewer-extra"},
                "body": "One more top-level reminder to keep the prompt compact, summary-first, and explicit about auth or availability caveats.",
                "html_url": "https://github.com/Owner/Repo/pull/123#issuecomment-4",
            },
            {
                "user": {"login": "github-actions[bot]"},
                "body": "Automated review: LGTM.",
                "html_url": "https://github.com/Owner/Repo/pull/123#issuecomment-5",
            },
        ]

        def fake_run(argv: list[str], cwd: str | None = None, timeout: int = 20) -> dict[str, object]:
            if argv[:3] == ["gh", "api", "graphql"]:
                return {"ok": True, "code": 0, "stdout": json.dumps(graphql_payload), "stderr": ""}
            if argv[:2] == ["gh", "api"] and "issues/123/comments" in argv[2]:
                return {"ok": True, "code": 0, "stdout": json.dumps(issue_comments_payload), "stderr": ""}
            raise AssertionError(f"unexpected command: {argv!r}")

        with mock.patch.object(copilot_prep_review, "command_exists", return_value=True), mock.patch.object(
            copilot_prep_review, "run_command", side_effect=fake_run
        ):
            conversations, caveats = copilot_prep_review.collect_pr_conversations(self.pr_meta())

        self.assertEqual(caveats, [])
        self.assertEqual(conversations["source"], "github-pr-discussion")
        self.assertEqual(conversations["fetched_via"], "graphql+issuecomment")
        self.assertEqual(conversations["unresolved_count"], 2)
        self.assertEqual(conversations["resolved_count"], 3)
        self.assertEqual(len(conversations["unresolved"]), 2)
        self.assertEqual(len(conversations["resolved"]), 2)
        self.assertEqual(conversations["top_level_count"], 3)
        self.assertEqual(len(conversations["top_level"]), 2)
        self.assertEqual(
            [item["label"] for item in conversations["unresolved"]],
            [
                "lua/copilotchat_review_prep.lua:87",
                "scripts/copilot_prep_review.py:1218",
            ],
        )
        self.assertEqual(
            [item["label"] for item in conversations["resolved"]],
            [
                "tests/copilotchat_review_prep.lua:301",
                "docs/copilotchat-review-prep.md:198",
            ],
        )
        self.assertEqual(
            [item["author"] for item in conversations["top_level"]],
            [
                "reviewer-context",
                "reviewer-extra",
            ],
        )
        all_summaries = " ".join(item["summary"] for item in conversations["unresolved"] + conversations["resolved"])
        self.assertNotIn("Automated review: LGTM.", all_summaries)
        self.assertIn("summary-first", all_summaries)
        self.assertIn("stale-cache rendering assertion", all_summaries)
        top_level_summaries = " ".join(item["summary"] for item in conversations["top_level"])
        self.assertNotIn("Updated docs and tests.", top_level_summaries)
        self.assertIn("standalone review bodies excluded", top_level_summaries)

    def test_degrades_cleanly_when_github_thread_fetch_fails(self) -> None:
        with mock.patch.object(copilot_prep_review, "command_exists", return_value=True), mock.patch.object(
            copilot_prep_review,
            "run_command",
            return_value={"ok": False, "code": 1, "stdout": "", "stderr": "HTTP 401: authentication required"},
        ):
            conversations, caveats = copilot_prep_review.collect_pr_conversations(self.pr_meta())

        self.assertEqual(conversations["source"], "github-pr-discussion")
        self.assertEqual(conversations["fetched_via"], "graphql+issuecomment")
        self.assertEqual(conversations["unresolved"], [])
        self.assertEqual(conversations["resolved"], [])
        self.assertEqual(conversations["unresolved_count"], 0)
        self.assertEqual(conversations["resolved_count"], 0)
        self.assertEqual(conversations["top_level"], [])
        self.assertEqual(conversations["top_level_count"], 0)
        self.assertEqual(len(caveats), 2)
        self.assertIn("PR review thread context unavailable", caveats[0])
        self.assertIn("HTTP 401: authentication required", caveats[0])
        self.assertIn("Top-level PR comment context unavailable", caveats[1])
        self.assertIn("HTTP 401: authentication required", caveats[1])


if __name__ == "__main__":
    unittest.main()
