#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Mateusz Kłysz
"""Git hook: the repository's commit rules (CONTRIBUTING.md) on each commit you make.

    ln -sf ../../scripts/commit-msg.py .git/hooks/commit-msg

It drops agent trailers (Co-Authored-By, Claude-Session) from the message, then rejects the commit
when its subject is not a Conventional Commit, when the message still names a private AI session or
an AI tool footer, or when the author or committer is an AI agent. The pull request check
(scripts/check-ai.py) applies the same rules on GitHub.
"""
from __future__ import annotations

import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import ai_rules  # noqa: E402

SCISSORS = "# ------------------------ >8 ------------------------"


def identity(var: str) -> tuple[str, str]:
    ident = subprocess.run(["git", "var", var], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                           text=True).stdout
    name, _, rest = ident.partition(" <")
    return name, rest.split(">", 1)[0]


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: commit-msg.py <message file>", file=sys.stderr)
        return 2
    path = Path(sys.argv[1])
    # git writes the message as UTF-8 (Polish names in it); the locale's code page on Windows would garble them,
    # and bytes keep its line ends as they are
    raw = path.read_bytes().decode("utf-8", errors="replace")
    # `git commit -v`: the diff below the scissors line is not part of the message
    message, _, _ = raw.partition(SCISSORS)
    stripped = ai_rules.strip_trailers(message)
    if stripped != message and ai_rules.TRAILER_RE.search(message):
        path.write_bytes(stripped.encode("utf-8"))
        print("commit-msg: dropped agent trailer line(s) from the message", file=sys.stderr)
        message = stripped
    lines = [line for line in message.splitlines() if not line.lstrip().startswith("#")]
    subject = next((line for line in lines if line.strip()), "")
    problems = ai_rules.subject_problems(subject) + ai_rules.text_problems("\n".join(lines))
    for role, var in (("author", "GIT_AUTHOR_IDENT"), ("committer", "GIT_COMMITTER_IDENT")):
        problems += ai_rules.identity_problems(role, *identity(var))
    for problem in problems:
        print(f"commit-msg: {problem}", file=sys.stderr)
    if problems:
        print("commit-msg: see CONTRIBUTING.md", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
