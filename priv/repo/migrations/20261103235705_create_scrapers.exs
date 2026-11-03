defmodule Contentoid.Repo.Migrations.CreateScrapers do
  use Ecto.Migration

  def up do
    create table(:scrapers, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :slug, :string, null: false
      add :url_pattern, :text, null: false
      add :priority, :integer, null: false, default: 0
      add :enabled, :boolean, null: false, default: true
      add :concurrency, :integer, null: false, default: 2
      add :image, :string, null: false
      add :script, :text, null: false
      add :output, :map, null: false
      add :mounts, {:array, :map}, null: false, default: []
      add :volumes, {:array, :map}, null: false, default: []

      timestamps(type: :utc_datetime)
    end

    create unique_index(:scrapers, [:slug])
    create unique_index(:scrapers, [:name])

    flush()

    # The default scrapers, as data: literal here so later code changes can't alter what this
    # migration inserted. Each script was run against its image before being written down.
    now = DateTime.utc_now(:second)

    rows =
      for scraper <- defaults() do
        id = Ecto.UUID.dump!(Ecto.UUID.generate(version: 7, precision: :monotonic))

        Map.merge(scraper, %{
          id: id,
          enabled: true,
          concurrency: 2,
          inserted_at: now,
          updated_at: now
        })
      end

    repo().insert_all("scrapers", rows)
  end

  def down, do: drop(table(:scrapers))

  defp defaults do
    [
      %{
        name: "aria2c",
        slug: "aria2c",
        # Direct links to archives, disk images, installers and documents.
        url_pattern:
          "(?i)^(https?|ftp)://[^?#]+\\.(7z|apk|appimage|bin|bz2|cbr|cbz|deb|dmg|epub|exe|gz|img|iso|msi|pdf|pkg|rar|rpm|tar|tgz|xz|zip|zst)([?#].*)?$",
        priority: 30,
        image: "contentoid-aria2:latest",
        script: ~S"""
        # aria2c runs as an RPC server on this container's loopback, which nothing outside the container can
        # reach. The script adds the URL, polls the download's status every second and prints it in
        # Contentoid's line protocol, then shuts aria2c down. On SIGTERM (a cancel or a shutdown) aria2c is
        # stopped first, so it saves its control file and the next attempt resumes. --continue also picks
        # up a file that has no control file, so a file already finished is reported, not fetched again.
        secret=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')

        # rpc METHOD PARAMS: calls aria2c's JSON-RPC; PARAMS is a JSON array, without the secret.
        rpc() {
          curl -fsS --max-time 10 http://127.0.0.1:6800/jsonrpc \
            -d "$(jq -cn --arg method "$1" --argjson params "$2" --arg token "token:$secret" \
              '{jsonrpc: "2.0", id: 1, method: $method, params: ([$token] + $params)}')"
        }

        aria2c --enable-rpc --rpc-listen-port=6800 --rpc-secret="$secret" --dir="$CONTENTOID_OUTPUT" \
          --summary-interval=0 --show-console-readout=false --console-log-level=warn --enable-color=false --download-result=hide \
          --follow-torrent=false --follow-metalink=false --continue=true &
        aria=$!
        trap 'kill -TERM "$aria" 2>/dev/null; wait "$aria"; exit 143' TERM INT

        tries=0
        until rpc aria2.getVersion '[]' >/dev/null 2>&1; do
          tries=$((tries + 1))
          [ "$tries" -lt 50 ] || { echo "[contentoid:error] aria2c's RPC server didn't start"; exit 1; }
          sleep 0.2
        done

        added=$(rpc aria2.addUri "$(jq -cn --arg url "$CONTENTOID_URL" '[[$url]]')")
        gid=$(printf '%s' "$added" | jq -r '.result // empty')
        [ -n "$gid" ] || { printf '%s' "$added" | jq -r '"[contentoid:error] \(.error.message)"'; exit 1; }

        progress='
          def human: . as $b
            | if $b < 1024 then "\($b) B"
              else ([1, 2, 3, 4] | map(select(pow(1024; .) <= $b)) | last) as $e
                | "\($b / pow(1024; $e) * 10 | round / 10) \(["B", "KiB", "MiB", "GiB", "TiB"][$e])"
              end;
          def duration: . as $s
            | "\($s / 60 | floor):\($s % 60 | tostring | if length < 2 then "0" + . else . end)";
          .result
          | (.totalLength | tonumber) as $total
          | (.completedLength | tonumber) as $done
          | (.downloadSpeed | tonumber) as $speed
          | "[contentoid:progress] "
            + (if $total > 0 then "\($done * 1000 / $total | floor / 10)%" else "-" end)
            + (if $speed > 0 then " \($speed | human)/s" else "" end)
            + (if $speed > 0 and $total > 0 then " ETA \(($total - $done) / $speed | ceil | duration)" else "" end)'

        while :; do
          status=$(rpc aria2.tellStatus "$(jq -cn --arg gid "$gid" '[$gid]')") || { echo "[contentoid:error] lost aria2c's RPC server"; exit 1; }

          case $(printf '%s' "$status" | jq -r '.result.status') in
            active | waiting | paused)
              printf '%s' "$status" | jq -r "$progress"
              ;;
            complete)
              printf '%s' "$status" | jq -r '.result.files[].path | "[contentoid:file] " + .'
              break
              ;;
            *)
              printf '%s' "$status" | jq -r '.result | "[contentoid:error] \(.errorMessage // "download \(.status)") (aria2 error \(.errorCode // "?"))"'
              code=$(printf '%s' "$status" | jq -r '.result.errorCode // "1" | tonumber')
              rpc aria2.shutdown '[]' >/dev/null 2>&1
              wait "$aria"
              exit "$code"
              ;;
          esac

          sleep 1
        done

        rpc aria2.shutdown '[]' >/dev/null 2>&1
        wait "$aria"
        """,
        output: %{source: "aria2c", target: "/downloads"},
        mounts: [],
        volumes: []
      },
      %{
        name: "gallery-dl",
        slug: "gallery-dl",
        # Sites where gallery-dl is the better tool; everything else falls through to yt-dlp.
        url_pattern:
          "(?i)^https?://([^/]+\\.)?(artstation\\.com|bsky\\.app|danbooru\\.donmai\\.us|deviantart\\.com|e621\\.net|flickr\\.com|gelbooru\\.com|imgur\\.com|kemono\\.(su|cr)|pinterest\\.com|pixiv\\.net|tumblr\\.com|wikimedia\\.org)/",
        priority: 20,
        image: "ghcr.io/mikf/gallery-dl:v1.32.19",
        script: ~S"""
        # gallery-dl prints each finished file in Contentoid's line protocol (`--Print after:`); it reports
        # no progress within a file. A gallery-dl config mounted at /config/gallery-dl is picked up.
        export HOME=/tmp XDG_CONFIG_HOME=/config
        exec gallery-dl --no-colors -d "$CONTENTOID_OUTPUT" --Print 'after:[contentoid:file] {_path}' -- "$CONTENTOID_URL"
        """,
        output: %{source: "gallery-dl", target: "/downloads"},
        mounts: [],
        volumes: []
      },
      %{
        name: "yt-dlp",
        slug: "yt-dlp",
        # Everything: yt-dlp is the catch-all, at the lowest priority.
        url_pattern: "(?i)^https?://",
        priority: 10,
        image: "contentoid-yt-dlp:latest",
        script: ~S"""
        # yt-dlp reports progress and each finished file through its own print templates, in Contentoid's
        # line protocol. A yt-dlp config mounted at /config/yt-dlp is picked up (XDG_CONFIG_HOME).
        export XDG_CONFIG_HOME=/config
        exec yt-dlp --newline --no-quiet --progress --color never \
          --progress-template 'download:[contentoid:progress] %(progress._percent_str)s %(progress._speed_str)s ETA %(progress._eta_str)s' \
          --print 'after_move:[contentoid:file] %(filepath)s' \
          -P "$CONTENTOID_OUTPUT" -- "$CONTENTOID_URL"
        """,
        output: %{source: "yt-dlp", target: "/downloads"},
        mounts: [],
        # yt-dlp's cache (signature functions, challenge solutions) survives between downloads.
        volumes: [%{name: "contentoid-yt-dlp-cache", target: "/cache", read_only: false}]
      }
    ]
  end
end
