// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html";
// Establish Phoenix Socket and LiveView configuration.
import { Socket } from "phoenix";
import { LiveSocket } from "phoenix_live_view";
import { hooks as colocatedHooks } from "phoenix-colocated/contentoid";
import topbar from "topbar";
import { SortableRows } from "./hooks/sortable_rows";

declare global {
  interface Window {
    liveSocket: LiveSocket;
    liveReloader: unknown;
  }
}

const csrfToken = document
  .querySelector("meta[name='csrf-token']")!
  .getAttribute("content");

const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  // The browser's IANA time zone: schedules default to it, and times are shown in it.
  params: { _csrf_token: csrfToken, timezone: Intl.DateTimeFormat().resolvedOptions().timeZone },
  hooks: { ...colocatedHooks, SortableRows },
});

// connect if there are any LiveViews on the page
liveSocket.connect();

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket;

// Progress bar for anything LiveView reports as page loading (`phx:page-loading-*`: live
// navigation, joins, reconnects), shown only once a load has taken 300ms. topbar draws on a
// canvas, which needs a concrete color rather than a `var()`, so the scheme's `--primary` is read
// at each load and follows dark mode. No shadow: the design is flat (DESIGN.md).
topbar.config({ shadowBlur: 0 });
window.addEventListener("phx:page-loading-start", () => {
  const accent = getComputedStyle(document.documentElement).getPropertyValue("--primary").trim();
  if (accent) topbar.config({ barColors: { 0: accent } });
  topbar.show(300);
});
window.addEventListener("phx:page-loading-stop", () => topbar.hide());

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", (event) => {
    const reloader = (event as CustomEvent).detail;
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs();

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown: string | null;
    window.addEventListener("keydown", (e) => (keyDown = e.key));
    window.addEventListener("keyup", (_e) => (keyDown = null));
    window.addEventListener(
      "click",
      (e) => {
        if (keyDown === "c") {
          e.preventDefault();
          e.stopImmediatePropagation();
          reloader.openEditorAtCaller(e.target);
        } else if (keyDown === "d") {
          e.preventDefault();
          e.stopImmediatePropagation();
          reloader.openEditorAtDef(e.target);
        }
      },
      true,
    );

    window.liveReloader = reloader;
  });
}
