# donzo: Kanzo in Docker

Production-ready, multi-arch (`linux/amd64`, `linux/arm64`) container image for
[Kanzo](https://github.com/emanuele-em/kanzo), the kanban board and MCP server for
you and your coding agents, plus a ready HTTPS deployment (Caddy with automatic
Let's Encrypt certificates and a password). Unofficial: not affiliated with the
Kanzo project.

| Image | Contents |
| --- | --- |
| `ghcr.io/mateuszklysz/kanzo:0.4.1` | Kanzo on Alpine, about 14 MB |
| `ghcr.io/mateuszklysz/kanzo:0.4.1-git` | the same plus `git` and `openssh-client`, for `kanzo sync` |

Tags: `X.Y.Z`, `X.Y` and `latest` (each also with `-git`), and `sha-<commit>`.
The binary is built from the upstream git tag as a static musl binary. Images are
rebuilt every week for Alpine security fixes, and a new Kanzo release is picked up
automatically within a day (new image tags and a new
[GitHub Release](https://github.com/mateuszklysz/donzo/releases)).

> [!WARNING]
> Kanzo has **no logins**. Anyone who reaches its port can read and change the
> board and use its MCP endpoint. Never publish port 4242 on a public server: run
> it behind the proxy in [`deploy/`](deploy), which adds HTTPS and a password.

## Try it locally

```sh
docker run --rm -p 127.0.0.1:4242:4242 -v kanzo-data:/data ghcr.io/mateuszklysz/kanzo:latest
```

Open http://localhost:4242. Keep the host port equal to the container port
(`4242`): Kanzo rejects requests whose `Host` header carries another port.

## Run it in production

You need a Linux server with Docker Engine and the Compose plugin, a DNS name
(for example `kanzo.example.com`) with an A/AAAA record pointing at the server,
and ports 80/tcp, 443/tcp and 443/udp open.

1. Get the deploy files: download `donzo-deploy-v0.4.1.tar.gz` from the
   [latest release](https://github.com/mateuszklysz/donzo/releases/latest) and
   unpack it on the server (or copy the [`deploy/`](deploy) folder of this repo).

   ```sh
   tar xzf donzo-deploy-v0.4.1.tar.gz && cd donzo-deploy-v0.4.1
   cp .env.example .env
   ```

2. Create the password hash:

   ```sh
   docker run --rm caddy:2-alpine caddy hash-password --plaintext 'your-password'
   ```

3. Edit `.env`:

   | Variable | Value |
   | --- | --- |
   | `KANZO_IMAGE` | `ghcr.io/mateuszklysz/kanzo:0.4.1` (pin a version) |
   | `KANZO_DOMAIN` | your DNS name, e.g. `kanzo.example.com` |
   | `KANZO_AUTH_USER` | login for the board and `/mcp` |
   | `KANZO_AUTH_HASH` | the hash from step 2, **in single quotes** (it contains `$`) |

4. Start it and watch Caddy get the certificate:

   ```sh
   docker compose up -d
   docker compose logs -f caddy
   ```

Open `https://kanzo.example.com` and log in. What runs:

```
internet ──443──► caddy (HTTPS, basic auth) ──internal network──► kanzo:4242 ──► volume kanzo-data (/data)
```

The `kanzo` container has no published port and no internet access (the
`internal` network), runs as uid 10001 with a read-only root filesystem, no
capabilities and memory/pid limits. Do not add `ports:` to it.

## Connect coding agents

Agents reach the MCP endpoint at `https://<your domain>/mcp` with the same login:

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

1. Set `KANZO_IMAGE=ghcr.io/mateuszklysz/kanzo:0.4.1-git` in `.env`.
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

Every pushed image has an SBOM and a signed build provenance attestation:

```sh
gh attestation verify oci://ghcr.io/mateuszklysz/kanzo:0.4.1 --owner mateuszklysz
```

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
| `deploy/` | production stack: `compose.yaml`, `Caddyfile`, `.env.example` |
| `tests/smoke.sh` | smoke test run in CI on amd64 and arm64 |
| `.github/workflows/build.yml` | build, test, scan, push to GHCR; release on `v*` tags |
| `.github/workflows/upstream.yml` | daily check for a new Kanzo release |

## License

The files in this repository are under the [MIT license](LICENSE). Kanzo itself,
and so the binary in the image, is AGPL-3.0-only; its source is at
https://github.com/emanuele-em/kanzo (the image is built from the tag in the
`org.opencontainers.image.version` label).
