-- Contentoid's database as of 0.0.1: every migration up to 20261105192052 squashed into one
-- schema, plus the default downloaders (yt-dlp, gallery-dl, aria2c) those migrations inserted.
-- The 20261105192052_structure migration runs it on a new database; one that ran the original
-- migrations has that version recorded already. Later changes go in new migrations, never here.
--
-- Generated with pg_dump --schema-only (tables, types, indexes, constraints, Oban's version
-- comment) and --data-only --column-inserts for downloaders, then stripped of pg_dump's session
-- settings and psql meta-commands, and of schema_migrations, which Ecto creates itself.

CREATE TYPE public.oban_job_state AS ENUM (
    'available',
    'suspended',
    'scheduled',
    'executing',
    'retryable',
    'completed',
    'discarded',
    'cancelled'
);

CREATE TABLE public.download_items (
    id uuid NOT NULL,
    url text,
    path text NOT NULL,
    download_id uuid NOT NULL,
    downloader_name character varying(255),
    inserted_at timestamp(0) without time zone NOT NULL
);

CREATE TABLE public.downloaders (
    id uuid NOT NULL,
    name character varying(255) NOT NULL,
    slug character varying(255) NOT NULL,
    url_pattern text,
    priority integer DEFAULT 0 NOT NULL,
    enabled boolean DEFAULT true NOT NULL,
    concurrency integer DEFAULT 2 NOT NULL,
    image character varying(255) NOT NULL,
    script text NOT NULL,
    output jsonb NOT NULL,
    mounts jsonb[] DEFAULT ARRAY[]::jsonb[] NOT NULL,
    volumes jsonb[] DEFAULT ARRAY[]::jsonb[] NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    files jsonb[] DEFAULT ARRAY[]::jsonb[] NOT NULL,
    input character varying(255) DEFAULT 'url'::character varying NOT NULL
);

CREATE TABLE public.downloads (
    id uuid NOT NULL,
    url text,
    status character varying(255) NOT NULL,
    progress double precision,
    progress_text character varying(255),
    files text[] DEFAULT ARRAY[]::text[] NOT NULL,
    error jsonb,
    log text,
    exit_status integer,
    oban_job_id bigint,
    started_at timestamp(0) without time zone,
    finished_at timestamp(0) without time zone,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    downloader_id uuid,
    downloader_name character varying(255),
    schedule_id uuid,
    start_at timestamp(0) without time zone,
    arguments text,
    phase character varying(255) DEFAULT 'download'::character varying NOT NULL,
    output_dir text,
    total_progress double precision,
    total_text character varying(255),
    current_file text,
    priority integer DEFAULT 0 NOT NULL,
    "position" integer,
    CONSTRAINT priority_range CHECK (((priority >= 0) AND (priority <= 9)))
);

CREATE TABLE public.oban_jobs (
    id bigint NOT NULL,
    state public.oban_job_state DEFAULT 'available'::public.oban_job_state NOT NULL,
    queue text DEFAULT 'default'::text NOT NULL,
    worker text NOT NULL,
    args jsonb DEFAULT '{}'::jsonb NOT NULL,
    errors jsonb[] DEFAULT ARRAY[]::jsonb[] NOT NULL,
    attempt integer DEFAULT 0 NOT NULL,
    max_attempts integer DEFAULT 20 NOT NULL,
    inserted_at timestamp without time zone DEFAULT timezone('UTC'::text, now()) NOT NULL,
    scheduled_at timestamp without time zone DEFAULT timezone('UTC'::text, now()) NOT NULL,
    attempted_at timestamp without time zone,
    completed_at timestamp without time zone,
    attempted_by text[],
    discarded_at timestamp without time zone,
    priority integer DEFAULT 0 NOT NULL,
    tags text[] DEFAULT ARRAY[]::text[],
    meta jsonb DEFAULT '{}'::jsonb,
    cancelled_at timestamp without time zone,
    CONSTRAINT attempt_range CHECK (((attempt >= 0) AND (attempt <= max_attempts))),
    CONSTRAINT positive_max_attempts CHECK ((max_attempts > 0)),
    CONSTRAINT queue_length CHECK (((char_length(queue) > 0) AND (char_length(queue) < 128))),
    CONSTRAINT worker_length CHECK (((char_length(worker) > 0) AND (char_length(worker) < 128)))
);

COMMENT ON TABLE public.oban_jobs IS '14';

CREATE SEQUENCE public.oban_jobs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;

ALTER SEQUENCE public.oban_jobs_id_seq OWNED BY public.oban_jobs.id;

CREATE UNLOGGED TABLE public.oban_peers (
    name text NOT NULL,
    node text NOT NULL,
    started_at timestamp without time zone NOT NULL,
    expires_at timestamp without time zone NOT NULL
);

CREATE TABLE public.post_processor_assignments (
    id uuid NOT NULL,
    post_processor_id uuid NOT NULL,
    downloader_id uuid,
    schedule_id uuid,
    arguments text,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    mounts jsonb[] DEFAULT ARRAY[]::jsonb[] NOT NULL,
    priority integer,
    CONSTRAINT one_owner CHECK ((num_nonnulls(downloader_id, schedule_id) = 1))
);

CREATE TABLE public.post_processors (
    id uuid NOT NULL,
    name character varying(255) NOT NULL,
    priority integer DEFAULT 0 NOT NULL,
    enabled boolean DEFAULT true NOT NULL,
    trigger character varying(255) DEFAULT 'new_files'::character varying NOT NULL,
    image character varying(255) NOT NULL,
    script text NOT NULL,
    mounts jsonb[] DEFAULT ARRAY[]::jsonb[] NOT NULL,
    volumes jsonb[] DEFAULT ARRAY[]::jsonb[] NOT NULL,
    files jsonb[] DEFAULT ARRAY[]::jsonb[] NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);

CREATE TABLE public.schedules (
    id uuid NOT NULL,
    name character varying(255) NOT NULL,
    url text,
    downloader_id uuid,
    cron character varying(255) NOT NULL,
    timezone character varying(255) NOT NULL,
    enabled boolean DEFAULT true NOT NULL,
    next_run_at timestamp(0) without time zone,
    last_run_at timestamp(0) without time zone,
    last_error jsonb,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    arguments text,
    priority integer DEFAULT 0 NOT NULL,
    jitter_seconds integer DEFAULT 0 NOT NULL,
    CONSTRAINT jitter_not_negative CHECK ((jitter_seconds >= 0)),
    CONSTRAINT priority_range CHECK (((priority >= 0) AND (priority <= 9)))
);

CREATE TABLE public.settings (
    id uuid NOT NULL,
    download_dir text,
    docker_socket text,
    max_concurrent_downloads integer DEFAULT 4 NOT NULL,
    log_lines integer DEFAULT 200 NOT NULL,
    stop_grace_seconds integer DEFAULT 2 NOT NULL,
    pull_timeout_minutes integer DEFAULT 30 NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    queue_paused boolean DEFAULT false NOT NULL
);

ALTER TABLE ONLY public.oban_jobs ALTER COLUMN id SET DEFAULT nextval('public.oban_jobs_id_seq'::regclass);

ALTER TABLE ONLY public.download_items
    ADD CONSTRAINT download_items_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.downloaders
    ADD CONSTRAINT downloaders_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.downloads
    ADD CONSTRAINT downloads_pkey PRIMARY KEY (id);

ALTER TABLE public.oban_jobs
    ADD CONSTRAINT non_negative_priority CHECK ((priority >= 0)) NOT VALID;

ALTER TABLE ONLY public.oban_jobs
    ADD CONSTRAINT oban_jobs_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.oban_peers
    ADD CONSTRAINT oban_peers_pkey PRIMARY KEY (name);

ALTER TABLE ONLY public.post_processor_assignments
    ADD CONSTRAINT post_processor_assignments_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.post_processors
    ADD CONSTRAINT post_processors_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.schedules
    ADD CONSTRAINT schedules_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.settings
    ADD CONSTRAINT settings_pkey PRIMARY KEY (id);

CREATE INDEX download_items_download_id_index ON public.download_items USING btree (download_id);

CREATE INDEX download_items_inserted_at_id_index ON public.download_items USING btree (inserted_at, id);

CREATE INDEX download_items_url_index ON public.download_items USING btree (url);

CREATE UNIQUE INDEX downloaders_name_index ON public.downloaders USING btree (name);

CREATE UNIQUE INDEX downloaders_slug_index ON public.downloaders USING btree (slug);

CREATE INDEX downloads_downloader_id_index ON public.downloads USING btree (downloader_id);

CREATE INDEX downloads_inserted_at_id_index ON public.downloads USING btree (inserted_at, id);

CREATE INDEX downloads_schedule_id_index ON public.downloads USING btree (schedule_id);

CREATE INDEX downloads_status_index ON public.downloads USING btree (status);

CREATE INDEX oban_jobs_args_index ON public.oban_jobs USING gin (args);

CREATE INDEX oban_jobs_meta_index ON public.oban_jobs USING gin (meta);

CREATE INDEX oban_jobs_state_cancelled_at_index ON public.oban_jobs USING btree (state, cancelled_at);

CREATE INDEX oban_jobs_state_discarded_at_index ON public.oban_jobs USING btree (state, discarded_at);

CREATE INDEX oban_jobs_state_queue_priority_scheduled_at_id_index ON public.oban_jobs USING btree (state, queue, priority, scheduled_at, id);

CREATE INDEX post_processor_assignments_downloader_id_index ON public.post_processor_assignments USING btree (downloader_id);

CREATE INDEX post_processor_assignments_post_processor_id_index ON public.post_processor_assignments USING btree (post_processor_id);

CREATE INDEX post_processor_assignments_schedule_id_index ON public.post_processor_assignments USING btree (schedule_id);

CREATE UNIQUE INDEX post_processors_name_index ON public.post_processors USING btree (name);

CREATE UNIQUE INDEX schedules_name_index ON public.schedules USING btree (name);

CREATE INDEX schedules_next_run_at_index ON public.schedules USING btree (next_run_at) WHERE enabled;

CREATE UNIQUE INDEX settings_singleton_index ON public.settings USING btree ((true));

ALTER TABLE ONLY public.download_items
    ADD CONSTRAINT download_items_download_id_fkey FOREIGN KEY (download_id) REFERENCES public.downloads(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.downloads
    ADD CONSTRAINT downloads_downloader_id_fkey FOREIGN KEY (downloader_id) REFERENCES public.downloaders(id) ON DELETE SET NULL;

ALTER TABLE ONLY public.downloads
    ADD CONSTRAINT downloads_schedule_id_fkey FOREIGN KEY (schedule_id) REFERENCES public.schedules(id) ON DELETE SET NULL;

ALTER TABLE ONLY public.post_processor_assignments
    ADD CONSTRAINT post_processor_assignments_downloader_id_fkey FOREIGN KEY (downloader_id) REFERENCES public.downloaders(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.post_processor_assignments
    ADD CONSTRAINT post_processor_assignments_post_processor_id_fkey FOREIGN KEY (post_processor_id) REFERENCES public.post_processors(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.post_processor_assignments
    ADD CONSTRAINT post_processor_assignments_schedule_id_fkey FOREIGN KEY (schedule_id) REFERENCES public.schedules(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.schedules
    ADD CONSTRAINT schedules_downloader_id_fkey FOREIGN KEY (downloader_id) REFERENCES public.downloaders(id) ON DELETE SET NULL;

INSERT INTO public.downloaders (id, name, slug, url_pattern, priority, enabled, concurrency, image, script, output, mounts, volumes, inserted_at, updated_at, files, input) VALUES ('01a1af3e-344a-7ce7-bbbb-c5fb28919ba4', 'gallery-dl', 'gallery-dl', '(?i)^https?://([^/]+\.)?(artstation\.com|bsky\.app|danbooru\.donmai\.us|deviantart\.com|e621\.net|flickr\.com|gelbooru\.com|imgur\.com|kemono\.(su|cr)|pinterest\.com|pixiv\.net|tumblr\.com|wikimedia\.org)/', 20, true, 2, 'ghcr.io/mikf/gallery-dl:v1.32.19', '# gallery-dl reports in Contentoid''s JSON line protocol: each file as it starts, which file of a
# post of several it is (gallery-dl can''t know a whole gallery''s size; unknown counts print as
# null) and each finished file with the URL it was fetched from (`--Print`, with `!j` JSON-encoding
# paths and URLs), and its progress from the first chunk (`output.mode` formats). Python output is
# unbuffered, so lines arrive as they''re printed. A gallery-dl config mounted at /config/gallery-dl
# is picked up. The archive in the output directory records every file downloaded, so a repeat run
# skips them.
export PYTHONUNBUFFERED=1 HOME=/tmp XDG_CONFIG_HOME=/config
exec gallery-dl --no-colors -d "$CONTENTOID_OUTPUT" \
  --download-archive "$CONTENTOID_OUTPUT/.gallery-dl-archive.sqlite3" \
  -o downloader.progress=0 -o output.shorten=false -o keywords-default=null \
  -o ''output.mode={"start": "", "success": "", "skip": "skipped {}\n", "progress": "{{\"contentoid\": \"progress\", \"text\": \"{0}B, {1}B/s\"}}\n", "progress-total": "{{\"contentoid\": \"progress\", \"percent\": {3}, \"text\": \"{0}B of {2}B, {1}B/s\"}}\n"}'' \
  --Print ''prepare-after:{{"contentoid": "total", "done": {num!j}, "of": {count!j}, "text": "in this post"}}'' \
  --Print ''prepare-after:{{"contentoid": "start", "path": {_path!j}}}'' \
  --Print ''after:{{"contentoid": "file", "url": {_url!j}, "path": {_path!j}}}'' -- "$CONTENTOID_URL"
', '{"source": "gallery-dl", "target": "/downloads"}', '{}', '{}', '2026-11-06 05:04:11', '2026-11-06 05:04:12', '{}', 'url');
INSERT INTO public.downloaders (id, name, slug, url_pattern, priority, enabled, concurrency, image, script, output, mounts, volumes, inserted_at, updated_at, files, input) VALUES ('01a1af3e-344a-7cb0-8bbd-8206ca325da3', 'aria2c', 'aria2c', '(?i)^(https?|ftp)://[^?#]+\.(7z|apk|appimage|bin|bz2|cbr|cbz|deb|dmg|epub|exe|gz|img|iso|msi|pdf|pkg|rar|rpm|tar|tgz|xz|zip|zst)([?#].*)?$', 30, true, 2, 'ghcr.io/paradox460/contentoid-aria2:latest', '# aria2c runs as an RPC server on this container''s loopback, which nothing outside the container can
# reach. The script adds the URL, polls the download''s status every second and reports it in
# Contentoid''s JSON line protocol (built with jq, so paths and messages are escaped), then shuts
# aria2c down. On SIGTERM (a cancel or a shutdown) aria2c is stopped first, so it saves its control
# file and the next attempt resumes. --continue also picks up a file that has no control file, so a
# file already finished is reported, not fetched again.
secret=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d '' \n'')

# rpc METHOD PARAMS: calls aria2c''s JSON-RPC; PARAMS is a JSON array, without the secret.
rpc() {
  curl -fsS --max-time 10 http://127.0.0.1:6800/jsonrpc \
    -d "$(jq -cn --arg method "$1" --argjson params "$2" --arg token "token:$secret" \
      ''{jsonrpc: "2.0", id: 1, method: $method, params: ([$token] + $params)}'')"
}

# error MESSAGE: reports what went wrong.
error() { jq -cn --arg message "$1" ''{contentoid: "error", message: $message}''; }

aria2c --enable-rpc --rpc-listen-port=6800 --rpc-secret="$secret" --dir="$CONTENTOID_OUTPUT" \
  --summary-interval=0 --show-console-readout=false --console-log-level=warn --enable-color=false --download-result=hide \
  --follow-torrent=false --follow-metalink=false --continue=true &
aria=$!
trap ''kill -TERM "$aria" 2>/dev/null; wait "$aria"; exit 143'' TERM INT

tries=0
until rpc aria2.getVersion ''[]'' >/dev/null 2>&1; do
  tries=$((tries + 1))
  [ "$tries" -lt 50 ] || { error "aria2c''s RPC server didn''t start"; exit 1; }
  sleep 0.2
done

added=$(rpc aria2.addUri "$(jq -cn --arg url "$CONTENTOID_URL" ''[[$url]]'')")
gid=$(printf ''%s'' "$added" | jq -r ''.result // empty'')
[ -n "$gid" ] || { printf ''%s'' "$added" | jq -c ''{contentoid: "error", message: .error.message}''; exit 1; }

progress=''
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
    }''

while :; do
  status=$(rpc aria2.tellStatus "$(jq -cn --arg gid "$gid" ''[$gid]'')") || { error "lost aria2c''s RPC server"; exit 1; }

  case $(printf ''%s'' "$status" | jq -r ''.result.status'') in
    active | waiting | paused)
      printf ''%s'' "$status" | jq -c "$progress"
      ;;
    complete)
      printf ''%s'' "$status" | jq -c ''.result.files[].path | {contentoid: "file", path: .}''
      break
      ;;
    *)
      printf ''%s'' "$status" | jq -c ''.result | {contentoid: "error", message: "\(.errorMessage // "download \(.status)") (aria2 error \(.errorCode // "?"))"}''
      code=$(printf ''%s'' "$status" | jq -r ''.result.errorCode // "1" | tonumber'')
      rpc aria2.shutdown ''[]'' >/dev/null 2>&1
      wait "$aria"
      exit "$code"
      ;;
  esac

  sleep 1
done

rpc aria2.shutdown ''[]'' >/dev/null 2>&1
wait "$aria"
', '{"source": "aria2c", "target": "/downloads"}', '{}', '{}', '2026-11-06 05:04:11', '2026-11-06 05:04:12', '{}', 'url');
INSERT INTO public.downloaders (id, name, slug, url_pattern, priority, enabled, concurrency, image, script, output, mounts, volumes, inserted_at, updated_at, files, input) VALUES ('01a1af3e-344a-7ced-a2dd-8fb90410bbdc', 'yt-dlp', 'yt-dlp', '(?i)^https?://', 10, true, 2, 'ghcr.io/paradox460/contentoid-yt-dlp:latest', '# yt-dlp reports progress and each finished file, with the video''s own page URL (one per video of a
# playlist or channel), through its own print templates, in Contentoid''s JSON line protocol (`j`
# fields are JSON-encoded, so any path or URL is safe). Python output is unbuffered, so each line
# arrives as it''s printed. A yt-dlp config mounted at /config/yt-dlp is picked up (XDG_CONFIG_HOME).
# The archive in the output directory records every video downloaded, so a repeat run (a schedule
# re-checking a channel) skips them.
export PYTHONUNBUFFERED=1 XDG_CONFIG_HOME=/config
exec yt-dlp --newline --no-quiet --progress --color never \
  --download-archive "$CONTENTOID_OUTPUT/.yt-dlp-archive.txt" \
  --progress-template ''download:{"contentoid": "progress", "percent": %(progress._percent_str)j, "text": "%(progress._speed_str)s ETA %(progress._eta_str)s"}'' \
  --print ''after_move:{"contentoid": "file", "url": %(webpage_url)j, "path": %(filepath)j}'' \
  -P "$CONTENTOID_OUTPUT" -- "$CONTENTOID_URL"
', '{"source": "yt-dlp", "target": "/downloads"}', '{}', '{"{\"name\": \"contentoid-yt-dlp-cache\", \"target\": \"/cache\", \"read_only\": false}"}', '2026-11-06 05:04:11', '2026-11-06 05:04:12', '{}', 'url');


--
-- PostgreSQL database dump complete
--
