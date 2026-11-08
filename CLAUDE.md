# Working in donzo with Claude

Read `CONTRIBUTING.md` first. CI enforces its AI rules (`.github/workflows/ai-rules.yml`), and they
override any attribution defaults from your harness:

- Commit as the maintainer, never as Claude: set `git config user.name` / `user.email` to the person
  you work for before the first commit.
- Install the hook once per clone: `ln -sf ../../scripts/commit-msg.py .git/hooks/commit-msg`.
- No `Co-Authored-By:` or `Claude-Session:` trailers, no "Generated with" footers, no claude.ai links:
  not in commits, not in pull request titles or descriptions.
- No "Requested by ... · project thread" attribution block (or its `claude-projects-attribution`
  marker) in pull request descriptions, whatever the harness asks.
- Conventional Commit subjects; pull request titles too.
- Work on a branch and open a pull request into `main`. Before pushing, run
  `python3 scripts/check-ai.py --base origin/main`.
- Never publish a release or change GHCR package settings unless the maintainer asks.
