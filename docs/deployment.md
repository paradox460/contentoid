# Deploying Contentoid

Contentoid runs as one container next to Postgres. It doesn't run downloads itself: it asks the
host's Docker (or Podman) daemon, through its socket, to start one container per download and per
post-processor. Those containers are siblings of Contentoid's, not children.

```mermaid
flowchart LR
  browser[Browser] -->|HTTP 4100| app[Contentoid container]
  app --> db[(Postgres)]
  app -->|/var/run/docker.sock| daemon[Host Docker / Podman]
  daemon --> dl1[download container]
  daemon --> dl2[post-processor container]
  dl1 -->|bind mounts| disk[/Host directories/]
  app -->|same paths| disk
```

Contentoid assumes one node: at boot and at shutdown it removes every container it labelled
`contentoid`, and at boot it requeues interrupted downloads. Run one instance per daemon.

## 1. Images

CI publishes the app image as `ghcr.io/paradox460/contentoid`, for linux/amd64 and linux/arm64:
`latest` and the version tags (`0.0.1`, `0.0`) from releases, `edge` from `main`. To build one
yourself instead:

```sh
mise run release                                    # contentoid:<version> and contentoid:latest
mise run release --image ghcr.io/paradox460/contentoid --push
mise run release --platform linux/amd64             # an x86 server, built on an ARM Mac
mise run release --engine podman
```

The version comes from `mix.exs`. By hand: `docker build -t contentoid .`

The image runs `bin/migrate` and then `bin/server`, so migrations apply on every start.

### Downloader and post-processor images

The default yt-dlp and aria2c downloaders use images built from this repository and published by
CI, `ghcr.io/paradox460/contentoid-yt-dlp:latest` and `ghcr.io/paradox460/contentoid-aria2:latest`,
and so does a czkawka post-processor (`ghcr.io/paradox460/contentoid-czkawka:latest`: the official
czkawka CLI binary, checksum pinned, with ffmpeg for video mode). gallery-dl uses its own published
`ghcr.io/mikf/gallery-dl`. Each is pulled on first use; Contentoid pulls only missing images, so
`docker pull` one to update it.

To build them yourself, from a checkout: `docker compose -f compose.dev.yml build yt-dlp aria2 czkawka`
(tagged with the published names, so they replace them). To use another registry, change the image on
the Downloaders or Post-processors page.

## 2. The path rule

Every mount source (the download directory, and every downloader, post-processor and post-processor
assignment mount) is handed to the daemon as a **host** path. Contentoid also creates and checks
these paths itself, from inside its own container. The two only agree when each host directory is
bind-mounted into Contentoid's container **at the same path**:

```sh
-v /srv/media:/srv/media          # right: same path on both sides
-v /srv/media:/data               # wrong: the daemon would look for /data on the host
```

- Use absolute paths in Settings and in mounts. `~` expands to the home directory of Contentoid's
  container, not the host user's.
- If the download directory is on no mount, Settings shows a warning (`Contentoid.HostPaths`).
  Otherwise the output would go into Contentoid's container, and Docker would create an empty,
  root-owned directory at that path on the host.
- A mount mapped to a different path isn't detected. Keep both sides the same.
- Mounts that only download containers use (a downloader's config directory, a post-processor's
  library) must still be visible to Contentoid at the same path: it refuses to start a run whose
  mount source doesn't exist.

## 3. User, socket and security

- **User.** Download containers run as the same uid:gid as Contentoid, so files belong to whoever
  Contentoid runs as. Run it as the host user who should own the downloads (`--user 1000:1000`),
  not the image's default `nobody`.
- **Socket.** Mount the daemon's socket at `/var/run/docker.sock`, where Contentoid looks first, and
  give the container the socket's group: `stat -c %g /var/run/docker.sock` on the host, then
  `--group-add <gid>`.
- **Security.** Access to the socket is root on the host, and downloaders and post-processors run
  any image with any mount. Contentoid has no login: keep it on a trusted network, or behind a
  reverse proxy that handles authentication.

## 4. Configuration

### Environment

| Variable | Required | Meaning |
|---|---|---|
| `DATABASE_URL` | yes | `ecto://USER:PASS@HOST/DATABASE` |
| `SECRET_KEY_BASE` | yes | At least 64 characters: `openssl rand -base64 48` |
| `PHX_HOST` | yes | The host name users reach it at. LiveView's websocket only accepts this origin |
| `PORT` | no | HTTP port in the container, default `4100` |
| `POOL_SIZE` | no | Database connections, default `10` |
| `ECTO_IPV6` | no | `true` to reach the database over IPv6 |
| `FORCE_SSL` | no | Default `true`: plain HTTP redirects to HTTPS (below). `false` serves plain HTTP on `PORT` |
| `DOWNLOAD_DIR` | no | The default download directory until Settings names one. Absolute, mounted at the same path (§2) |
| `DEFAULT_LOCALE` | no | BCP 47 tag (`de`, `pt-BR`) for number and date formats, and text when it's a translated language (`en`, `es`), when a browser's `Accept-Language` names no locale Contentoid has. Default `en` |

### HTTPS

By default, production enforces HTTPS (`FORCE_SSL`, read at runtime by `ContentoidWeb.ForceSSL`):
a plain-HTTP request redirects to `https://PHX_HOST`, except for `localhost` and `127.0.0.1`. Put a
TLS reverse proxy in front that sets `X-Forwarded-Proto` (honoured), and publish Contentoid's port
only on `127.0.0.1`. With Caddy:

```
contentoid.example.lan {
  reverse_proxy 127.0.0.1:4100
}
```

For a LAN-only `.lan` name, add `tls internal` to that block and trust Caddy's root certificate. To
serve plain HTTP with no proxy, set `FORCE_SSL=false`. Contentoid then also builds its own URLs as
`http://PHX_HOST:PORT`. Either way, the browser must reach it at `PHX_HOST`: LiveView's websocket
refuses other origins, so a page opened by IP address or another name loads, but then doesn't work.

### In-app settings

Everything about how downloads run lives in the database and is edited on the **Settings** page.
There are no environment variables for these, except `DOWNLOAD_DIR` as the download directory's
default. Changes apply to the next run.

| Setting | Notes |
|---|---|
| Download directory | Blank uses `DOWNLOAD_DIR`; with neither, relative mount sources fail. Absolute, mounted at the same path (§2). Relative mount sources resolve under it |
| Docker socket | Blank detects `/var/run/docker.sock`. Set it only if you mount the socket elsewhere |
| Downloads at once | The global limit; each downloader also has its own |
| Log lines kept | Per download |
| Stop grace | Seconds a cancelled or interrupted script gets to save resume state |
| Image pull timeout | Minutes |

## 5. Docker with systemd

`/opt/contentoid` holds the repository's `compose.yml` and a `.env` (mode 600) made from its
`.env.example`, downloaded as in the README's Quick start:

```sh
cd /opt/contentoid
curl -fsSLO https://raw.githubusercontent.com/paradox460/contentoid/main/compose.yml
curl -fsSL https://raw.githubusercontent.com/paradox460/contentoid/main/.env.example -o .env
chmod 600 .env
```

Fill in `.env` following its comments: `DOWNLOAD_DIR`, `PUID`/`PGID` (§3), `DOCKER_GID`
(`stat -c %g /var/run/docker.sock`), and for a TLS proxy `PHX_HOST=contentoid.example.lan` and
`FORCE_SSL=true`. Postgres creates the `contentoid` database on its first start (`POSTGRES_DB`).
Other host directories downloaders use (a media library, a config directory) go in the
`contentoid` service's `volumes`, at the same path on both sides (§2), e.g.
`- /srv/media:/srv/media`.

`restart: unless-stopped` already brings the stack back after a reboot once `docker.service` is
enabled. A unit adds ordering, `systemctl start/stop` and logs in the journal.
`/etc/systemd/system/contentoid.service`:

```ini
[Unit]
Description=Contentoid
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target

[Service]
WorkingDirectory=/opt/contentoid
ExecStartPre=/usr/bin/docker compose pull --quiet
ExecStart=/usr/bin/docker compose up --remove-orphans
ExecStop=/usr/bin/docker compose down --timeout 90
Restart=on-failure
TimeoutStopSec=120

[Install]
WantedBy=multi-user.target
```

```sh
sudo systemctl daemon-reload
sudo systemctl enable --now contentoid
journalctl -u contentoid -f
```

Drop `ExecStartPre` to update only by hand (`docker compose pull && systemctl restart contentoid`).

## 6. Podman with systemd (Quadlet)

Contentoid works with Podman's Docker-compatible API. Use **rootful** Podman. Rootless Podman maps
container uids through subuids, so the uid Contentoid gives download containers isn't the host
user's, and downloads end up owned by a subuid.

Enable the API socket, and give it a group, since it's root-only by default:

```sh
sudo groupadd --system podman-api
sudo mkdir -p /etc/systemd/system/podman.socket.d
printf '[Socket]\nSocketGroup=podman-api\nSocketMode=0660\n' | sudo tee /etc/systemd/system/podman.socket.d/group.conf
sudo systemctl daemon-reload && sudo systemctl enable --now podman.socket
getent group podman-api   # its gid goes in GroupAdd below
```

Quadlet files go in `/etc/containers/systemd/`; `systemctl daemon-reload` turns each one into a
service.

`contentoid.network`:

```ini
[Network]
```

`contentoid-db.volume`:

```ini
[Volume]
```

`contentoid-db.container`:

```ini
[Container]
Image=docker.io/library/postgres:18
ContainerName=contentoid-db
Network=contentoid.network
Volume=contentoid-db.volume:/var/lib/postgresql
ShmSize=128m
EnvironmentFile=/etc/contentoid/env

[Service]
Restart=always

[Install]
WantedBy=multi-user.target
```

`contentoid.container`:

```ini
[Unit]
Requires=contentoid-db.service podman.socket
After=contentoid-db.service podman.socket

[Container]
Image=ghcr.io/paradox460/contentoid:latest
ContainerName=contentoid
Network=contentoid.network
PublishPort=127.0.0.1:4100:4100
User=1000
Group=1000
GroupAdd=<gid of podman-api>
EnvironmentFile=/etc/contentoid/env
Environment=PHX_HOST=contentoid.example.lan
Environment=DOWNLOAD_DIR=/srv/contentoid
Volume=/run/podman/podman.sock:/var/run/docker.sock
Volume=/srv/contentoid:/srv/contentoid
Volume=/srv/media:/srv/media
# SELinux would block the socket; see below for the data directories.
SecurityLabelDisable=true
StopTimeout=90

[Service]
Restart=always
TimeoutStopSec=120

[Install]
WantedBy=multi-user.target
```

`/etc/contentoid/env` (mode 600):

```sh
POSTGRES_PASSWORD=…
POSTGRES_DB=contentoid
DATABASE_URL=ecto://postgres:…@contentoid-db/contentoid
SECRET_KEY_BASE=…
```

```sh
sudo systemctl daemon-reload
sudo systemctl start contentoid-db contentoid
journalctl -u contentoid -f
```

Quadlet services are enabled by their `[Install]` section; `systemctl enable` doesn't apply to
them. `AutoUpdate=registry` in `[Container]`, together with `podman-auto-update.timer`, updates the
image automatically.

**SELinux (Fedora, RHEL).** Contentoid's own mounts are unlabelled because of
`SecurityLabelDisable=true`. Download containers get plain bind mounts with no `:z`, so label the
data directories once, or downloads can't write to them:

```sh
sudo semanage fcontext -a -t container_file_t '/srv/media(/.*)?'
sudo restorecon -R /srv/media
```

## 7. Operations

- **Upgrades:** pull the new image and restart. Migrations run at start. A download that was
  running gets requeued and resumes.
- **Backups:** the database holds downloaders, post-processors, schedules, settings and the
  record of what's been downloaded. Run `docker compose exec db pg_dump -U postgres contentoid >
  contentoid.sql` (or `podman exec contentoid-db …`). The files are wherever your mounts put them.
- **Logs:** Contentoid logs to stdout (the journal under systemd). Each download's own log is on
  its page.
- **Shell:** `docker compose exec contentoid /app/bin/contentoid remote` gives an IEx shell inside
  the running node.
