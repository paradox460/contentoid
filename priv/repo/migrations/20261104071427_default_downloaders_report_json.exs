defmodule Contentoid.Repo.Migrations.DefaultDownloadersReportJson do
  @moduledoc """
  The default downloaders report in Contentoid's JSON line protocol (`Contentoid.Downloads.Protocol`):
  one JSON object per line, with tools' own JSON encoding for paths and URLs. yt-dlp and gallery-dl
  also run with unbuffered Python output, so finished files and starts arrive as they're printed
  rather than in batches. Only a script still exactly as the previous migrations left it is
  changed; an edited one is left alone, with a notice, and needs its report lines rewritten by hand.
  """
  use Ecto.Migration

  require Logger

  def up do
    replace("yt-dlp", yt_dlp_lines(), yt_dlp_json())
    replace("gallery-dl", gallery_dl_lines(), gallery_dl_json())
    replace("aria2c", aria2c_lines(), aria2c_json())
  end

  def down do
    replace("yt-dlp", yt_dlp_json(), yt_dlp_lines())
    replace("gallery-dl", gallery_dl_json(), gallery_dl_lines())
    replace("aria2c", aria2c_json(), aria2c_lines())
  end

  defp replace(slug, from, to) do
    %{num_rows: rows} =
      repo().query!(
        "UPDATE downloaders SET script = $1, updated_at = now() WHERE slug = $2 AND script = $3",
        [to, slug, from]
      )

    if rows == 0,
      do: Logger.warning("Left the #{slug} downloader's script alone: it isn't the default one")
  end

  defp yt_dlp_lines do
    ~S"""
    # yt-dlp reports progress and each finished file, with the video's own page URL (one per video of a
    # playlist or channel), through its own print templates, in Contentoid's line protocol. A yt-dlp
    # config mounted at /config/yt-dlp is picked up (XDG_CONFIG_HOME). The archive in the output
    # directory records every video downloaded, so a repeat run (a schedule re-checking a channel)
    # skips them.
    export XDG_CONFIG_HOME=/config
    exec yt-dlp --newline --no-quiet --progress --color never \
      --download-archive "$CONTENTOID_OUTPUT/.yt-dlp-archive.txt" \
      --progress-template 'download:[contentoid:progress] %(progress._percent_str)s %(progress._speed_str)s ETA %(progress._eta_str)s' \
      --print 'after_move:[contentoid:item] %(webpage_url)s %(filepath)s' \
      -P "$CONTENTOID_OUTPUT" -- "$CONTENTOID_URL"
    """
  end

  defp yt_dlp_json do
    ~S"""
    # yt-dlp reports progress and each finished file, with the video's own page URL (one per video of a
    # playlist or channel), through its own print templates, in Contentoid's JSON line protocol (`j`
    # fields are JSON-encoded, so any path or URL is safe). Python output is unbuffered, so each line
    # arrives as it's printed. A yt-dlp config mounted at /config/yt-dlp is picked up (XDG_CONFIG_HOME).
    # The archive in the output directory records every video downloaded, so a repeat run (a schedule
    # re-checking a channel) skips them.
    export PYTHONUNBUFFERED=1 XDG_CONFIG_HOME=/config
    exec yt-dlp --newline --no-quiet --progress --color never \
      --download-archive "$CONTENTOID_OUTPUT/.yt-dlp-archive.txt" \
      --progress-template 'download:{"contentoid": "progress", "percent": %(progress._percent_str)j, "text": "%(progress._speed_str)s ETA %(progress._eta_str)s"}' \
      --print 'after_move:{"contentoid": "file", "url": %(webpage_url)j, "path": %(filepath)j}' \
      -P "$CONTENTOID_OUTPUT" -- "$CONTENTOID_URL"
    """
  end

  defp gallery_dl_lines do
    ~S"""
    # gallery-dl reports in Contentoid's line protocol: each file as it starts and its progress
    # (`output.mode` formats, from the first chunk: `downloader.progress=0`), which file of a post of
    # several it is (`--Print prepare:`; gallery-dl can't know a whole gallery's size), and each
    # finished file with the URL it was fetched from (`--Print after:`). A gallery-dl config mounted
    # at /config/gallery-dl is picked up. The archive in the output directory records every file
    # downloaded, so a repeat run skips them.
    export HOME=/tmp XDG_CONFIG_HOME=/config
    exec gallery-dl --no-colors -d "$CONTENTOID_OUTPUT" \
      --download-archive "$CONTENTOID_OUTPUT/.gallery-dl-archive.sqlite3" \
      -o downloader.progress=0 -o output.shorten=false \
      -o 'output.mode={"start": "[contentoid:start] {}\n", "success": "", "skip": "skipped {}\n", "progress": "[contentoid:progress] - {0}B, {1}B/s\n", "progress-total": "[contentoid:progress] {3}% {0}B of {2}B, {1}B/s\n"}' \
      --Print 'prepare:[contentoid:total] {num}/{count} in this post' \
      --Print 'after:[contentoid:item] {_url} {_path}' -- "$CONTENTOID_URL"
    """
  end

  defp gallery_dl_json do
    ~S"""
    # gallery-dl reports in Contentoid's JSON line protocol: each file as it starts, which file of a
    # post of several it is (gallery-dl can't know a whole gallery's size; unknown counts print as
    # null) and each finished file with the URL it was fetched from (`--Print`, with `!j` JSON-encoding
    # paths and URLs), and its progress from the first chunk (`output.mode` formats). Python output is
    # unbuffered, so lines arrive as they're printed. A gallery-dl config mounted at /config/gallery-dl
    # is picked up. The archive in the output directory records every file downloaded, so a repeat run
    # skips them.
    export PYTHONUNBUFFERED=1 HOME=/tmp XDG_CONFIG_HOME=/config
    exec gallery-dl --no-colors -d "$CONTENTOID_OUTPUT" \
      --download-archive "$CONTENTOID_OUTPUT/.gallery-dl-archive.sqlite3" \
      -o downloader.progress=0 -o output.shorten=false -o keywords-default=null \
      -o 'output.mode={"start": "", "success": "", "skip": "skipped {}\n", "progress": "{{\"contentoid\": \"progress\", \"text\": \"{0}B, {1}B/s\"}}\n", "progress-total": "{{\"contentoid\": \"progress\", \"percent\": {3}, \"text\": \"{0}B of {2}B, {1}B/s\"}}\n"}' \
      --Print 'prepare-after:{{"contentoid": "total", "done": {num!j}, "of": {count!j}, "text": "in this post"}}' \
      --Print 'prepare-after:{{"contentoid": "start", "path": {_path!j}}}' \
      --Print 'after:{{"contentoid": "file", "url": {_url!j}, "path": {_path!j}}}' -- "$CONTENTOID_URL"
    """
  end

  defp aria2c_lines do
    ~S"""
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
    """
  end

  defp aria2c_json do
    ~S"""
    # aria2c runs as an RPC server on this container's loopback, which nothing outside the container can
    # reach. The script adds the URL, polls the download's status every second and reports it in
    # Contentoid's JSON line protocol (built with jq, so paths and messages are escaped), then shuts
    # aria2c down. On SIGTERM (a cancel or a shutdown) aria2c is stopped first, so it saves its control
    # file and the next attempt resumes. --continue also picks up a file that has no control file, so a
    # file already finished is reported, not fetched again.
    secret=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')

    # rpc METHOD PARAMS: calls aria2c's JSON-RPC; PARAMS is a JSON array, without the secret.
    rpc() {
      curl -fsS --max-time 10 http://127.0.0.1:6800/jsonrpc \
        -d "$(jq -cn --arg method "$1" --argjson params "$2" --arg token "token:$secret" \
          '{jsonrpc: "2.0", id: 1, method: $method, params: ([$token] + $params)}')"
    }

    # error MESSAGE: reports what went wrong.
    error() { jq -cn --arg message "$1" '{contentoid: "error", message: $message}'; }

    aria2c --enable-rpc --rpc-listen-port=6800 --rpc-secret="$secret" --dir="$CONTENTOID_OUTPUT" \
      --summary-interval=0 --show-console-readout=false --console-log-level=warn --enable-color=false --download-result=hide \
      --follow-torrent=false --follow-metalink=false --continue=true &
    aria=$!
    trap 'kill -TERM "$aria" 2>/dev/null; wait "$aria"; exit 143' TERM INT

    tries=0
    until rpc aria2.getVersion '[]' >/dev/null 2>&1; do
      tries=$((tries + 1))
      [ "$tries" -lt 50 ] || { error "aria2c's RPC server didn't start"; exit 1; }
      sleep 0.2
    done

    added=$(rpc aria2.addUri "$(jq -cn --arg url "$CONTENTOID_URL" '[[$url]]')")
    gid=$(printf '%s' "$added" | jq -r '.result // empty')
    [ -n "$gid" ] || { printf '%s' "$added" | jq -c '{contentoid: "error", message: .error.message}'; exit 1; }

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
      | {
          contentoid: "progress",
          percent: (if $total > 0 then $done * 1000 / $total | floor / 10 else null end),
          text: ([if $speed > 0 then "\($speed | human)/s" else empty end,
                  if $speed > 0 and $total > 0 then "ETA \(($total - $done) / $speed | ceil | duration)" else empty end]
                 | join(" "))
        }'

    while :; do
      status=$(rpc aria2.tellStatus "$(jq -cn --arg gid "$gid" '[$gid]')") || { error "lost aria2c's RPC server"; exit 1; }

      case $(printf '%s' "$status" | jq -r '.result.status') in
        active | waiting | paused)
          printf '%s' "$status" | jq -c "$progress"
          ;;
        complete)
          printf '%s' "$status" | jq -c '.result.files[].path | {contentoid: "file", path: .}'
          break
          ;;
        *)
          printf '%s' "$status" | jq -c '.result | {contentoid: "error", message: "\(.errorMessage // "download \(.status)") (aria2 error \(.errorCode // "?"))"}'
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
    """
  end
end
