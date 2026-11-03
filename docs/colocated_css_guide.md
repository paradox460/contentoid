# Colocated CSS guide

This project supports both global and scoped colocated CSS for Phoenix LiveView components.

> **TailwindCSS is banned.** Do not use tailwind utility classes, `@apply`, tailwind directives, or any tailwind config anywhere in this project. All styling **must** be colocated CSS (preferred) or, only when unavoidable, global `app.css`. Client-side JS follows the same colocated-first rule: prefer colocated hooks over external `assets/js/` files. See the JS/CSS guidelines in `AGENTS.md`.

## Priority order

Reach for styling in this order and stop at the first that fits:

1. Scoped colocated CSS (`ContentoidWeb.ColocatedScopedCSS`): the default for component-specific styles.
2. Global colocated CSS (`ContentoidWeb.ColocatedCSS`): only for reusable utilities and base styles.
3. Global `app.css`: only if necessary.
4. Inline `style="..."`: avoid unless there's no other way (e.g. dynamic values computed from Elixir).

## Modules

### `ContentoidWeb.ColocatedCSS`: global CSS
Use this for utility classes or styles that apply across the whole application.

Example:
```elixir
defmodule MyApp.ButtonComponent do
  use Phoenix.Component

  def button(assigns) do
    ~H"""
    <style :type={ContentoidWeb.ColocatedCSS}>
      .btn-utility { 
        padding: 0.5rem 1rem;
        border: 1px solid var(--border-strong);
      }
    </style>
    
    <button class="btn-utility"><%= render_slot(@inner_block) %></button>
    """
  end
end
```

The CSS is extracted globally and available to all components.

### `ContentoidWeb.ColocatedScopedCSS`: scoped CSS
Use this for component-specific styles that apply **only** within the component's boundaries. It uses CSS `@scope` rules to keep styles from leaking.

Example:
```elixir
defmodule MyApp.CardComponent do
  use Phoenix.Component

  def card(assigns) do
    ~H"""
    <style :type={ContentoidWeb.ColocatedScopedCSS}>
      .card-title { 
        font-size: 1.5rem;
        font-weight: bold;
      }
      .card-content {
        padding: 1rem;
      }
    </style>
    
    <div class="card">
      <h3 class="card-title"><%= @title %></h3>
      <div class="card-content">
        <%= render_slot(@inner_block) %>
      </div>
    </div>
    """
  end
end
```

The `.card-title` and `.card-content` styles apply **only** within this component, not to nested components or parent elements.

## Scoped CSS lower bound options

By default, scoped CSS uses an exclusive lower bound, which stops at nested component boundaries.

### Exclusive (default)
```heex
<style :type={ContentoidWeb.ColocatedScopedCSS}>
  .my-class { color: red; }
</style>
```

This generates:
```css
@scope ([phx-css-abc123]) to ([phx-r]) {
  .my-class { color: red; }
}
```

Styles stop at nested component roots (elements with the `phx-r` attribute).

### Inclusive
```heex
<style :type={ContentoidWeb.ColocatedScopedCSS} lower-bound="inclusive">
  .my-class { color: red; }
</style>
```

This generates:
```css
@scope ([phx-css-abc123]) to ([phx-r] > *) {
  .my-class { color: red; }
}
```

Styles reach a nested component's root element (`[phx-r]`) but nothing below it.

### None (no lower bound)
```heex
<style :type={ContentoidWeb.ColocatedScopedCSS} lower-bound="none">
  .my-class { color: red; }
</style>
```

This generates:
```css
@scope ([phx-css-abc123]) {
  .my-class { color: red; }
}
```

With no lower bound, styles apply to the element and **all** its descendants,
crossing nested component boundaries (elements with `phx-r`). That gives up the
encapsulation scoping provides, so reserve it for deliberate parent-page
overrides that must reach inside function components like `<.form>`/`<.input>`.

## How scoped CSS works

1. Each `<style>` block gets a hash-based scope identifier (e.g. `phx-css-abc123`).
2. The scope ID is added as an attribute to all root tags in the template.
3. Styles are wrapped in a `@scope` rule whose upper bound is the scope ID attribute (start applying
   here) and whose lower bound is the `phx-r` attribute (stop applying here).
4. LiveView adds `phx-r` to all component root tags, so the boundaries are found automatically.

### Example transformation

Input:
```heex
<div>
  <style :type={ContentoidWeb.ColocatedScopedCSS}>
    .title { color: blue; }
  </style>
  
  <h1 class="title">Hello</h1>
  
  <.nested_component>
    <p class="title">World</p>
  </.nested_component>
</div>
```

Output HTML:
```html
<div phx-css-abc123>
  <h1 class="title">Hello</h1>  <!-- styled -->
  
  <div phx-r>  <!-- nested component root -->
    <p class="title">World</p>  <!-- NOT styled (outside scope) -->
  </div>
</div>
```

Generated CSS:
```css
@scope ([phx-css-abc123]) to ([phx-r]) {
  .title { color: blue; }
}
```

## When to use each

Use `ContentoidWeb.ColocatedCSS` (global) for utility classes meant for reuse, base styles or
resets, and styling third-party components.

Use `ContentoidWeb.ColocatedScopedCSS` (scoped) for self-contained components, component-specific
layout rules, and whenever styles must not conflict between components. It gives CSS encapsulation
without BEM or similar conventions.

## Breakpoints

Breakpoint and input queries use the saved custom media in `assets/css/media.css`, in `assets/css`
and colocated blocks alike, and never their literals:

| Name | Query | Use |
|---|---|---|
| `--phone` | `(max-width: 54rem)` | phones, and a foldable's inner screen |
| `--tablet` | `(max-width: 64rem)` | tablets and phones |
| `--laptop` | `(max-width: 75rem)` | small laptops, tablets and phones |
| `--touch` | `(hover: none)` | replacing hover-only affordances |
| `--coarse` | `(pointer: coarse)` | 44px hit areas (`var(--touch-target)`) |

```css
@media (--phone) { div:scope { grid-template-columns: minmax(0, 1fr); } }
@media (--phone), (--coarse) { .row { flex-wrap: wrap; } }
```

Bun's CSS bundler leaves `@custom-media` alone; `assets/build.ts` resolves it with LightningCSS
afterwards, and an undefined name fails the build.

## Browser support

CSS `@scope` is supported in:
- Chrome/Edge 118+
- Safari 17.4+
- Firefox 128+

For older browsers, use global CSS with manual scoping via class naming conventions (BEM, etc.).

## Configuration

The scoped CSS implementation needs this in `config/config.exs`:

```elixir
config :phoenix_live_view, root_tag_attribute: "phx-r"
```

This is already configured in this project.

## Tips

- Use colocated CSS when a component needs non-trivial custom styles.
- Start with `ContentoidWeb.ColocatedScopedCSS`; promote a rule to global `ContentoidWeb.ColocatedCSS` only once it's reused across components.
- If you're reaching for a Tailwind utility class, write the equivalent colocated CSS instead.
- Browser DevTools show the generated `@scope` rules and scope attributes.

## Examples in this project

- `ContentoidWeb.CoreComponents.flash/1`: scoped CSS (`lower-bound="none"`, `:scope[data-kind="error"]` root rules) plus the `.AutoDismiss` colocated hook.
- `ContentoidWeb.CoreComponents.button/1`: global `ContentoidWeb.ColocatedCSS`, because its root may be a `<.link>` `<a>` that carries no scope marker.
- `ContentoidWeb.Layouts.app/1`: `lower-bound="none"` with a tag-qualified root (`div:scope`) so the navigation items, `<.link>` roots, stay in scope; plus the `.NavDrawer` colocated hook.
