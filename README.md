# Contentoid

Automates content acquisition: hand it a URL and the matching downloader downloads it in a Docker
container, queued, with progress, cancel and retry in the browser.

## Quick start (Docker Compose)

Contentoid runs from published images, next to the host's Docker. With Docker (Engine, Desktop or
OrbStack) and Compose installed:

1. `mkdir contentoid && cd contentoid`
2. `curl -fsSLO https://raw.githubusercontent.com/paradox460/contentoid/main/compose.yml`
3. `curl -fsSL https://raw.githubusercontent.com/paradox460/contentoid/main/.env.example -o .env`
4. Edit `.env`, following its comments.
5. `mkdir -p "<your DOWNLOAD_DIR>"`
6. `docker compose up -d`
7. Open [`localhost:4100`](http://localhost:4100).

- Downloads land under `DOWNLOAD_DIR` (`yt-dlp/`, `gallery-dl/`, `aria2c/`), owned by `PUID:PGID`.
- The tool images are pulled on first use.
- Update with `docker compose pull && docker compose up -d`. Contentoid pulls only missing images,
  so a new tool image comes with `docker pull ghcr.io/paradox460/contentoid-yt-dlp:latest` (likewise
  `-aria2`, `-czkawka`).
- The downloads page says "Docker isn't answering" when the socket or `DOCKER_GID` is wrong.
- For the LAN, set `PUBLISH=0.0.0.0:4100` and `PHX_HOST` to the name browsers use. There's no login
  ([`docs/deployment.md`](docs/deployment.md) §3).

TLS, systemd and Podman: [`docs/deployment.md`](docs/deployment.md).

## Development

1. `mise install` for Elixir, Erlang, Bun and the lint tools (`mise.toml`).
2. Docker (Docker Engine, Docker Desktop or OrbStack; Podman's Docker-compatible API should also do).
3. Postgres on `localhost:5432`, user and password `postgres`: `docker compose -f compose.dev.yml up -d db`.
4. `mix setup`, then `mix phx.server`, and open [`localhost:4100`](http://localhost:4100).

The tool images are pulled from GHCR; `docker compose -f compose.dev.yml build yt-dlp aria2 czkawka`
tests local changes to `docker/`. The gallery-dl downloader uses gallery-dl's own image.

- `mix precommit` before committing: compile with warnings as errors, oxlint, format (Quokka and
  oxfmt), Credo, tests.
- `DESIGN.md` has the visual rules; `AGENTS.md` the code's.
- `mise run fonts` rebuilds the Iosevka webfonts from `iosevka.toml`.
- `mise run release` builds the app image locally.

## Releasing

- Bump `version` in `mix.exs`, then push tag `vX.Y.Z` on that commit
  (`git tag vX.Y.Z <commit> && git push origin vX.Y.Z`). The `Image: contentoid` workflow publishes
  `X.Y.Z`, `X.Y` and `latest`, and refuses a tag that doesn't match `mix.exs`.
- Every push to `main` publishes `edge`.
- A tool image publishes `latest` and its tool's version when its `docker/<name>/` changes on `main`.
- Workflows are generated: edit `.github/*.pkl`, then `mise run workflows`, and commit the YAML. CI
  fails when they're out of step.
- The first publish of each package is private on GHCR. Make each one Public once (package settings →
  Change visibility).

## Downloaders

A downloader (Downloaders page) is a URL pattern, a Docker image and a shell script to run in it. A URL
goes to the highest-priority enabled downloader whose pattern matches it; the download form preselects
that one and you can pick another. Three come with Contentoid:

| Downloader | Priority | Image | Takes |
|---|---|---|---|
| aria2c | 30 | `ghcr.io/paradox460/contentoid-aria2:latest` (built from `docker/aria2`) | direct links to archives, disk images, installers and documents |
| gallery-dl | 20 | `ghcr.io/mikf/gallery-dl:v1.32.19` (gallery-dl's own) | imgur, DeviantArt, ArtStation, pixiv, Flickr, Wikimedia and other gallery sites |
| yt-dlp | 10 | `ghcr.io/paradox460/contentoid-yt-dlp:latest` (built from `docker/yt-dlp`) | everything else |

The script runs as `/bin/sh -c SCRIPT contentoid URL`, so the image needs `/bin/sh`. It gets
`CONTENTOID_URL`, `CONTENTOID_OUTPUT` (where to write files) and `CONTENTOID_DOWNLOAD_ID`, and
reports back on stdout or stderr with one JSON object per line, named by its `"contentoid"` key.
Anything else, including other JSON, goes to the download's log:

```json
{"contentoid": "progress", "percent": 42.3, "text": "1.2MiB/s ETA 0:31"}
{"contentoid": "total", "done": 3, "of": 12, "text": "in this post"}
{"contentoid": "start", "path": "/downloads/post/03.jpg"}
{"contentoid": "file", "path": "/downloads/Video.webm", "url": "https://site/watch?v=1"}
{"contentoid": "error", "message": "Resource not found"}
```

- `progress` is the current file: `percent` is a number or a string like `"42.3%"`, or give `done`
  and `of`; leave both out when unknown.
- `total` is the whole download, when the tool knows it, shown as a second bar: `done` of `of`, or
  a `percent`. A total of 1 or `null` is ignored.
- `start` names the file starting; its name shows on the download's page.
- `file` is a finished file, with the URL of what it is when the tool knows it; without `url` it's
  recorded under the download's URL.
- `error`: the last one explains a failed run.

Extra keys are ignored, and a message missing what it needs goes to the log rather than being
dropped. Tools' templates can JSON-encode a field themselves (yt-dlp `%(filepath)j`, gallery-dl
`{_path!j}`, jq), so a path with quotes in it can't break a line. From plain shell, the starter
script on the downloader form has a small `json` quoting function.

It must exit 0 on success. Each downloader also has:

- an **output mount**: a host directory (absolute, `~/…`, or relative to the download directory)
  bound at a container path; reported files under it are shown with their host paths
- **mounts**: more host paths bound in, read-only by default, such as a tool's config directory.
  They must exist. Paths in a mounted config are container paths, so a cookies file is referenced as
  `/config/…`; `--cookies-from-browser` can't work, there's no browser in the container. The default
  scripts read a config mounted at `/config/yt-dlp`, `/config/gallery-dl` (and aria2c takes its
  options in the script).
- **named volumes**: Docker volumes kept between downloads, such as yt-dlp's cache
- **files**: kept in Contentoid itself (name, directory in the container, contents) and put into
  the container before the script starts, owned by root and read-only: a tool's config, a cookies
  file, a helper script. Unlike mounts, they need nothing on the host. A yt-dlp config is
  `config` in `/config/yt-dlp` (the default scripts set `XDG_CONFIG_HOME=/config`). Missing
  directories are created; a file can't go inside a mount.
- **downloads at once**: its own concurrency limit. All downloaders together are also held to
  Settings' "Downloads at once".

A disabled downloader takes no new downloads; its queued ones wait until it's enabled again. A downloader
with downloads queued or running can't be deleted; its finished downloads keep its name.

A downloader can take **arguments** instead of a URL ("Takes" on its form): one that looks up its
content itself, such as a subscriptions checker. It has no pattern, isn't offered on the download
form, and is started only by a schedule, with the schedule's freeform arguments (or none). The
script then runs as `/bin/sh -c SCRIPT contentoid ARG…`: the arguments split into words as a shell
would (quotes and backslashes, no expansion), so they're `"$@"`; `CONTENTOID_ARGUMENTS` holds them
as written, and there's no `CONTENTOID_URL`. A `file` it reports without a `url` is recorded
without a URL.

## Schedules and deferred downloads

A **schedule** (Schedules page) downloads a URL again on a cron schedule, so a channel, playlist,
profile or gallery picks up what's new; or, pinned to an arguments downloader, runs it with the
schedule's arguments (the form swaps the URL field for an arguments one). Each run is an ordinary
download, tagged with the schedule.

- **When**: five-field cron (`0 3 * * *` is 3:00 daily, `0 9 * * 1-5` 9:00 on weekdays) or
  `@hourly`, `@daily`, `@weekly`, `@monthly`, `@yearly`, in the schedule's time zone (a new one
  defaults to your browser's). The form shows the next three run times. Across daylight saving, a
  time the clocks skip runs when the gap ends, and a time they repeat runs once.
- **Downloader**: pinned, or "whichever matches the URL" at each run. An arguments schedule pins its
  downloader.
- **Random delay**: up to `h:m:s` after each run time (e.g. `0:30:00`), chosen afresh per run, so
  schedules due together don't all start at once. The download waits queued until then. Run now
  doesn't wait.
- **Priority**: 0-9, higher first (downloads queued by hand are 0). Waiting downloads start in
  priority order, both within a downloader and for the global download limit; a running download
  is never stopped for a higher one.
- **Overlap**: a run is skipped while the previous one is still queued (waiting out its delay
  included) or running; the schedules list says so.
- **Post-processing**: each assigned post-processor can get its own arguments, mounts and priority
  (blank keeps the post-processor's), which orders the runs for this schedule.
- **Downtime**: if Contentoid was down at one or more run times, the schedule runs once when it's
  back, then carries on. A disabled schedule doesn't catch up when it's enabled again.
- **Run now** runs it immediately without moving its next run, URL and arguments schedules alike.

Repeat runs skip what's already been fetched: the default yt-dlp and gallery-dl scripts keep a
download archive in their output directory (`.yt-dlp-archive.txt`, `.gallery-dl-archive.sqlite3`),
and aria2c recognizes a finished file. Delete an archive entry (or the file) to fetch something again.
Contentoid leaves skipping to the tools; a downloader for another tool should use that tool's own
archive.

## What's been downloaded

The Downloaded page lists every file actually downloaded, newest first, with the URL of what it
is, and can be searched by URL. For a playlist or channel that's each video's own page (yt-dlp's
canonical `watch?v=` URL, even from a `youtu.be` link); for gallery-dl the file's own URL; for a
script that reports a `file` without a `url`, the download's URL. A file is recorded as soon as it
finishes, so one finished before a run failed or was cancelled still counts. Items a tool skipped
(its archive already had them) aren't recorded again.

A single download can also be **deferred**: the download form's optional "Start at" (your browser's
time zone) keeps it queued until then. Retrying a deferred download starts it immediately.

Due schedules are checked every minute.

## How downloads run

Each download runs in its own container, started through the Docker Engine API on the daemon's
socket; a missing image is pulled first. Cancelling a download stops and removes its container,
which stops everything its script started. When Contentoid stops it removes its containers, and at
boot it removes any a crash left behind; downloads interrupted either way are queued again, and the
default scripts resume from their partial files. Contentoid runs on one node.

Containers run as the user running Contentoid, so the files are theirs.

## Settings

The Settings page holds how downloads run. Saved changes apply to downloads that start
afterwards; the download limit applies at once.

| Setting | Default | Meaning |
|---|---|---|
| Download directory | `downloads/` in dev; `DOWNLOAD_DIR` in production (`compose.yml`); with neither, downloads with relative mount sources fail until it's set | Where relative mount sources point, such as the default downloaders' output directories (`yt-dlp/`, `gallery-dl/`, `aria2c/`) |
| Docker socket | `DOCKER_HOST` when it's `unix://…`, else the first of `/var/run/docker.sock`, `~/.docker/run/docker.sock`, `~/.orbstack/run/docker.sock` | The Docker daemon's socket |
| Downloads at once | `4` | Downloads running at once across all downloaders; lowering it stops nothing that's running |
| Log lines kept per download | `200` | The tail of a script's output kept as the download's log |
| Stop grace | `2` seconds | How long a cancelled or interrupted script gets to save its resume state before it's killed |
| Image pull timeout | `30` minutes | How long pulling a missing image may take |

The HTTP port is the `PORT` environment variable (default `4100`).

## License

Contentoid is licensed under the GNU Affero General Public License v3.0 (`LICENSE`). Run a modified
version as a service and you must offer its users the modified source.
