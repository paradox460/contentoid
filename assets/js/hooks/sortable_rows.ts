import Sortable, { type SortableEvent } from "sortablejs";
import type { Hook } from "phoenix_live_view";

/**
 * Drag-to-reorder for a `<.table sort_event=…>` body (ContentoidWeb.CoreComponents.table/1).
 * Only rows with `data-sort-id` move, by their `<.drag_handle>`; the rest of a row keeps its
 * clicks. On a drop the server gets `sort_event` with `{ids}`: those rows' ids in the new order.
 * The server owns the order: it re-lists the rows either way, which snaps a refused drag back.
 * SortableJS's fallback drag lets the page keep a `grabbing` cursor (`:root.drag-active`); its
 * floating copy goes on `<body>`, out of LiveView's way, and `.drag-fallback` hides it. No
 * keyboard alternative.
 */
type SortableRowsHook = Hook & { sortable?: Sortable };

export const SortableRows: SortableRowsHook = {
  mounted() {
    const root = document.documentElement;
    this.sortable = new Sortable(this.el, {
      draggable: "[data-sort-id]",
      handle: "[data-drag-handle]",
      ghostClass: "drag-ghost",
      fallbackClass: "drag-fallback",
      forceFallback: true,
      fallbackOnBody: true,
      animation: 150,
      onStart: () => root.classList.add("drag-active"),
      onEnd: (evt: SortableEvent) => {
        root.classList.remove("drag-active");
        if (evt.oldIndex === evt.newIndex) return;
        this.pushEvent(this.el.dataset.sortEvent!, {
          ids: Array.from(
            this.el.querySelectorAll<HTMLElement>(":scope > [data-sort-id]"),
            (row) => row.dataset.sortId!,
          ),
        });
      },
    });
  },
  destroyed() {
    this.sortable?.destroy();
    document.documentElement.classList.remove("drag-active");
  },
};
