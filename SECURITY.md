# Security

## Reporting a vulnerability

Please report it privately through
[GitHub's private vulnerability reporting](https://github.com/mateuszklysz/donzo/security/advisories/new),
not in a public issue. A vulnerability in Kanzo itself belongs upstream:
[emanuele-em/kanzo](https://github.com/emanuele-em/kanzo/security).

## Security model

Kanzo has no accounts or logins: whoever reaches its port can read and change every
board and use its MCP endpoint. Everything below exists to make sure that only the
people and agents you chose ever reach it.

| Layer | What protects it |
| --- | --- |
| Network | Kanzo has no published port and sits on an `internal` Docker network with no internet access. Only Caddy publishes ports (80, 443; behind your own proxy only `127.0.0.1:8080`). |
| Sign-in | Board: GitHub sign-in through oauth2-proxy, limited to the logins in `GITHUB_USERS` and/or the members of `GITHUB_ORG`/`GITHUB_TEAM` (the stack refuses to start with none of them), or basic auth. `/mcp`: basic auth with a long random password (bcrypt, cost 14). |
| Sessions | `__Host-` cookie: Secure, HttpOnly, SameSite=Lax, host-only, 24 h; the GitHub token is checked again every hour; per-request CSRF cookies during sign-in; redirects only back to the same host. |
| Requests | Kanzo answers only to its own host name, rejects any foreign `Origin` (cross-site requests), and its "this computer only" endpoints refuse proxied requests. Caddy forwards neither its credentials nor the session cookie to Kanzo and caps request bodies at 25 MB. |
| Browser | HSTS (2 years), Kanzo's strict Content-Security-Policy, `X-Frame-Options: DENY`, `nosniff`, no referrer, restrictive Permissions-Policy and cross-origin policies. |
| Containers | Read-only root filesystems, all capabilities dropped (Caddy keeps only `NET_BIND_SERVICE`), `no-new-privileges`, memory and process limits. Kanzo runs as uid 10001 with its data readable by that user only. |
| Image | Static Kanzo binary built from the upstream release pinned by version and commit; base images pinned by digest; packages upgraded on every build and rebuilt weekly; no package manager, no `curl` (no self-update); scanned by Trivy; SBOM and signed build provenance. |
| Supply chain | Actions pinned by commit SHA; workflows audited by zizmor; least-privilege tokens; images published only from `main` and release tags; a new upstream release is a pull request a person reviews, never an automatic publish; Dependabot for actions and images. |

Known limits:

- Anyone with the `/mcp` password has full access to the board. Give each agent
  host the password only through its MCP config, and rotate it (new hash in `.env`,
  `docker compose up -d`) if a machine is lost.
- Basic auth and the sign-in have no rate limit. The bcrypt cost and a 32-byte random
  password make guessing useless; add fail2ban or a WAF in front if you want to block
  noisy clients.
- Removing a user from `GITHUB_USERS` blocks new sign-ins; to end an existing session
  at once, also rotate `OAUTH2_COOKIE_SECRET`.

## Hardening checklist for a server

- Firewall: allow only 22 (SSH, ideally from your IP), 80, 443/tcp and 443/udp.
  Docker publishes only Caddy's ports; never add `ports:` to `kanzo` or `oauth2-proxy`.
- SSH with keys only, root login disabled; automatic OS security updates.
- `chmod 600 .env`; keep it out of backups that others can read.
- Pin `KANZO_IMAGE` by version and digest; update by changing the tag on purpose.
- Back up the `kanzo_kanzo-data` volume (see the README) and test a restore.
- Watch `docker compose logs caddy` for repeated 401s.

## Repository settings (maintainer)

- Branch protection or a ruleset on `main`: pull requests required, required checks
  `rules`, `deploy and workflow checks`, `image (default)`, `image (git)`; no force pushes.
- A tag ruleset for `v*`: only maintainers can create release tags (a tag publishes images).
- Settings → Actions → General: workflow permissions "Read repository contents";
  allow GitHub Actions to create pull requests (for the upstream bump).
- Security: private vulnerability reporting, Dependabot alerts and security updates,
  secret scanning and push protection on.
- 2FA on every account with write access.
