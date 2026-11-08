# Contributing

Work on a branch and open a pull request into `main`. Commit subjects and pull request titles are
Conventional Commits: `<type>(<scope>): <summary>`, for example `fix(deploy): pass the Host header`.
Types: build, chore, ci, docs, feat, fix, perf, refactor, revert, style, test. At most 100
characters, no full stop at the end.

Before you push a change to the image, build it and run the smoke test:

```sh
docker buildx build --platform linux/amd64 -t kanzo:local --load .
tests/smoke.sh kanzo:local linux/amd64
```

A release is a tag `vX.Y.Z` (the Kanzo version in the `Dockerfile`) or `vX.Y.Z-N` for a rebuild of
the same version; pushing it publishes the images and the GitHub Release.

## AI tools

You may use an AI agent, but what lands in the history is yours:

- No agent trailers (`Co-Authored-By:`, `Claude-Session:`) in commits, pull request descriptions or
  review comments. The only co-author line allowed names a person by their GitHub noreply address:
  `Co-authored-by: login <12345+login@users.noreply.github.com>`.
- No AI tool footers ("Generated with ...") and no links to AI chats or agent sessions (claude.ai,
  chatgpt.com): sessions are private.
- No agent attribution blocks in pull requests ("Requested by ... · project thread", the
  `claude-projects-attribution` marker, claude.ai project links).
- Author and committer are you, never an AI agent (an anthropic.com or openai.com address, Claude,
  Copilot or another bot).

The `ai-rules` workflow (`scripts/check-ai.py`) checks every pull request and every push to `main`,
and blocks the merge when it fails. Install the same check as a commit hook, once per clone:

```sh
ln -sf ../../scripts/commit-msg.py .git/hooks/commit-msg
```

The hook drops agent trailers from your message and rejects the rest. A line that must name what the
rules forbid (a test of the rules) carries `ai-rules: allow`. Before you open a pull request:

```sh
python3 scripts/check-ai.py --base origin/main
```
