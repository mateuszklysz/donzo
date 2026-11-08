#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Mateusz Kłysz
"""Tests of scripts/ai_rules.py: python3 scripts/test_ai_rules.py -v"""
import importlib.util
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import ai_rules  # noqa: E402


def script(name):
    """scripts/<name>.py as a module (its name has a hyphen)."""
    spec = importlib.util.spec_from_file_location(name.replace("-", "_"), HERE / f"{name}.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class Subject(unittest.TestCase):
    def test_conventional(self):
        self.assertEqual(ai_rules.subject_problems("feat(devlogs): segment cache"), [])
        self.assertEqual(ai_rules.subject_problems("fix: keep the rail"), [])
        self.assertEqual(ai_rules.subject_problems("feat!: drop 1.11"), [])

    def test_bad(self):
        self.assertTrue(ai_rules.subject_problems("Ride the board"))
        self.assertTrue(ai_rules.subject_problems("feature: ride"))
        self.assertTrue(ai_rules.subject_problems("fix: the rail."))

    def test_git_subjects(self):
        self.assertEqual(ai_rules.subject_problems("Merge branch 'main'"), [])


class Text(unittest.TestCase):
    def test_trailers(self):
        self.assertTrue(ai_rules.text_problems("x\n\nCo-Authored-By: Claude <noreply@anthropic.com>"))  # ai-rules: allow
        self.assertTrue(ai_rules.text_problems("Claude-Session: https://example.com/x"))  # ai-rules: allow

    def test_person_credit_kept(self):
        self.assertEqual(ai_rules.text_problems(
            "Co-authored-by: dana <123+dana@users.noreply.github.com>"), [])  # ai-rules: allow

    def test_links_and_footers(self):
        self.assertTrue(ai_rules.text_problems("see https://claude.ai/code/session_01abc"))  # ai-rules: allow
        self.assertTrue(ai_rules.text_problems("Generated with [Claude Code](https://claude.com)"))  # ai-rules: allow
        self.assertTrue(ai_rules.text_problems("\U0001F916 Generated with something"))  # ai-rules: allow

    def test_project_attribution(self):
        self.assertTrue(ai_rules.text_problems(
            '<!-- claude-projects-attribution: {"github_login":"dana"} -->'))  # ai-rules: allow
        self.assertTrue(ai_rules.text_problems(
            "_Requested by **Dana** \u00b7 [project thread](https://example.com/x)_"))  # ai-rules: allow
        self.assertTrue(ai_rules.text_problems(
            "Requested by Dana \u00b7 project thread"))  # ai-rules: allow
        self.assertTrue(ai_rules.text_problems(
            "https://claude.ai/code/project/chan_01?thread=cmsg_01"))  # ai-rules: allow
        self.assertEqual(ai_rules.text_problems("Requested by the owner in issue #3"), [])

    def test_prose_about_claude_is_fine(self):
        self.assertEqual(ai_rules.text_problems("The co-authored-by rule is in CONTRIBUTING.md"), [])

    def test_waiver(self):
        self.assertEqual(ai_rules.text_problems("Claude-Session: x  ai-rules: allow"), [])


class Identity(unittest.TestCase):
    def test_agents(self):
        self.assertTrue(ai_rules.identity_problems("author", "Claude", "noreply@anthropic.com"))
        self.assertTrue(ai_rules.identity_problems("author", "Someone", "bot@openai.com"))
        self.assertTrue(ai_rules.identity_problems("committer", "claude[bot]",
                                                   "209825114+claude[bot]@users.noreply.github.com"))
        self.assertTrue(ai_rules.identity_problems("author", "Copilot", "198982749+Copilot@users.noreply.github.com"))

    def test_people(self):
        self.assertEqual(ai_rules.identity_problems("author", "Mateusz Kłysz", "mateuszklysz@icloud.com"), [])
        self.assertEqual(ai_rules.identity_problems("committer", "GitHub", "noreply@github.com"), [])

    def test_strip(self):
        text = "feat: x\n\nbody\n\nCo-Authored-By: Claude <noreply@anthropic.com>\n"  # ai-rules: allow
        self.assertEqual(ai_rules.strip_trailers(text), "feat: x\n\nbody\n")


class AddedLines(unittest.TestCase):
    def test_hunks(self):
        """An added line that starts with "++" is a line, not a file header; counts end each hunk."""
        diff = "\n".join([
            "diff --git a/x.md b/x.md", "--- a/x.md", "+++ b/x.md",
            "@@ -3,2 +3,3 @@", "-old", "--- gone", "+new", "+++ also added", "+third",
            "@@ -10 +11 @@", "-a", "+b",
            "diff --git a/y.py b/y.py", "new file mode 100644", "--- /dev/null", "+++ b/y.py",
            "@@ -0,0 +1 @@", "+print()", ""])
        check = script("check-ai")
        with mock.patch.object(check, "git", return_value=diff):
            self.assertEqual(check.added_lines("base"), [
                ("x.md", 3, "new"), ("x.md", 4, "++ also added"), ("x.md", 5, "third"), ("x.md", 11, "b"),
                ("y.py", 1, "print()")])


class Hook(unittest.TestCase):
    def run_hook(self, text):
        with tempfile.TemporaryDirectory() as tmp:
            msg = Path(tmp) / "COMMIT_EDITMSG"
            msg.write_bytes(text.encode("utf-8"))
            env = {**os.environ, "GIT_AUTHOR_NAME": "Mateusz Kłysz", "GIT_AUTHOR_EMAIL": "m@example.com",
                   "GIT_COMMITTER_NAME": "Mateusz Kłysz", "GIT_COMMITTER_EMAIL": "m@example.com"}
            r = subprocess.run([sys.executable, str(HERE / "commit-msg.py"), str(msg)], capture_output=True,
                               text=True, env=env, cwd=HERE)
            return r.returncode, msg.read_bytes().decode("utf-8")

    def test_strips_and_keeps_utf8(self):
        rc, out = self.run_hook("fix(devlogs): łódź\n\nZażółć gęślą jaźń\n\n"
                                "Co-Authored-By: Claude <noreply@anthropic.com>\n")  # ai-rules: allow
        self.assertEqual(rc, 0)
        self.assertEqual(out, "fix(devlogs): łódź\n\nZażółć gęślą jaźń\n")

    def test_diff_below_scissors_is_not_checked(self):
        rc, _ = self.run_hook("fix(devlogs): x\n\n# ------------------------ >8 ------------------------\n"
                              "+see https://claude.ai/code/session_01abc\n")  # ai-rules: allow
        self.assertEqual(rc, 0)


if __name__ == "__main__":
    unittest.main()
