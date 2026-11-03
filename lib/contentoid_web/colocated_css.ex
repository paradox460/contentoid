defmodule ContentoidWeb.ColocatedCSS do
  @moduledoc """
  Global colocated CSS: a `<style :type={ContentoidWeb.ColocatedCSS}>` block is extracted as is, with
  no `@scope`, into the `components` layer (`assets/css/app.css`).

  Second in the order of preference (`docs/colocated_css_guide.md`), for styles a component must
  apply where scoping cannot reach, e.g. `ContentoidWeb.CoreComponents.button/1`, whose root may be
  `<.link>`'s `<a>`, which carries no scope marker. Namespace every class it defines.
  """

  use Phoenix.LiveView.ColocatedCSS

  @impl true
  def transform("style", _attrs, css, _meta), do: {:ok, css, []}
end
