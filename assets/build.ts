import { watch, existsSync, readdirSync, statSync } from "node:fs";
import { relative, resolve } from "node:path";
import { Features, transform } from "lightningcss";

// Bun computes inline-sourcemap `sources` paths relative to `outdir`; dropping
// `outdir` makes that prefix nondeterministic across builds (byte-identical code,
// differing sourcemap) which defeats change detection. Each bundle builds into a fixed,
// unwatched staging dir to keep output deterministic, then only changed bytes are copied
// into its live-reloaded destination.
const ts = () => new Date().toTimeString().slice(0, 8); // HH:MM:SS
const log = (msg: string) => console.log(`[assets ${ts()}] ${msg}`);
const logError = (msg: string) => console.error(`[assets ${ts()}] ${msg}`);

const bundles = [
  { entrypoints: ["js/app.ts", "css/app.css"], root: ".", stage: ".build-stage", dest: "../priv/static/assets" },
];

// Bun's CSS bundler passes `@custom-media` (assets/css/media.css) through untouched; LightningCSS
// proper resolves it. No `targets`: Bun already lowered syntax. Without targets every feature counts
// as supported, so `include` forces the one compile this pass exists for.
const INLINE_MAP = /\/\*# sourceMappingURL=data:application\/json;base64,([A-Za-z0-9+/=]+) \*\/\s*$/;
function resolveCustomMedia(filename: string, bytes: Buffer, minify: boolean): Buffer {
  const text = bytes.toString("utf8");
  const map = text.match(INLINE_MAP);
  const result = transform({
    filename,
    code: Buffer.from(map ? text.slice(0, map.index) : text),
    minify,
    drafts: { customMedia: true },
    include: Features.CustomMediaQueries,
    sourceMap: map !== null,
    inputSourceMap: map ? Buffer.from(map[1], "base64").toString("utf8") : undefined,
  });
  let out = result.code.toString("utf8");
  if (map && result.map) {
    out += `\n/*# sourceMappingURL=data:application/json;base64,${Buffer.from(result.map).toString("base64")} */\n`;
  }
  return Buffer.from(out);
}

// Writes `bytes` to `dest` unless it already holds exactly them; true when it wrote.
async function writeIfChanged(dest: string, bytes: Buffer): Promise<boolean> {
  const existing = Bun.file(dest);
  if ((await existing.exists()) && Buffer.from(await existing.arrayBuffer()).equals(bytes)) return false;
  await Bun.write(dest, bytes);
  log(`  wrote ${dest}`);
  return true;
}

async function build(opts: Record<string, unknown>, label = "") {
  const started = performance.now();
  const entrypoints = bundles.flatMap((b) => b.entrypoints);
  log(`build start${label ? ` (${label})` : ""}, entrypoints: ${entrypoints.join(", ")}`);

  const written: string[] = [];
  const unchanged: string[] = [];

  for (const bundle of bundles) {
    const result = await Bun.build({
      entrypoints: bundle.entrypoints,
      outdir: bundle.stage,
      root: bundle.root,
      external: ["/fonts/*", "/images/*"],
      throw: false,
      ...opts,
    });

    if (!result.success) {
      logError(`build failed (${result.logs.length} error${result.logs.length === 1 ? "" : "s"})`);
      for (const entry of result.logs) {
        console.error(entry);
      }
      return { success: false };
    }

    const stageAbs = resolve(bundle.stage);
    for (const output of result.outputs) {
      const rel = relative(stageAbs, output.path);
      const dest = `${bundle.dest}/${rel}`;
      const raw = Buffer.from(await output.arrayBuffer());
      let bytes: Buffer;
      try {
        bytes = rel.endsWith(".css") ? resolveCustomMedia(rel, raw, opts.minify === true) : raw;
      } catch (e) {
        logError(`custom media: ${(e as Error).message}`);
        return { success: false };
      }
      if (await writeIfChanged(dest, bytes)) written.push(rel.split("/").pop()!);
      else unchanged.push(rel);
    }
  }
  const ms = (performance.now() - started).toFixed(0);
  log(
    written.length > 0
      ? `rebuilt ${written.join(", ")} (${written.length} changed, ${unchanged.length} unchanged, ${ms}ms)`
      : `no changes (${unchanged.length} up-to-date, ${ms}ms)`,
  );
  return { success: true };
}

const dev = {
  sourcemap: "inline",
  define: { "process.env.NODE_ENV": '"development"' },
};

const prod = {
  minify: true,
  define: { "process.env.NODE_ENV": '"production"' },
};

const mode = process.argv[2];
log(`mode=${mode ?? "build"}`);

if (mode === "deploy") {
  const result = await build(prod, "deploy");
  if (!result.success) process.exit(1);
} else if (mode === "watch") {
  // The Phoenix watcher spawns this process via an Erlang port (System.cmd/3).
  // Graceful BEAM shutdown closes the port; violent death (SIGKILL, crash)
  // closes the port's stdin pipe. Both surface here as stdin EOF, at which
  // point the watcher exits (see the drain loop below), so no orphan lingers
  // rewriting bundles. This is the sole orphan-cleanup mechanism.
  //
  // Do NOT reintroduce a pidfile-based reap that SIGTERMs a sibling watcher:
  // a signal exit is non-zero, which Phoenix's `restart: :transient` watcher
  // treats as an error and restarts, producing a mutual-restart loop between
  // concurrent dev servers.

  const runBuild = () => build(dev, "watch");
  await runBuild();

  let timer: Timer;
  const trigger = (dir: string, filename: string | null) => {
    log(`changed ${dir}/${filename ?? "?"}, rebuild queued`);
    clearTimeout(timer);
    timer = setTimeout(runBuild, 60);
  };

  const dirs = ["../_build/dev/phoenix-colocated/contentoid", "js", "css"];
  const present = dirs.filter((dir) => {
    if (existsSync(dir)) return true;
    log(`not watching (missing) ${dir}`);
    return false;
  });

  // Bind mounts (devcontainer on macOS/Windows) never deliver host inotify events,
  // so fs.watch silently observes nothing. Poll mtimes there instead.
  if (process.env.FILE_WATCHER_POLL === "true" || process.env.FILE_WATCHER_POLL === "1") {
    const snapshot = () => {
      const seen = new Map<string, number>();
      const walk = (dir: string) => {
        for (const entry of readdirSync(dir, { withFileTypes: true })) {
          const path = `${dir}/${entry.name}`;
          if (entry.isDirectory()) walk(path);
          else seen.set(path, statSync(path).mtimeMs);
        }
      };
      for (const dir of present) {
        try {
          walk(dir);
        } catch {
          // Directory vanished between ticks; next tick re-reads it.
        }
      }
      return seen;
    };

    let previous = snapshot();
    setInterval(() => {
      const current = snapshot();
      for (const [path, mtime] of current) {
        if (previous.get(path) !== mtime) {
          previous = current;
          trigger(".", path);
          return;
        }
      }
      for (const path of previous.keys()) {
        if (!current.has(path)) {
          previous = current;
          trigger(".", path);
          return;
        }
      }
      previous = current;
    }, 500);
    log(`polling ${present.join(", ")} every 500ms`);
  } else {
    for (const dir of present) {
      watch(dir, { recursive: true }, (_event, filename) => trigger(dir, filename));
      log(`watching ${dir}`);
    }
  }

  // Drain stdin; EOF resolves the read loop and means the port (and BEAM) closed.
  const reader = Bun.stdin.stream().getReader();
  try {
    while (!(await reader.read()).done) {
      // Discard input; we only care about the EOF signal.
    }
  } catch {
    // stdin error: treat as parent gone.
  }
  log("stdin closed, exiting");
  process.exit(0);
} else {
  const result = await build(dev, "dev");
  if (!result.success) process.exit(1);
}
