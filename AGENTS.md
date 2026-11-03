This is a web application written using the Phoenix web framework.

## Project guidelines

- Use `mix precommit` alias when you are done with all changes and fix any pending issues. It runs
  `compile --warnings-as-errors`, `gettext.extract --check-up-to-date` (in its own
  `_build/gettext`; run `mix gettext.extract --merge` when it fails), oxlint (`assets/js` and the
  extracted colocated hooks), `deps.unlock --unused`, `format` (Quokka, plus oxfmt for HEEx
  `<script>`/`<style>` bodies via `priv/formatter/js_and_css_formatter.ex`), `credo --strict`, then
  `test`
- Use the already included and available `:req` (`Req`) library for HTTP requests, **avoid** `:httpoison`, `:tesla`, and `:httpc`. Req is included by default and is the preferred HTTP client for Phoenix apps

## This codebase, specifically

**Read `DESIGN.md` before touching UI.** It holds the visual rules (Tomorrow palette, no border
radius, flat surfaces, Iosevka, icon stroke width) and the contrast constraints behind the tokens.

### Icons

- Icons come from the **Iconex** Hex dep (`~> 0.1.0`, `mix.exs`), Lucide set only
  (`config :iconex, sets: [:lucide]`). `<.lucide name="…" />` is `Iconex.lucide/1`, imported in
  `html_helpers` (`lib/contentoid_web.ex`) and in `core_components.ex`. There is no local icon module
  or `@icons` list: any name from https://lucide.dev/icons/ works with no registration step.
- The `:iconex` compiler (last in `compilers:`, `mix.exs`) scans compiled modules for literal icon
  names and writes a pruned sprite to `priv/static/images/iconex.svg` (gitignored). An unknown literal
  name fails compilation. `Iconex.lucide/1` also raises `ArgumentError` at render for an unknown name.
- **A name computed at runtime is invisible to the compiler**, e.g.
  `name={if @x, do: "pause", else: "play"}`. List every possible value with
  `hint(:lucide, ~w[…])` (`Iconex.hint/2`) at the top of the function component, or the icon renders
  blank from the pruned sprite.
- Delivery: dev uses `delivery: :inline` (`config/dev.exs`). Other envs use the default `:external`
  sprite file. `{Iconex.sprite_tag()}` sits once in `layouts/root.html.heex`. `:sets` and `:delivery`
  are read when iconex compiles: `mix deps.compile iconex --force` after changing them.
- Sizing: `.iconex` in `assets/css/base.css` makes every icon 1em. It uses `stroke="currentColor"`,
  so size and color it from the parent's `font-size`/`color`. Don't pass Tailwind `class` values; the
  `size` attr exists but the 1em CSS overrides it.
- Stroke width is app-wide, `config :iconex, lucide: [stroke_width: 1]` (`config/config.exs`, read
  when iconex compiles: `mix deps.compile iconex --force` after changing it). Don't pass
  `stroke_width` per icon.
- No Heroicons in this app. Ignore the generic Phoenix `hero-*` icon guidance below.

### CSS

- Semantic tokens live in `assets/css/tokens.css`: `--background --foreground --muted-foreground
  --surface-1..3 --border --border-strong --primary --primary-foreground --ring --destructive
  --destructive-foreground --success --warning --info --panel-gap --touch-target`. They map the
  base16 Tomorrow / Tomorrow Night palette (`--base00`…`--base0F`), which components never use directly. `--primary`
  (blue) works both as a fill under `--primary-foreground` text and as text or a border on a surface.
  `--success`/`--warning`/`--info` are marks only (borders, icons), never text. Open Props is imported
  (`assets/css/app.css`), so `--size-N --font-size-N` are available; `--radius-N` and `--shadow-N`
  are off limits (`DESIGN.md`). Prefer a semantic token when one exists.
- **Open Props' normalize caps `max-inline-size` on text elements**: `p` (`--size-content-3`),
  `li`/`dd`/`figcaption`/`blockquote`/`td` (`--size-content-2`), `h1`-`h6`/`dt`, `small`. A `<li>` row or
  a heading inside a wide panel will silently be ~45ch wide. Fix with `max-inline-size: none`, as
  `core_components.ex` already does (`header/1`, `table/1`, `list/1`, `flash/1`). `div`/`span` get no cap.
- `lower-bound="none"` on a colocated `<style>` makes every element carrying the scope marker a scope
  root, so root rules must be tag-qualified (`div:scope`, `header:scope`), never a bare class. Use it
  only to reach inside a nested component's root (e.g. `<.input>`'s internals, or a `<.link>` root as
  in `Layouts.app/1`).
- Root-attached pseudo-elements need the scope root too: `dialog:scope::backdrop`, never `::backdrop`.
- A colocated `<style>` block must come first in its template, before `<Layouts.app>` or any other tag.
- Content passed into a component's slot gets the caller's scope marker only on its own root *tags*;
  a component call there (e.g. `<.form>`) carries none and falls outside the caller's styles. Wrap such
  slot content in one tag (e.g. `<div class="<thing>-body">` styled
  `div.<thing>-body:scope { display: contents; }`) so the caller's rules reach it.
- Breakpoints are saved custom media (`assets/css/media.css`): `@media (--phone)` (≤ 54rem, so a
  foldable's ~791px inner screen is a phone), `(--tablet)` (≤ 64rem), `(--laptop)` (≤ 75rem),
  `(--touch)` (hover: none), `(--coarse)` (pointer: coarse; size hit areas with
  `var(--touch-target)`). Never write the literals; `assets/build.ts` resolves the names with
  LightningCSS, and an unknown name fails the build. The root is 16px everywhere.

### Schema conventions

- **Every persisted schema starts `use Contentoid.Schema`, never `use Ecto.Schema`.** That macro
  (`lib/contentoid/schema.ex`) sets `@primary_key {:id, Ecto.UUID, autogenerate: [version: 7, precision:
  :monotonic]}` and `@foreign_key_type Ecto.UUID`, so ids are time-ordered **UUID v7**. Do not write the
  two attributes by hand and do not reintroduce `{:id, :binary_id, autogenerate: true}`: that form
  delegates to the adapter and silently yields random v4. `mix phx.gen.*` emits the v4 form because
  `generators: [binary_id: true]` (`config/config.exs`) has no schema-attribute option: replace it in
  generated code. Embedded schemas (`@primary_key false`) keep `use Ecto.Schema`.
- `precision: :monotonic` is required: it lets `id` break ties when ordering by
  `inserted_at` (`[asc: inserted_at, asc: id]`); plain `:millisecond` v7 (random `rand_a`) would
  scramble order within one millisecond. `test/contentoid/schema_test.exs` fails if the precision is
  dropped.
- Any hand-built id (a `Repo.insert_all/3` row, or a test's "unknown id") must come from
  `Contentoid.Schema.generate_id/0`, **never** `Ecto.UUID.generate/0`, whose default is v4.
  `Ecto.UUID` as a *type* (fields, schemaless types, `Ecto.UUID.t()` specs) is fine.
- Every enum-like field is `field :x, Ecto.Enum, values: [...]`. There are no custom `Ecto.Type`
  modules; do not add one for an enum.

### Downloaders and downloads

- A **downloader** (`Contentoid.Downloaders.Downloader`, a database row edited on the Downloaders
  page; called a scraper before the `rename_scrapers_to_downloaders` migration) is an input kind
  (`input`: `:url` or `:arguments`), a URL pattern (URL downloaders only), priority, enabled flag,
  concurrency, Docker image, shell script, output mount, extra mounts, named
  volumes and files. There is no per-tool Elixir code: everything tool-specific lives in the script
  and its files. The three defaults (yt-dlp, gallery-dl, aria2c) are inserted by the
  `create_scrapers` migration as literal data; change a default in a new migration, not the old
  one, once it has run anywhere but dev. Their images: `docker/yt-dlp`, `docker/aria2`, published by
  CI as `ghcr.io/paradox460/contentoid-<name>` (`use_published_tool_images` migration), gallery-dl's
  own `ghcr.io/mikf/gallery-dl`.
- A downloader's **files** (`Downloader.ConfigFile`: name, directory, contents) are stored in the
  row and put into the created container before it starts, as a tar through the Engine API
  (`PUT /containers/{id}/archive`, `Contentoid.Downloads.Docker.Tar`), root-owned and mode 0444, so
  the script (running as the host user) can read but not change them. Nothing is written on the
  host. A file may not sit under a mount or volume target: it would land on the host or the volume.
- Scripts report with a JSON line protocol (`Contentoid.Downloads.Protocol`): one object per line,
  named by its `"contentoid"` key: `progress` (the current file), `total` (`done`/`of`, the whole
  download, shown as a second bar; under 2 or not a number is ignored), `start`, `file` (`path`,
  optional `url`, preferred: the URL of what the file is), `moved`, `removed`, `error`. Everything
  else, including malformed or unknown messages, goes to the log; never drop a line silently.
  Extra keys are ignored, so new fields don't break anything. Scripts must JSON-encode values with
  the tool's own templating (yt-dlp `%(f)j`, gallery-dl `{f!j}`, jq), never by pasting raw paths
  into a string, and Python tools run with `PYTHONUNBUFFERED=1` so lines arrive as printed. Each
  finished file becomes a `Contentoid.Downloads.Item` the moment it's
  reported (`Downloads.record_item/3`, broadcast on `Downloads.subscribe_items/0`): the record of
  what's been downloaded. Contentoid doesn't skip anything itself; skipping is each tool's archive
  (`--download-archive` in the default scripts). Prefer a tool's own templating (`--print`,
  `--progress-template`, gallery-dl's `--Print`, aria2's JSON-RPC) over parsing its human output.
  Reported paths are container paths; the runner maps the output mount back to the host. Run a
  changed script against its real image before committing it.
- `Contentoid.Downloaders.match/1` picks the highest-priority enabled URL downloader whose pattern
  matches; `test/contentoid/downloaders_test.exs` pins which URLs the defaults take.
- An **arguments downloader** finds its content itself. Only a schedule starts it, with the
  schedule's freeform `arguments` (maybe none); the download form lists URL downloaders only. Its
  download has `arguments` and no `url` (`Download.create_changeset/2` checks the pair against the
  downloader); the runner passes `Download.argv/1` (`OptionParser.split/1`: quotes and backslashes,
  no expansion) as `"$@"` plus `CONTENTOID_ARGUMENTS`, and no `CONTENTOID_URL`. Its
  `file` items without a `url` have a nil `url`. Code reading `download.url` or `item.url` must allow
  nil.
- A download (`Contentoid.Downloads.Download`, `belongs_to :downloader`, plus `downloader_name` kept for
  deleted downloaders) runs as one Oban job (`Contentoid.Downloads.Worker`, `max_attempts: 1`; retrying
  is the user's call) in its downloader's queue, `downloader-<id>`, started at runtime with a fixed
  limit of 1 000 (`Contentoid.Downloads.Queues`; a disabled downloader's queue is paused), so it hands
  jobs out at once. The worker then waits in `Contentoid.Downloads.Slots`, the only gate: the
  downloader's concurrency, Settings' `max_concurrent_downloads` and the queue's pause
  (`Downloads.pause_queue/0`, saved in `settings.queue_paused`; running downloads are never
  stopped). Slots serves waiters in line order, `downloads.position` (set only by
  `Contentoid.Downloads`: placed by priority on creation or retry, moved by drag
  `reorder_queue/1` and `start_download_now/1`, cleared when it starts). Downloader changes
  go through `Contentoid.Downloaders`, which keeps the queues and Slots' concurrency in step and
  broadcasts `{:downloaders, :changed}`.
- Each run is its own container (`Contentoid.Downloads.Runner`, `Contentoid.Downloads.Docker`: Engine
  API v1.41 over the daemon's Unix socket with `Req`; no docker CLI), pulling a missing image first.
  Containers outlive whoever started them, so the runner's watchdog removes its container when the
  job's process dies (a cancel), always stopping it first so the script can save its resume state.
  Only `Contentoid.Downloads` writes download state; writes on behalf of a run apply only while the
  download is still `running`, so a cancel is never overwritten. Every change is broadcast as
  `{:download, download}` (`Downloads.subscribe/0`).
- Only a finished download (completed, failed, cancelled) can be deleted (`Downloads.delete_download/1`,
  `delete_finished_downloads/0`), broadcast as `{:downloads_deleted, ids}` and, to item subscribers,
  `{:items_deleted, ids}`. Its row goes (log included) and its items with it (`on_delete: :delete_all`,
  so every item has a download); its files stay on disk.
- Contentoid assumes **one node**: `Contentoid.Downloads.Janitor` (a child before Oban) removes every
  Contentoid container at boot and again at shutdown, and at boot requeues every download still
  queued or running whose job isn't waiting. Don't add a second node without replacing this.
  Oban uses the `Oban.Notifiers.PG` notifier for the same reason (`config/config.exs`): the
  Postgres notifier's `LISTEN` isn't up when `Queues.start_all/0` signals the downloader queues at
  boot, and in the release they never started.
- **Deployment** (`docs/deployment.md`, the user-facing `compose.yml` + `.env.example`; dev uses
  `compose.dev.yml`): the release image (`Dockerfile`, `mise run release` locally) runs next to the
  host's daemon via its socket. CI publishes every image (app and `docker/*`) to GHCR from
  `.github/images.pkl`; workflow YAML is generated (`mise run workflows`, a fish script in
  `.mise/tasks/workflows`), never edited by hand.
  Mount sources are host paths that Contentoid also creates and checks itself, so in a container
  each must be bind-mounted at the same path; `Contentoid.HostPaths.warning/1` (shown on Settings)
  flags a download directory on no mount. Update the doc when env vars, Settings or mounts change.
- Everything that talks to Docker is tested against `Contentoid.FakeDocker`
  (`test/support/fake_docker.ex`), a fake Engine API plugged in through `Req.Test`; tests that cross
  processes call `Req.Test.set_req_test_to_shared/0`. `FakeDocker.start/1` saves a Docker socket in
  Settings, so its tests need the DB sandbox (`Contentoid.DataCase`). The test database holds the default
  downloaders. A LiveView test that changes a downloader must end on a view assertion, so the view's own
  broadcast is handled before the test (and its fake Docker) ends.
- **Settings** (`Contentoid.Settings`, one `settings` row edited on the Settings page; no row means every
  default) hold the download directory, Docker socket, `max_concurrent_downloads`, log lines kept and
  Docker stop grace and pull timeout. There are no env vars for them. They're read from the database at
  each use, never cached, so a save applies to the next run; `update_settings/1` pushes a changed limit
  to `Slots.set_limit/1`. Relative mount sources resolve under `Settings.download_dir/0` (the row, else
  `config :contentoid, Contentoid.Settings, default_download_dir:`, set in dev and test config and from
  `DOWNLOAD_DIR` in production), and
  `Downloaders.host_path/1` returns `{:error, message}` when neither is set.

### Post-processors

- A **post-processor** (`Contentoid.PostProcessors.PostProcessor`, edited on the Post-processors page)
  is a Docker image and script like a downloader, plus priority, enabled and `trigger` (`:new_files`
  or `:always`). It's assigned to downloaders and schedules through `post_processor_assignments`
  (`PostProcessors.Assignment`: one table, exactly one owner, freeform `arguments`, and `mounts`
  bound on top of the post-processor's own), cast with the owner's changeset (`cast_assoc`,
  `_sort`/`_drop` params, nested `mounts_sort`/`mounts_drop`; the owner must be preloaded). One
  post-processor can be assigned to an owner more than once, with different arguments or mounts. A
  download runs its downloader's and schedule's assignments of enabled ones, each `{post-processor,
  arguments, mounts}` once, highest priority first: the assignment's `priority` when set, else the
  post-processor's (`PostProcessors.for_download/1`).
- They run in the same Oban job after the downloader exits 0 (`Runner`): the download moves to phase
  `:post_processing` with `output_dir` recorded, and each gets its arguments as `"$@"` (and
  `CONTENTOID_ARGUMENTS`), the current files in `CONTENTOID_FILES` (one per line), its binds in
  `CONTENTOID_MOUNTS` (host, tab, container path; output first) for scripts taking host paths, the
  output directory at `/contentoid/output` (no mount or volume may be under `/contentoid`). Scripts
  report `moved` (`from`, `to`) and `removed` (`path`) messages besides the usual ones;
  a move rewrites the item's path. The first failure fails the download; a retry of a download in
  phase `:post_processing` keeps files and log and re-runs only post-processing (`Downloads.reset/2`).

### Schedules and time

- A **schedule** (`Contentoid.Schedules.Schedule`) is a URL or, pinned to an arguments downloader,
  arguments; an optional pinned downloader, a cron expression and an IANA time zone. Its changeset
  keeps whichever of `url`/`arguments` the pinned downloader takes and drops the other.
  `Schedules.run_now/1` ("Run now") starts either kind by hand. `Contentoid.Schedules.run_due/1`, called every minute by
  `Contentoid.Schedules.Ticker` (Oban's cron plugin, the static `scheduler` queue), starts a download
  per due schedule through `Downloads.create_download/1`, skips one whose previous download is in
  flight, records `last_error`, and sets `next_run_at` from now (one catch-up run after downtime).
  Changing cron, time zone or enabled recomputes `next_run_at`; nothing else does. A schedule's
  `jitter_seconds` (entered as `jitter`, `h:m:s`) defers each *due* run by a random delay through the
  download's `start_at`; `run_now/1` never waits. Its `priority` (0-9, higher first) is copied to the
  download: a new download goes into line after the last waiting one of the same or higher
  priority, so a higher one starts sooner but nothing running is ever stopped, and a drag can move
  it anywhere. Downloads queued by hand are 0.
- Cron math goes through `Contentoid.Schedules.Cron` only, never `Crontab` directly: it computes in
  local wall-clock time and resolves DST gaps (run at the gap's end) and repeats (run once) itself.
  Oban's own cron parser is private API; don't use it.
- Time zones come from `tz` (`config :elixir, :time_zone_database`). Every LiveView has `@timezone`,
  the browser's zone (`ContentoidWeb.Timezone`, from the `timezone` connect param), for reading and
  filling `datetime-local` values (`parse_local/2`, `to_local/2`); store UTC. Show a timestamp with
  `<.local_time id=… at=… />` (`ContentoidWeb.LocalTime`): the browser formats it with
  `Intl.DateTimeFormat` in its own zone (or `time_zone`) and the page's locale.
- A deferred download has `start_at`; its Oban job gets `scheduled_at`, and it stays `queued` until
  then (`Downloads.deferred?/1`). Retrying clears `start_at`.

### Locale and translation

- Every user-visible string goes through Gettext (`gettext`, `ngettext`; changeset messages
  `dgettext_noop("errors", …)` with values as error opts). Each text run around markup or a code
  literal is its own msgid; never concatenate translated pieces. Plurals bind a formatted
  `%{number}`, never `%{count}`. `priv/gettext/*.pot` and the `en` `.po` files are committed;
  `mix precommit` fails when `mix gettext.extract --merge` would change them. Never call `gettext`
  at compile time (module attributes).
- Numbers, percents and durations shown go through `ContentoidWeb.Format` (`number/1`,
  `percent/1`, `duration/1`, `download_status/1`), CLDR via `localize`, in the request's locale.
- The locale is the browser's `Accept-Language` best match among CLDR "modern" locales, else
  `DEFAULT_LOCALE` (`Localize.Plug.PutLocale` in the router, `ContentoidWeb.Locale` on mount). The
  CLDR data is downloaded by `mix localize.download_locales` (in `mix setup` and the Dockerfile)
  into the gitignored `priv/localize/`.
- Stored messages (`downloads.error`, `schedules.last_error`) are `Contentoid.Message` embeds: a
  msgid plus bindings, or verbatim `text` from a tool, Docker or the OS. Errors reaching the UI from
  `lib/contentoid` are `{:error, %Message{}}`; render with `message_text/1`
  (`ContentoidWeb.Messages`), never interpolation or `inspect`.


### Phoenix v1.8 guidelines

- **Always** begin your LiveView templates with `<Layouts.app flash={@flash} active={:section} ...>` which wraps all inner content. `active` names the navigation item the page belongs to (`:downloads`, …), marked `aria-current="page"` in the left navigation pane. `/` redirects to `/downloads` (`ContentoidWeb.PageController`)
- A new top-level page gets its navigation item in `Layouts.app/1` (`<.nav_item navigate={~p"/…"} active={@active == :section}><.lucide name="…" /> Label</.nav_item>`). All navigation lives in that left pane; never add a top bar or per-page nav strip (`DESIGN.md`)
- The `MyAppWeb.Layouts` module is aliased in the `my_app_web.ex` file, so you can use it without needing to alias it again
- Anytime you run into errors with no `current_scope` assign:
  - You failed to follow the Authenticated Routes guidelines, or you failed to pass `current_scope` to `<Layouts.app>`
  - **Always** fix the `current_scope` error by moving your routes to the proper `live_session` and ensure you pass `current_scope` as needed
- Phoenix v1.8 moved the `<.flash_group>` component to the `Layouts` module. You are **forbidden** from calling `<.flash_group>` outside of the `layouts.ex` module
- **Always** use the `<.lucide>` component for icons (Lucide names via Iconex; see "Icons" above), **never** use `Heroicons` modules or similar
- **Always** use the imported `<.input>` component for form inputs from `core_components.ex` when available. `<.input>` is imported and using it will save steps and prevent errors
- If you override the default input classes (`<.input class="myclass px-2 py-1 rounded-lg">)`) class with your own values, no default classes are inherited, so your
custom classes must fully style the input

### JS and CSS guidelines

- **NEVER use TailwindCSS.** No tailwind utility classes (`px-2`, `w-5`, `h-5`, `flex`, `rounded-lg`, etc.), no `@apply`, no tailwind config or directives, anywhere. If you encounter tailwind classes in existing markup, prefer replacing them with colocated CSS as you touch the code.
- **Prioritize colocated CSS.** Styling **must** live in a colocated `<style>` block inside the component/LiveView via `ContentoidWeb.ColocatedScopedCSS` (component-scoped, the default choice) or `ContentoidWeb.ColocatedCSS` (global utilities only). See `docs/colocated_css_guide.md`.
  - Order of preference: **scoped colocated CSS** first, then **global colocated CSS** only when reuse demands it, then global `app.css` **only if necessary**. Avoid inline `style="..."` attributes unless there's no other way (e.g. dynamic values computed from Elixir).
  - **`ContentoidWeb.ColocatedScopedCSS` wraps rules in `@scope ([phx-css-…]) to ([phx-r])`. A bare class/tag selector EXCLUDES the scope root (the component's outermost element) and matches only descendants.** To style the root element itself (e.g. positioning a `popover`/notice container, overriding UA `[popover]` defaults), you **must** target it with the `:scope` pseudo-class, not its class name. A `.root-class { … }` rule silently no-ops on the root and UA/global styles win.
- **Prioritize colocated JS.** Client-side behavior **must** live in a colocated JS hook (`<script :type={Phoenix.LiveView.ColocatedHook} name=".MyHook">`) defined inside the HEEx template, for both `phx-hook` behavior and general JS state. Reach for an external `assets/js/` hook only when the hook must be shared across many templates.
- Out of the box **only the app.js and app.css bundles are supported**
  - You cannot reference an external vendor'd script `src` or link `href` in the layouts
  - You must import the vendor deps into app.js and app.css to use them


<!-- usage-rules-start -->

<!-- phoenix:elixir-start -->
## Elixir guidelines

- Elixir lists **do not support index based access via the access syntax**

  **Never do this (invalid)**:

      i = 0
      mylist = ["blue", "green"]
      mylist[i]

  Instead, **always** use `Enum.at`, pattern matching, or `List` for index based list access, ie:

      i = 0
      mylist = ["blue", "green"]
      Enum.at(mylist, i)

- Elixir variables are immutable, but can be rebound, so for block expressions like `if`, `case`, `cond`, etc
  you *must* bind the result of the expression to a variable if you want to use it and you CANNOT rebind the result inside the expression, ie:

      # INVALID: we are rebinding inside the `if` and the result never gets assigned
      if connected?(socket) do
        socket = assign(socket, :val, val)
      end

      # VALID: we rebind the result of the `if` to a new variable
      socket =
        if connected?(socket) do
          assign(socket, :val, val)
        end

- **Never** nest multiple modules in the same file as it can cause cyclic dependencies and compilation errors
- **Never** use map access syntax (`changeset[:field]`) on structs as they do not implement the Access behaviour by default. For regular structs, you **must** access the fields directly, such as `my_struct.field` or use higher level APIs that are available on the struct if they exist, `Ecto.Changeset.get_field/2` for changesets
- Elixir's standard library has everything necessary for date and time manipulation. Familiarize yourself with the common `Time`, `Date`, `DateTime`, and `Calendar` interfaces by accessing their documentation as necessary. **Never** install additional dependencies unless asked or for date/time parsing (which you can use the `date_time_parser` package)
- Don't use `String.to_atom/1` on user input (memory leak risk)
- Predicate function names should not start with `is_` and should end in a question mark. Names like `is_thing` should be reserved for guards
- Elixir's builtin OTP primitives like `DynamicSupervisor` and `Registry`, require names in the child spec, such as `{DynamicSupervisor, name: MyApp.MyDynamicSup}`, then you can use `DynamicSupervisor.start_child(MyApp.MyDynamicSup, child_spec)`
- Use `Task.async_stream(collection, callback, options)` for concurrent enumeration with back-pressure. The majority of times you will want to pass `timeout: :infinity` as option

## Mix guidelines

- Read the docs and options before using tasks (by using `mix help task_name`)
- To debug test failures, run tests in a specific file with `mix test test/my_test.exs` or run all previously failed tests with `mix test --failed`
- `mix deps.clean --all` is **almost never needed**. **Avoid** using it unless you have good reason

## Test guidelines

- **Always use `start_supervised!/1`** to start processes in tests as it guarantees cleanup between tests
- **Avoid** `Process.sleep/1` and `Process.alive?/1` in tests
  - Instead of sleeping to wait for a process to finish, **always** use `Process.monitor/1` and assert on the DOWN message:

      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

   - Instead of sleeping to synchronize before the next call, **always** use `_ = :sys.get_state/1` to ensure the process has handled prior messages
<!-- phoenix:elixir-end -->

<!-- phoenix:phoenix-start -->
## Phoenix guidelines

- Remember Phoenix router `scope` blocks include an optional alias which is prefixed for all routes within the scope. **Always** be mindful of this when creating routes within a scope to avoid duplicate module prefixes.

- You **never** need to create your own `alias` for route definitions! The `scope` provides the alias, ie:

      scope "/admin", AppWeb.Admin do
        pipe_through :browser

        live "/users", UserLive, :index
      end

  the UserLive route would point to the `AppWeb.Admin.UserLive` module

- `Phoenix.View` no longer is needed or included with Phoenix, don't use it
<!-- phoenix:phoenix-end -->

<!-- phoenix:ecto-start -->
## Ecto Guidelines

- **Always** preload Ecto associations in queries when they'll be accessed in templates, ie a message that needs to reference the `message.user.email`
- Remember `import Ecto.Query` and other supporting modules when you write `seeds.exs`
- `Ecto.Schema` fields always use the `:string` type, even for `:text`, columns, ie: `field :name, :string`
- `Ecto.Changeset.validate_number/2` **DOES NOT SUPPORT the `:allow_nil` option**. By default, Ecto validations only run if a change for the given field exists and the change value is not nil, so such as option is never needed
- You **must** use `Ecto.Changeset.get_field(changeset, :field)` to access changeset fields
- Fields which are set programmatically, such as `user_id`, must not be listed in `cast` calls or similar for security purposes. Instead they must be explicitly set when creating the struct
- **Always** invoke `mix ecto.gen.migration migration_name_using_underscores` when generating migration files, so the correct timestamp and conventions are applied
<!-- phoenix:ecto-end -->

<!-- phoenix:html-start -->
## Phoenix HTML guidelines

- Phoenix templates **always** use `~H` or .html.heex files (known as HEEx), **never** use `~E`
- **Always** use the imported `Phoenix.Component.form/1` and `Phoenix.Component.inputs_for/1` function to build forms. **Never** use `Phoenix.HTML.form_for` or `Phoenix.HTML.inputs_for` as they are outdated
- When building forms **always** use the already imported `Phoenix.Component.to_form/2` (`assign(socket, form: to_form(...))` and `<.form for={@form} id="msg-form">`), then access those forms in the template via `@form[:field]`
- **Always** add unique DOM IDs to key elements (like forms, buttons, etc) when writing templates, these IDs can later be used in tests (`<.form for={@form} id="product-form">`)
- For "app wide" template imports, you can import/alias into the `my_app_web.ex`'s `html_helpers` block, so they will be available to all LiveViews, LiveComponent's, and all modules that do `use MyAppWeb, :html` (replace "my_app" by the actual app name)

- Elixir supports `if/else` but **does NOT support `if/else if` or `if/elsif`**. **Never use `else if` or `elseif` in Elixir**, **always** use `cond` or `case` for multiple conditionals.

  **Never do this (invalid)**:

      <%= if condition do %>
        ...
      <% else if other_condition %>
        ...
      <% end %>

  Instead **always** do this:

      <%= cond do %>
        <% condition -> %>
          ...
        <% condition2 -> %>
          ...
        <% true -> %>
          ...
      <% end %>

- HEEx require special tag annotation if you want to insert literal curly's like `{` or `}`. If you want to show a textual code snippet on the page in a `<pre>` or `<code>` block you *must* annotate the parent tag with `phx-no-curly-interpolation`:

      <code phx-no-curly-interpolation>
        let obj = {key: "val"}
      </code>

  Within `phx-no-curly-interpolation` annotated tags, you can use `{` and `}` without escaping them, and dynamic Elixir expressions can still be used with `<%= ... %>` syntax

- HEEx class attrs support lists, but you must **always** use list `[...]` syntax. You can use the class list syntax to conditionally add classes, **always do this for multiple class values**:

      <a class={[
        "px-2 text-white",
        @some_flag && "py-5",
        if(@other_condition, do: "border-red-500", else: "border-blue-100"),
        ...
      ]}>Text</a>

  and **always** wrap `if`'s inside `{...}` expressions with parens, like done above (`if(@other_condition, do: "...", else: "...")`)

  and **never** do this, since it's invalid (note the missing `[` and `]`):

      <a class={
        "px-2 text-white",
        @some_flag && "py-5"
      }> ...
      => Raises compile syntax error on invalid HEEx attr syntax

- **Never** use `<% Enum.each %>` or non-for comprehensions for generating template content, instead **always** use `<%= for item <- @collection do %>`
- HEEx HTML comments use `<%!-- comment --%>`. **Always** use the HEEx HTML comment syntax for template comments (`<%!-- comment --%>`)
- HEEx allows interpolation via `{...}` and `<%= ... %>`, but the `<%= %>` **only** works within tag bodies. **Always** use the `{...}` syntax for interpolation within tag attributes, and for interpolation of values within tag bodies. **Always** interpolate block constructs (if, cond, case, for) within tag bodies using `<%= ... %>`.

  **Always** do this:

      <div id={@id}>
        {@my_assign}
        <%= if @some_block_condition do %>
          {@another_assign}
        <% end %>
      </div>

  and **Never** do this – the program will terminate with a syntax error:

      <%!-- THIS IS INVALID NEVER EVER DO THIS --%>
      <div id="<%= @invalid_interpolation %>">
        {if @invalid_block_construct do}
        {end}
      </div>
<!-- phoenix:html-end -->

<!-- phoenix:liveview-start -->
## Phoenix LiveView guidelines

- **Never** use the deprecated `live_redirect` and `live_patch` functions, instead **always** use the `<.link navigate={href}>` and  `<.link patch={href}>` in templates, and `push_navigate` and `push_patch` functions LiveViews
- **Avoid LiveComponent's** unless you have a strong, specific need for them
- LiveViews should be named like `AppWeb.WeatherLive`, with a `Live` suffix. When you go to add LiveView routes to the router, the default `:browser` scope is **already aliased** with the `AppWeb` module, so you can just do `live "/weather", WeatherLive`

### LiveView streams

- **Always** use LiveView streams for collections for assigning regular lists to avoid memory ballooning and runtime termination with the following operations:
  - basic append of N items - `stream(socket, :messages, [new_msg])`
  - resetting stream with new items - `stream(socket, :messages, [new_msg], reset: true)` (e.g. for filtering items)
  - prepend to stream - `stream(socket, :messages, [new_msg], at: -1)`
  - deleting items - `stream_delete(socket, :messages, msg)`

- When using the `stream/3` interfaces in the LiveView, the LiveView template must 1) always set `phx-update="stream"` on the parent element, with a DOM id on the parent element like `id="messages"` and 2) consume the `@streams.stream_name` collection and use the id as the DOM id for each child. For a call like `stream(socket, :messages, [new_msg])` in the LiveView, the template would be:

      <div id="messages" phx-update="stream">
        <div :for={{id, msg} <- @streams.messages} id={id}>
          {msg.text}
        </div>
      </div>

- LiveView streams are *not* enumerable, so you cannot use `Enum.filter/2` or `Enum.reject/2` on them. Instead, if you want to filter, prune, or refresh a list of items on the UI, you **must refetch the data and re-stream the entire stream collection, passing reset: true**:

      def handle_event("filter", %{"filter" => filter}, socket) do
        # re-fetch the messages based on the filter
        messages = list_messages(filter)

        {:noreply,
         socket
         |> assign(:messages_empty?, messages == [])
         # reset the stream with the new messages
         |> stream(:messages, messages, reset: true)}
      end

- LiveView streams *do not support counting or empty states*. If you need to display a count, you must track it using a separate assign. For empty states, you can use Tailwind classes:

      <div id="tasks" phx-update="stream">
        <div class="hidden only:block">No tasks yet</div>
        <div :for={{id, task} <- @streams.tasks} id={id}>
          {task.name}
        </div>
      </div>

  The above only works if the empty state is the only HTML block alongside the stream for-comprehension.

- When updating an assign that should change content inside any streamed item(s), you MUST re-stream the items
  along with the updated assign:

      def handle_event("edit_message", %{"message_id" => message_id}, socket) do
        message = Chat.get_message!(message_id)
        edit_form = to_form(Chat.change_message(message, %{content: message.content}))

        # re-insert message so @editing_message_id toggle logic takes effect for that stream item
        {:noreply,
         socket
         |> stream_insert(:messages, message)
         |> assign(:editing_message_id, String.to_integer(message_id))
         |> assign(:edit_form, edit_form)}
      end

  And in the template:

      <div id="messages" phx-update="stream">
        <div :for={{id, message} <- @streams.messages} id={id} class="flex group">
          {message.username}
          <%= if @editing_message_id == message.id do %>
            <%!-- Edit mode --%>
            <.form for={@edit_form} id="edit-form-#{message.id}" phx-submit="save_edit">
              ...
            </.form>
          <% end %>
        </div>
      </div>

- **Never** use the deprecated `phx-update="append"` or `phx-update="prepend"` for collections

### LiveView JavaScript interop

- Remember anytime you use `phx-hook="MyHook"` and that JS hook manages its own DOM, you **must** also set the `phx-update="ignore"` attribute
- **Always** provide an unique DOM id alongside `phx-hook` otherwise a compiler error will be raised

LiveView hooks come in two flavors, 1) colocated js hooks for "inline" scripts defined inside HEEx,
and 2) external `phx-hook` annotations where JavaScript object literals are defined and passed to the `LiveSocket` constructor.

#### Inline colocated js hooks

**Never** write raw embedded `<script>` tags in heex as they are incompatible with LiveView.
Instead, **always use a colocated js hook script tag (`:type={Phoenix.LiveView.ColocatedHook}`)
when writing scripts inside the template**:

    <input type="text" name="user[phone_number]" id="user-phone-number" phx-hook=".PhoneNumber" />
    <script :type={Phoenix.LiveView.ColocatedHook} name=".PhoneNumber">
      export default {
        mounted() {
          this.el.addEventListener("input", e => {
            let match = this.el.value.replace(/\D/g, "").match(/^(\d{3})(\d{3})(\d{4})$/)
            if(match) {
              this.el.value = `${match[1]}-${match[2]}-${match[3]}`
            }
          })
        }
      }
    </script>

- colocated hooks are automatically integrated into the app.js bundle
- colocated hooks names **MUST ALWAYS** start with a `.` prefix, i.e. `.PhoneNumber`

#### External phx-hook

External JS hooks (`<div id="myhook" phx-hook="MyHook">`) must be placed in `assets/js/` and passed to the
LiveSocket constructor:

    const MyHook = {
      mounted() { ... }
    }
    let liveSocket = new LiveSocket("/live", Socket, {
      hooks: { MyHook }
    });

#### Pushing events between client and server

Use LiveView's `push_event/3` when you need to push events/data to the client for a phx-hook to handle.
**Always** return or rebind the socket on `push_event/3` when pushing events:

    # re-bind socket so we maintain event state to be pushed
    socket = push_event(socket, "my_event", %{...})

    # or return the modified socket directly:
    def handle_event("some_event", _, socket) do
      {:noreply, push_event(socket, "my_event", %{...})}
    end

Pushed events can then be picked up in a JS hook with `this.handleEvent`:

    mounted() {
      this.handleEvent("my_event", data => console.log("from server:", data));
    }

Clients can also push an event to the server and receive a reply with `this.pushEvent`:

    mounted() {
      this.el.addEventListener("click", e => {
        this.pushEvent("my_event", { one: 1 }, reply => console.log("got reply from server:", reply));
      })
    }

Where the server handled it via:

    def handle_event("my_event", %{"one" => 1}, socket) do
      {:reply, %{two: 2}, socket}
    end

### LiveView tests

- `Phoenix.LiveViewTest` module and `LazyHTML` (included) for making your assertions
- Form tests are driven by `Phoenix.LiveViewTest`'s `render_submit/2` and `render_change/2` functions
- Come up with a step-by-step test plan that splits major test cases into small, isolated files. You may start with simpler tests that verify content exists, gradually add interaction tests
- **Always reference the key element IDs you added in the LiveView templates in your tests** for `Phoenix.LiveViewTest` functions like `element/2`, `has_element/2`, selectors, etc
- **Never** tests again raw HTML, **always** use `element/2`, `has_element/2`, and similar: `assert has_element?(view, "#my-form")`
- Instead of relying on testing text content, which can change, favor testing for the presence of key elements
- Focus on testing outcomes rather than implementation details
- Be aware that `Phoenix.Component` functions like `<.form>` might produce different HTML than expected. Test against the output HTML structure, not your mental model of what you expect it to be
- When facing test failures with element selectors, add debug statements to print the actual HTML, but use `LazyHTML` selectors to limit the output, ie:

      html = render(view)
      document = LazyHTML.from_fragment(html)
      matches = LazyHTML.filter(document, "your-complex-selector")
      IO.inspect(matches, label: "Matches")

### Form handling

#### Creating a form from params

If you want to create a form based on `handle_event` params:

    def handle_event("submitted", params, socket) do
      {:noreply, assign(socket, form: to_form(params))}
    end

When you pass a map to `to_form/1`, it assumes said map contains the form params, which are expected to have string keys.

You can also specify a name to nest the params:

    def handle_event("submitted", %{"user" => user_params}, socket) do
      {:noreply, assign(socket, form: to_form(user_params, as: :user))}
    end

#### Creating a form from changesets

When using changesets, the underlying data, form params, and errors are retrieved from it. The `:as` option is automatically computed too. E.g. if you have a user schema:

    defmodule MyApp.Users.User do
      use Ecto.Schema
      ...
    end

And then you create a changeset that you pass to `to_form`:

    %MyApp.Users.User{}
    |> Ecto.Changeset.change()
    |> to_form()

Once the form is submitted, the params will be available under `%{"user" => user_params}`.

In the template, the form form assign can be passed to the `<.form>` function component:

    <.form for={@form} id="todo-form" phx-change="validate" phx-submit="save">
      <.input field={@form[:field]} type="text" />
    </.form>

Always give the form an explicit, unique DOM ID, like `id="todo-form"`.

#### Avoiding form errors

**Always** use a form assigned via `to_form/2` in the LiveView, and the `<.input>` component in the template. In the template **always access forms this**:

    <%!-- ALWAYS do this (valid) --%>
    <.form for={@form} id="my-form">
      <.input field={@form[:field]} type="text" />
    </.form>

And **never** do this:

    <%!-- NEVER do this (invalid) --%>
    <.form for={@changeset} id="my-form">
      <.input field={@changeset[:field]} type="text" />
    </.form>

- You are FORBIDDEN from accessing the changeset in the template as it will cause errors
- **Never** use `<.form let={f} ...>` in the template, instead **always use `<.form for={@form} ...>`**, then drive all form references from the form assign as in `@form[:field]`. The UI should **always** be driven by a `to_form/2` assigned in the LiveView module that is derived from a changeset
<!-- phoenix:liveview-end -->

<!-- usage-rules-end -->