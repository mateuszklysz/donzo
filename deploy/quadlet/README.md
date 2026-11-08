# Deploying Kanzo with Podman Quadlets

[Quadlet](https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html) manages Podman containers declaratively as systemd services. This setup runs Kanzo and `oauth2-proxy` behind an external reverse proxy (such as Nginx Proxy Manager, standalone Nginx, or Traefik) on Fedora CoreOS, RHEL, or Fedora.

## Architecture

```text
Browser (HTTPS)
  └─► External Reverse Proxy (e.g. Nginx Proxy Manager :443)
        └─► oauth2-proxy (:4180 in kanzo-internal network)
              └─► Kanzo (:4242 in kanzo-internal network)
```

## Setup

### 1. Copy Quadlet Unit Files

* **System-wide / Rootful (e.g. Fedora CoreOS):**
  Copy the unit files to `/etc/containers/systemd/`:

  ```sh
  sudo mkdir -p /etc/containers/systemd
  sudo cp deploy/quadlet/kanzo.container \
          deploy/quadlet/kanzo-oauth2-proxy.container \
          deploy/quadlet/kanzo-data.volume \
          deploy/quadlet/kanzo.network \
          /etc/containers/systemd/
  ```

* **Rootless (User mode):**
  Copy the files to `~/.config/containers/systemd/`.

### 2. Configure Environment

Copy `kanzo.env.example` to `kanzo.env` alongside the unit files:

```sh
sudo cp deploy/quadlet/kanzo.env.example /etc/containers/systemd/kanzo.env
sudo chmod 0600 /etc/containers/systemd/kanzo.env
```

Fill in:
* `OAUTH2_PROXY_CLIENT_ID` and `OAUTH2_PROXY_CLIENT_SECRET`
* `OAUTH2_PROXY_COOKIE_SECRET` (`openssl rand -base64 32 | tr -- '+/' '-_'`)
* `OAUTH2_PROXY_GITHUB_ORG` or `OAUTH2_PROXY_GITHUB_USERS`

### 3. Set the Container Hostname

In `kanzo.container`, set `HostName` to match your public domain:

```ini
HostName=kanzo.example.com
```

> **Why this is required:** Kanzo validates the incoming `Host` header against the machine's local hostname to protect against DNS rebinding. If `HostName` does not match the external domain, Kanzo returns `403 Forbidden: kanzo does not answer requests from other sites`.

### 4. Start the Services

```sh
sudo systemctl daemon-reload
sudo systemctl start kanzo kanzo-proxy
```

To enable them across reboots:

```sh
sudo systemctl enable kanzo kanzo-proxy
```

Check status and logs:

```sh
sudo systemctl status kanzo kanzo-proxy
sudo journalctl -u kanzo -f
sudo journalctl -u kanzo-proxy -f
```

---

## Reverse Proxy Integration (Nginx Proxy Manager / Nginx)

### Kanzo CSRF Protection

Kanzo enforces that any state-changing request (POST, PUT, DELETE) includes an `Origin` header matching:

$$\text{Origin} == \text{"http://"} + \text{Host}$$

Because Kanzo runs on plain HTTP internally, it strictly requires the `http://` scheme. If a browser sends `Origin: https://kanzo.example.com`, Kanzo rejects the request with:

```text
403 Forbidden: kanzo does not answer requests from other sites
```

To solve this, your front-facing reverse proxy must rewrite the `Origin` header scheme from `https://` to `http://` before forwarding the request to `oauth2-proxy`.

### Nginx Proxy Manager (NPM) Configuration

In Nginx, child `location` blocks inherit `proxy_set_header` directives from a parent `server` block **only if** the `location` block contains no `proxy_set_header` directives of its own.

Because NPM injects its own `proxy_set_header` directives inside its default `location /` block, placing `proxy_set_header Origin ...` into the NPM **Advanced** tab at the `server` level is silently ignored.

To configure NPM properly:
1. Open your Proxy Host in Nginx Proxy Manager.
2. In the **Details** tab:
   * **Forward Hostname / IP:** `kanzo-proxy` (or the container/host IP)
   * **Forward Port:** `4180`
   * **Block Common Exploits:** On
   * **Websockets Support:** On
3. Go to the **Advanced** tab and override the entire `location /` block:

```nginx
location / {
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header X-Forwarded-Host $host;
    proxy_set_header X-Forwarded-Port $server_port;

    # Rewrite Origin from https to http for Kanzo CSRF protection
    set $kanzo_origin $http_origin;
    if ($http_origin ~* "^https://(.*)$") {
        set $kanzo_origin "http://$1";
    }
    proxy_set_header Origin $kanzo_origin;

    proxy_pass $forward_scheme://$server:$port;

    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection $http_connection;
    proxy_buffering off;
    proxy_read_timeout 1h;
}
```

---

## GitHub Authentication: OAuth App vs. GitHub App

When restricting access to a GitHub organization using `OAUTH2_PROXY_GITHUB_ORG`:

1. **Use a GitHub OAuth App (Recommended):**
   * Register a new OAuth App at **GitHub** → **Settings** → **Developer settings** → **OAuth Apps**.
   * Set `OAUTH2_PROXY_SCOPE="user:email read:org"`.
   * The `read:org` scope allows `oauth2-proxy` to verify membership even when members have their organization membership visibility set to **Private** (the default on GitHub).
   * Ensure that third-party access is granted under organization settings if policy restrictions are enabled.

2. **Using a GitHub App (Caveat):**
   * GitHub Apps issue user-to-server tokens that do not utilize OAuth scopes.
   * GitHub's `/user/orgs` endpoint ignores GitHub App permissions for private memberships and returns `[]`, causing `oauth2-proxy` to fail with:
     ```text
     [github.go:174] Missing Organization:"<org>" in []
     [oauthproxy.go:963] Error creating session during OAuth2 callback: user is missing required organization
     ```
   * If you must use a GitHub App, every organization member must change their membership visibility from **Private** to **Public** at `https://github.com/orgs/<org>/people`.

3. **Fallback to Specific Users:**
   * To authorize individual users instead of an organization, remove or unset `OAUTH2_PROXY_GITHUB_ORG` and set:
     ```ini
     OAUTH2_PROXY_SCOPE=user:email
     OAUTH2_PROXY_GITHUB_USERS=user1,user2
     ```
   * Note: `OAUTH2_PROXY_GITHUB_ORG` must not be set when relying on `OAUTH2_PROXY_GITHUB_USERS` alone, as any failure in the organization check halts authentication during callback.
