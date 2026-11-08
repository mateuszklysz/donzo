# donzo: Kanzo in Docker

Production-ready, multi-arch (`linux/amd64`, `linux/arm64`) container image for
[Kanzo](https://github.com/emanuele-em/kanzo), the kanban board and MCP server for
you and your coding agents, plus a ready HTTPS deployment (Caddy with automatic
Let's Encrypt certificates, GitHub sign-in or a password). Unofficial: not affiliated with the
Kanzo project.

Sign in to the board with your **GitHub account** (oauth2-proxy) or a password;
coding agents use the MCP endpoint with a password, or sign in with GitHub too (Claude's
custom connectors, through mcp-auth-proxy).

| Image | Contents |
| --- | --- |
| `ghcr.io/nickyyoo/kanzo:0.4.1` | Kanzo on Alpine, about 14 MB |
| `ghcr.io/nickyyoo/kanzo:0.4.1-git` | the same plus `git` and `openssh-client`, for `kanzo sync` |

Tags: `X.Y.Z`, `X.Y` and `latest` (each also with `-git`), and `sha-<commit>`.
The binary is built as a static musl binary from the upstream release, pinned by
version and commit. Images are rebuilt every week with the latest Alpine security
fixes. A new Kanzo release arrives as a pull request within a day and is published
(image tags and a [GitHub Release](https://github.com/nickyyOO/donzo/releases))
only after it is reviewed, merged and tagged. See [SECURITY.md](SECURITY.md) for the
security model.

> [!WARNING]
> Kanzo has **no logins**. Anyone who reaches its port can read and change the
> board and use its MCP endpoint. Never publish port 4242 on a public server: run
> it behind the proxy in [`deploy/`](deploy), which adds HTTPS and GitHub sign-in or a password.

## Try it locally

```sh
docker run --rm -p 127.0.0.1:4242:4242 -v kanzo-data:/data ghcr.io/nickyyoo/kanzo:latest
```

Open http://localhost:4242. Keep the host port equal to the container port
(`4242`): Kanzo rejects requests whose `Host` header carries another port.

## Run it in production

You need a Linux server with Docker Engine and the Compose plugin, a DNS name
(for example `kanzo.example.com`) with an A/AAAA record pointing at the server,
and ports 80/tcp, 443/tcp and 443/udp open. Does the domain already have a certificate,
or does another proxy already run HTTPS on the server? See
[Use a certificate you already have](#use-a-certificate-you-already-have).

1. Get the deploy files: download `donzo-deploy-v0.4.1.tar.gz` from the
   [latest release](https://github.com/nickyyOO/donzo/releases/latest) and
   unpack it on the server (or copy the [`deploy/`](deploy) folder of this repo).

   ```sh
   gh attestation verify donzo-deploy-v0.4.1.tar.gz --owner nickyyOO   # optional
   tar xzf donzo-deploy-v0.4.1.tar.gz && cd donzo-deploy-v0.4.1
   cp .env.example .env && chmod 600 .env   # .env holds secrets
   ```

2. Create a long random password (agents use it for `/mcp`, so nobody types it)
   and its hash:

   ```sh
   openssl rand -base64 32                     # the password: keep it in a password manager
   docker run --rm caddy:2-alpine caddy hash-password --plaintext 'the-password'
   ```

3. Edit `.env`:

   | Variable | Value |
   | --- | --- |
   | `KANZO_IMAGE` | `ghcr.io/nickyyoo/kanzo:0.4.1` (pin a version) |
   | `KANZO_DOMAIN` | your DNS name, e.g. `kanzo.example.com` |
   | `KANZO_AUTH_USER` | login for the board and `/mcp` |
   | `KANZO_AUTH_HASH` | the hash from step 2, **in single quotes** (it contains `$`) |

4. Optional, recommended: [sign in with GitHub](#sign-in-with-github) instead of the
   password for the board.

5. Start it and watch Caddy get the certificate:

   ```sh
   docker compose up -d
   docker compose logs -f caddy
   ```

Open `https://kanzo.example.com` and log in. What runs:

```
internet ──443──► caddy (HTTPS, sign-in) ──internal network──► kanzo:4242 ──► volume kanzo-data (/data)
                     └── with GitHub sign-in: forward_auth ──► oauth2-proxy:4180 ──► GitHub API
```

The `kanzo` container has no published port and no internet access (the
`internal` network), runs as uid 10001 with a read-only root filesystem, no
capabilities and memory/pid limits. Do not add `ports:` to it.

### Sign in with GitHub

The board then asks for a GitHub login instead of the password; only the GitHub
accounts you list (plus, optionally, members of an org or team) get in. `/mcp` keeps
the password from `KANZO_AUTH_USER`/`KANZO_AUTH_HASH`, unless you add GitHub sign-in for
it too ([Connect Claude with GitHub sign-in](#connect-claude-with-github-sign-in)).

1. Create a GitHub OAuth app: GitHub → Settings → Developer settings →
   [OAuth Apps](https://github.com/settings/developers) → New OAuth App.
   - Homepage URL: `https://kanzo.example.com`
   - Authorization callback URL: `https://kanzo.example.com/oauth2/callback`

   Then generate a client secret.
2. In `.env`:

   | Variable | Value |
   | --- | --- |
   | `COMPOSE_FILE` | `compose.yaml:compose.sso.yaml` (uncomment the line) |
   | `GITHUB_CLIENT_ID`, `GITHUB_CLIENT_SECRET` | from the OAuth app |
   | `OAUTH2_COOKIE_SECRET` | output of `openssl rand -base64 32 \| tr -- '+/' '-_'` |
   | `GITHUB_USERS` | GitHub logins allowed in, comma-separated |
   | `GITHUB_ORG`, `GITHUB_TEAM` | allow an org's members, or teams as `org:team,...` (set at least one of these three); then also set `GITHUB_SCOPE=user:email read:org` |

   Sign-in asks GitHub only for read access to the account's email addresses
   (`user:email`), plus organization membership (`read:org`) when you set `GITHUB_SCOPE` for
   an org or team. The OAuth app needs no other permissions; on GitHub's consent screen
   don't grant it access to any organization unless you use `GITHUB_ORG`/`GITHUB_TEAM`.

3. `docker compose up -d`. A session lasts 24 hours; every hour oauth2-proxy checks
   with GitHub that the user's token still works, so revoking the app in GitHub
   (Settings → Applications) signs that user out within the hour.

The sign-in and error pages are styled like Kanzo (light and dark, with Kanzo's logo)
and live in `deploy/sso-templates/`; the board shows one "Continue with GitHub" page
before GitHub. Kanzo's `/logo.png` and `/icon.png` are reachable without signing in,
for that page. The files must stay world-readable: oauth2-proxy runs as uid 65532.

Removing someone from `GITHUB_USERS` (or the org/team) stops new sign-ins at once.
To end their current session too, also change `OAUTH2_COOKIE_SECRET` and run
`docker compose up -d` (this signs everyone out).

### Use a certificate you already have

By default Caddy gets a Let's Encrypt certificate for `KANZO_DOMAIN` by itself.
If the domain already has HTTPS, pick the case that fits and add its file to
`COMPOSE_FILE` in `.env` (after `compose.sso.yaml` when you use GitHub sign-in).
Sign-in, `/mcp` and all checks work the same in every case.

**Your own certificate files** (a wildcard, a company CA, a Cloudflare origin
certificate, ...): Caddy keeps ports 80 and 443 and uses your files instead of
Let's Encrypt.

```sh
# .env
COMPOSE_FILE=compose.yaml:compose.tls-files.yaml
```

Put the full chain and the key in `deploy/certs/` as `fullchain.pem` and `privkey.pem`
(or set `KANZO_CERTS_DIR` to their folder). Copy real files, not certbot's
`live/` symlinks, which point outside the folder. After each renewal run
`docker compose restart caddy`.

**Another reverse proxy already does HTTPS on the server** (nginx, Traefik, another
Caddy): Caddy gives up ports 80/443, serves plain HTTP on `127.0.0.1:8080` only and
keeps the sign-in; your proxy forwards the domain to it.

```sh
# .env
COMPOSE_FILE=compose.yaml:compose.behind-proxy.yaml
#KANZO_HTTP_BIND=127.0.0.1   # change only if the proxy runs on another host or network
#KANZO_HTTP_PORT=8080
```

Your proxy must pass the original `Host`, append `X-Forwarded-For`, allow 25 MB
uploads and not buffer responses (MCP streams them). For nginx:

```nginx
server {
    listen 443 ssl;
    http2 on;
    server_name kanzo.example.com;
    ssl_certificate     /etc/ssl/kanzo/fullchain.pem;
    ssl_certificate_key /etc/ssl/kanzo/privkey.pem;
    client_max_body_size 25m;

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_http_version 1.1;
        proxy_buffering off;
        proxy_read_timeout 1h;
    }
}
```

Caddy takes the visitor's address from the last `X-Forwarded-For` entry your proxy
adds, so a visitor can't fake it. Serve the board only over HTTPS: the GitHub sign-in
cookie and Kanzo's checks expect the browser to see `https://`.

For systemd-managed deployments with Podman (such as on Fedora CoreOS or RHEL) or behind Nginx Proxy Manager, see [Podman Quadlet](deploy/quadlet/).

## Connect coding agents

Agents reach the MCP endpoint at `https://<your domain>/mcp` with the
`KANZO_AUTH_USER` login and its password (with or without GitHub sign-in):

```sh
claude mcp add --transport http kanzo https://kanzo.example.com/mcp \
  --header "Authorization: Basic $(printf 'admin:your-password' | base64)"
```

Over HTTP Kanzo cannot see the agent's folder. Either the agent passes `project`
to the tools, or a per-repo MCP config (`.mcp.json`) adds headers so Kanzo finds
the project from the repo, as `kanzo mcp` does locally:

```json
{ "mcpServers": { "kanzo": {
  "type": "http",
  "url": "https://kanzo.example.com/mcp",
  "headers": {
    "Authorization": "Basic <base64 of user:password>",
    "X-Kanzo-Folder": "/path/to/this/repo",
    "X-Kanzo-Repos": "your-org/this-repo"
  }
} } }
```

### Connect Claude with GitHub sign-in

Claude's custom connectors (claude.ai, Claude Desktop) can't send a password; they sign
in with OAuth. `compose.mcp-oauth.yaml` puts
[mcp-auth-proxy](https://github.com/sigbit/mcp-auth-proxy) in front of `/mcp`: the client
registers itself, you sign in with GitHub in a browser window once, and it gets its own
token. The board's sign-in doesn't change. `/mcp` then no longer takes the password, so
agents connect the same way.

1. In the GitHub app you use for the board's sign-in, add a second callback URL:
   `https://kanzo.example.com/.auth/github/callback`. A GitHub App takes several callback
   URLs. An OAuth App takes only one: change it to `https://kanzo.example.com/` (GitHub
   accepts every path below it, so the board's `/oauth2/callback` keeps working). No new
   permissions: when only logins are allowed, mcp-auth asks GitHub for no scopes and only
   reads who signed in.
2. In `.env`: add `:compose.mcp-oauth.yaml` to `COMPOSE_FILE` and set `MCP_GITHUB_USERS`
   to the GitHub logins that may connect, comma-separated and written exactly as on GitHub
   (upper/lower case matters).
3. `docker compose up -d`.
4. Claude: Settings → Connectors → Add custom connector, URL
   `https://kanzo.example.com/mcp`, OAuth Client ID and Secret empty. Connect, then sign
   in with GitHub and press Authorize. Claude Code:

   ```sh
   claude mcp add --transport http kanzo https://kanzo.example.com/mcp
   ```

   then `/mcp` in Claude Code to sign in.

It also works without `compose.sso.yaml` (password for the board, GitHub for `/mcp`); it
still needs `GITHUB_CLIENT_ID` and `GITHUB_CLIENT_SECRET` from a GitHub app. The image is
`ghcr.io/nickyyoo/kanzo-mcp-auth`, built in this repository from mcp-auth-proxy's release
pinned by commit (`mcp-auth/Dockerfile`), as a static binary on distroless.

A token lasts 24 hours and is renewed for up to 30 days. Removing someone from
`MCP_GITHUB_USERS` stops new sign-ins; to end every connection at once, delete the
signing key and tokens: `docker compose rm -sf mcp-auth && docker volume rm
kanzo_mcp-auth-data && docker compose up -d` (everyone connects again).

`kanzo join` does **not** work through HTTPS (it speaks plain HTTP to port 4242).

## Update

Change the tag in `KANZO_IMAGE` in `.env`, then:

```sh
docker compose pull && docker compose up -d
```

The update button on the board does nothing in the container, on purpose: the
image has no `curl`, so updates always come from a new image tag.

## Backup and restore

```sh
# tasks as JSON (no images)
docker compose exec kanzo kanzo export -f json > kanzo-$(date +%F).json

# full copy of the data volume (database, images, config)
docker compose stop kanzo
docker run --rm -v kanzo_kanzo-data:/data -v "$PWD":/b alpine tar czf /b/kanzo-data-$(date +%F).tgz -C /data .
docker compose start kanzo

# restore that copy into the volume
docker compose stop kanzo
docker run --rm -v kanzo_kanzo-data:/data -v "$PWD":/b alpine sh -c 'tar xzf /b/kanzo-data-YYYY-MM-DD.tgz -C /data && chown -R 10001:10001 /data'
docker compose start kanzo
```

### Sync to a git repo (`-git` image)

1. Set `KANZO_IMAGE=ghcr.io/nickyyoo/kanzo:0.4.1-git` in `.env`.
2. Set `KANZO_GIT_TOKEN` to a fine-grained token with Contents read/write on one
   private repository for the data.
3. In `compose.yaml`, change the `kanzo` service to `networks: [internal, public]`
   (the `internal` network has no internet access).
4. `docker compose up -d`, then Settings → Sync on the board, or
   `docker compose exec kanzo kanzo sync --repo https://github.com/<you>/kanzo-data`.

The token is read from the environment when git asks for it; it is never written
to disk or put in a URL.

## Configuration

| Variable | Default | |
| --- | --- | --- |
| `KANZO_PORT` | `4242` | Port inside the container. |
| `KANZO_MCP_HTTP` | `true` | Serve MCP at `/mcp`. Only used when `config.toml` is first created. |
| `KANZO_GIT_TOKEN` | – | `-git` image: token for `kanzo sync` over HTTPS. |
| `KANZO_GIT_USER` | `x-access-token` | `-git` image: username sent with the token. |

Data lives in the `/data` volume: `kanzo.db`, `images/` and `config.toml`. On
first start the container writes `config.toml` with `listen = "0.0.0.0"`; an
existing file is never changed, so edit it there for other Kanzo settings. A
bind-mounted folder must be owned by uid/gid `10001`. Run a single instance per
volume: Kanzo uses SQLite and file locks.

Kanzo only answers to `Host` names it knows (`localhost`, IP addresses and its own
hostname), which is why `deploy/compose.yaml` sets `hostname: ${KANZO_DOMAIN}`.
Caddy changes only the scheme of the `Origin` header (`https://` to `http://`), so
Kanzo's cross-site request check still rejects foreign origins.

## Verify an image

Every pushed image has an SBOM and a signed build provenance attestation, and so
does the release's deploy bundle:

```sh
gh attestation verify oci://ghcr.io/nickyyoo/kanzo:0.4.1 --owner nickyyOO
gh attestation verify donzo-deploy-v0.4.1.tar.gz --owner nickyyOO
```

In production, pin the image by digest as well (`KANZO_IMAGE=ghcr.io/nickyyoo/kanzo:0.4.1@sha256:…`; the digest is
shown by `docker buildx imagetools inspect ghcr.io/nickyyoo/kanzo:0.4.1`).

## Build it yourself

```sh
docker buildx build --platform linux/amd64,linux/arm64 -t kanzo:local .            # default image
docker buildx build --platform linux/amd64 --target git -t kanzo:local-git --load .  # with git
tests/smoke.sh kanzo:local-git linux/amd64                                          # needs curl on the host
```

## Repository layout

| Path | |
| --- | --- |
| `Dockerfile`, `docker-entrypoint.sh` | the image |
| `deploy/` | production stack: `compose.yaml`, `Caddyfile`, `.env.example`; GitHub sign-in: `compose.sso.yaml`, `Caddyfile.sso`, `sso-templates/`; own certificate: `compose.tls-files.yaml`; behind another proxy: `compose.behind-proxy.yaml`; GitHub sign-in for `/mcp`: `compose.mcp-oauth.yaml`; Podman Quadlet: [`deploy/quadlet/`](deploy/quadlet/) |
| `mcp-auth/Dockerfile` | the mcp-auth image (mcp-auth-proxy, MIT) for `compose.mcp-oauth.yaml` |
| `tests/smoke.sh`, `tests/smoke-mcp-auth.sh` | smoke tests run in CI on amd64 and arm64 |
| `SECURITY.md` | security model, hardening, reporting a vulnerability |
| `.github/workflows/build.yml` | build, test, scan, push to GHCR; release on `v*` tags |
| `.github/workflows/upstream.yml` | daily check: a pull request for each new Kanzo release |
| `.github/workflows/ai-rules.yml`, `scripts/` | rules on AI tools in commits and pull requests ([CONTRIBUTING.md](CONTRIBUTING.md)) |

## License

The files in this repository are under the [MIT license](LICENSE). Kanzo itself,
and so the binary in the image, is AGPL-3.0-only; its source is at
https://github.com/emanuele-em/kanzo (the image is built from the tag in the
`org.opencontainers.image.version` label).
