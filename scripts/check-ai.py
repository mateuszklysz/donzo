#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Mateusz Kłysz
"""The repository's rules on AI tools (CONTRIBUTING.md) on a change: each of its commits (subject,
message, author, committer), the lines it adds to files, and the pull request's title and
description.

    check-ai.py [--base REV] [--title TEXT] [--body-file FILE]

--base defaults to the merge base with origin/main. Exits 1 and lists the problems when there are
any. The workflow .github/workflows/ai-rules.yml runs it on every pull request and push.
"""
from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import ai_rules  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
HUNK_RE = re.compile(r"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@")
# The files that state the rules, so name what they forbid.
RULE_FILES = {"scripts/ai_rules.py", "scripts/check-ai.py", "scripts/commit-msg.py",
              "scripts/test_ai_rules.py", "CONTRIBUTING.md", "CLAUDE.md"}


def git(*args: str) -> str:
    return subprocess.run(["git", *args], cwd=ROOT, check=True, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, text=True, errors="replace").stdout


def added_lines(base: str) -> list[tuple[str, int, str]]:
    """(path, line, text) of each line the change adds, rule files left out."""
    out, path, line, old_left, new_left = [], "", 0, 0, 0
    for row in git("diff", "--unified=0", "--no-color", "--no-ext-diff", base, "HEAD").splitlines():
        # inside a hunk by its counts: an added line "++ x" reads "+++ x" and is not a file header
        if old_left or new_left:
            if row.startswith("+"):
                new_left -= 1
                if path and path not in RULE_FILES:
                    out.append((path, line, row[1:]))
                line += 1
            elif row.startswith("-"):
                old_left -= 1
            elif row.startswith(" "):
                old_left, new_left, line = old_left - 1, new_left - 1, line + 1
            continue
        if row.startswith("+++ "):
            path = row[6:] if row.startswith("+++ b/") else ""
        elif row.startswith("@@"):
            m = HUNK_RE.match(row)
            old_left = int(m.group(2) or 1) if m else 0
            new_left = int(m.group(4) or 1) if m else 0
            line = int(m.group(3)) if m else 0
    return out


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--base", help="compare with this revision (default: merge base with origin/main)")
    ap.add_argument("--title", help="a pull request title, checked as a commit subject")
    ap.add_argument("--body-file", type=Path, help="a pull request description")
    args = ap.parse_args(argv)
    base = args.base or git("merge-base", "origin/main", "HEAD").strip()

    problems: list[str] = []
    for sha in git("rev-list", "--reverse", f"{base}..HEAD").split():
        where = f"commit {sha[:10]}"
        fields = git("log", "-1", "--format=%an%x00%ae%x00%cn%x00%ce%x00%B", sha).split("\0", 4)
        an, ae, cn, ce, message = fields
        subject = next((line for line in message.splitlines() if line.strip()), "")
        found = ai_rules.subject_problems(subject) + ai_rules.text_problems(message)
        found += ai_rules.identity_problems("author", an, ae)
        found += ai_rules.identity_problems("committer", cn, ce)
        problems += [f"{where}: {p}" for p in found]
    for path, line, text in added_lines(base):
        problems += [f"{path}:{line}: {p}" for p in ai_rules.text_problems(text)]
    if args.title is not None:
        problems += [f"pull request title: {p}" for p in
                     ai_rules.subject_problems(args.title) + ai_rules.text_problems(args.title)]
    if args.body_file:
        body = args.body_file.read_text(encoding="utf-8", errors="replace")
        problems += [f"pull request description: {p}" for p in ai_rules.text_problems(body)]

    for problem in problems:
        print(problem)
    if problems:
        print(f"\n{len(problems)} problems (CONTRIBUTING.md)", file=sys.stderr)
        return 1
    print("ai rules: no problems")
    return 0


if __name__ == "__main__":
    sys.exit(main())
