# Contentoid design

Contentoid is a developer tool. The interface is utilitarian: dense, flat, angular and monospaced. It
borrows the feel of a terminal UI (hard edges, one typeface, a fixed palette, 1px rules), but it is
a browser app and behaves like one: real links, buttons, forms, scrolling, text selection and
accessibility semantics.

The implementation lives in `assets/css/tokens.css` (color), `assets/css/fonts.css` (type),
`assets/css/base.css` (resets) and the colocated `<style>` blocks of each component
(`docs/colocated_css_guide.md`).

## Rules

1. **Color is base16 Tomorrow.** [Tomorrow](https://github.com/chriskempson/tomorrow-theme) as
   published in [base16](https://github.com/tinted-theming/schemes) in light mode, Tomorrow Night in
   dark mode, following `prefers-color-scheme`. No color outside the palette; components use the
   semantic tokens below, never `--base0*` or hex values.
2. **No border radius, anywhere.** `base.css` resets every element (and `::before`/`::after`) to
   `border-radius: 0`, overriding Open Props' normalize and the UA. Never set `border-radius` and
   never use Open Props' `--radius-*`.
3. **Flat.** No `box-shadow`, gradients, `backdrop-filter`, blur or translucent surfaces. Depth comes
   only from a surface step plus a 1px border.
4. **One typeface: Iosevka Custom**, for all text, code included. Only the built weights exist:
   200 (ExtraLight), 400 (Regular), 700 (Bold), each upright and italic. Use 700 for headings and
   emphasis; never ask for 500 or 600.
5. **Icons are Lucide, at stroke width 1.** `<.lucide name="…" />` (Iconex). 0.5 was too thin on some
   monitors. The width is set once for the app (`config :iconex, lucide: [stroke_width: 1]`,
   `config/config.exs`); don't pass `stroke_width` per icon. Icons are 1em and take `currentColor`,
   so size and color them from the parent.
6. **Lines are 1px solid.** `--border` for structure (dividers, panels, table rules); `--border-strong`
   for the edges of controls (inputs, secondary buttons, floating notices), which need 3:1 against
   their surroundings. Focus is a 1px `--ring` outline, offset 1px.
7. **Loosely TUI, not a TUI.** Don't draw borders with box-drawing characters, fake terminal windows,
   blinking cursors or ASCII art, and don't align layout with spaces: use CSS grid and flex. Keep
   native controls and their semantics.
8. **Two panes, no top bar.** A navigation pane on the left holds all of the app's navigation; the
   pane on its right holds whatever is being looked at. See Layout.

## Palette

`--base00`…`--base0F` in `tokens.css` (base16's slot numbering), swapped per scheme. Contrast is
against each scheme's background.

| Token | base16 role | Tomorrow | Contrast | Tomorrow Night | Contrast |
|---|---|---|---|---|---|
| `--base00` | default background | `#ffffff` | — | `#1d1f21` | — |
| `--base01` | lighter background | `#e0e0e0` | — | `#282a2e` | — |
| `--base02` | selection | `#c5c8c6` | — | `#373b41` | — |
| `--base03` | comments | `#b4b7b4` | 2.02 | `#969896` | 5.69 |
| `--base04` | dark foreground | `#969896` | 2.91 | `#b4b7b4` | 8.17 |
| `--base05` | default foreground | `#373b41` | 11.26 | `#c5c8c6` | 9.80 |
| `--base06` | light foreground | `#282a2e` | — | `#e0e0e0` | 12.52 |
| `--base07` | light background | `#1d1f21` | — | `#ffffff` | 16.53 |
| `--base08` | red | `#c82829` | 5.54 | `#cc6666` | 4.46 |
| `--base09` | orange | `#f5871f` | 2.51 | `#de935f` | 6.65 |
| `--base0A` | yellow | `#eab700` | 1.86 | `#f0c674` | 10.26 |
| `--base0B` | green | `#718c00` | 3.85 | `#b5bd68` | 8.22 |
| `--base0C` | aqua | `#3e999f` | 3.35 | `#8abeb7` | 7.97 |
| `--base0D` | blue | `#4271ae` | 4.99 | `#81a2be` | 6.18 |
| `--base0E` | purple | `#8959a8` | 5.17 | `#b294bb` | 6.18 |
| `--base0F` | brown | `#a3685a` | 4.48 | `#a3685a` | 3.69 |

base06, base07 and base0F are in the palette for completeness; no semantic token uses them yet.

## Semantic tokens

| Token | From | Use |
|---|---|---|
| `--background` | base00 | the page |
| `--foreground` | base05 | all running text |
| `--muted-foreground` | dark: base03; light: base04 mixed 60% toward base05 | secondary text: subtitles, table headers, idle controls |
| `--surface-1` | base00 | the base layer; inputs and floating notices sit on it |
| `--surface-2` | base01 | raised chrome (the header bar), hover, zebra rows |
| `--surface-3` | base02 | selected or pressed; `::selection` |
| `--border` | base02 | structural lines |
| `--border-strong` | dark: base03; light: base04 | control edges |
| `--primary` / `--primary-foreground` | base0D / base00 | the main action (as a fill with `--primary-foreground` text), links, pressed toggles, the focus ring (`--ring`), the page-load bar |
| `--destructive` / `--destructive-foreground` | base08 / base00 | destructive actions and errors |
| `--success` / `--warning` / `--info` | base0B / base0A / base0C | status marks |

## Contrast

- Text holds WCAG AA, 4.5:1. No light-mode gray reaches that (base04 is 2.91), so
  `--muted-foreground` there is base04 mixed 60% toward base05 (`#5d6063`: 6.33 on the background,
  4.79 on `--surface-2`). In dark mode it is base03 (5.69, 4.95 on `--surface-2`).
- `--border-strong` is base04 in light mode (2.91, just under the 3:1 control-edge target; base03
  would be 2.02) and base03 in dark mode.
- Status colors (`--success`, `--warning`, `--info`) are marks only: borders, icons, small
  indicators. They never color text or fill behind text; in light mode orange, yellow, green and
  aqua all fall under 4.5:1.
- Tomorrow Night's red is 4.46:1 on the background, a hair under AA. It is used as is for
  destructive text and fills rather than leaving the palette. Keep red text on `--surface-1`; on
  `--surface-2` it drops to 3.87.

## Type

- `--ff-base` is `"Iosevka Custom"` with a monospace fallback stack. It is also
  `--font-monospace-code`, which Open Props' normalize uses for `code`, `kbd` and `pre`.
- The root is 16px on every screen, so iOS doesn't zoom into focused inputs. Size text
  in rem or Open Props' `--font-size-*`.
- The font is built from `iosevka.toml`: `mise run fonts` clones Iosevka (pinned in `mise.toml`),
  builds hinted WOFF2 (needs `ttfautohint` on PATH) and copies the six faces into
  `priv/static/fonts`. Rebuild after editing `iosevka.toml`, and commit the WOFF2 files. Each face is
  over jj's 1 MiB limit for *new* files, so adding a face needs a one-off
  `jj --config snapshot.max-new-file-size=2097152 st`; rebuilding existing faces does not.

## Spacing

Open Props' `--size-*` for padding and gaps; `--panel-gap` between top-level panels (0.75rem, 0.5rem
on phones). Coarse pointers get `--touch-target` (44px) hit areas.

## Layout

`Layouts.app/1` is the whole shell:

- **Navigation pane**, left, 15rem, on `--surface-2` with a `--border` rule on its right edge: the
  app name at the top, one list of navigation items, the version at the bottom. Every way of getting
  around the app is an item here; pages never add a top bar, tabs across the top or their own nav
  strip. The page's item is marked `aria-current="page"` (`--surface-3` background, a `--primary`
  rule on its left edge, `--foreground` text); the rest are `--muted-foreground` until hovered.
  Groups of items get a small uppercase heading when the list grows past a handful.
- **Page pane**, right, takes the remaining width on `--background` and scrolls on its own, so the
  navigation pane stays put. A page opens with `<.header>` (title, optional subtitle and actions)
  and puts everything else below it.
- **Phones** (`--phone`): the page pane takes the full width and the navigation pane becomes a
  drawer from the left (Popover API, so Escape and outside clicks close it), opened by the menu
  button at the top of the page pane. Following a link inside it closes it.
