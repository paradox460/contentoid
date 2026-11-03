defmodule ContentoidWeb.ColocatedScopedCSS do
  @moduledoc """
  Scoped CSS extraction for Phoenix LiveView colocated `<style>` tags using CSS @scope.

  This module transforms CSS rules to be scoped to only the elements within the
  component that defines them, using CSS @scope rules with upper and lower bounds.

  ## Usage

  In any LiveView component:

      <style :type={ContentoidWeb.ColocatedScopedCSS}>
        .my-class { color: red; }
      </style>

  This will be transformed to:

      @scope ([phx-css-abc123]) to ([phx-r]) {
        .my-class { color: red; }
      }

  ## Lower Bound Options

  By default, the lower bound is exclusive (stops at nested components, their root
  included). You can make it inclusive with the following, which keeps a nested
  component's root (`[phx-r]`) in scope and excludes everything below it:

      <style :type={ContentoidWeb.ColocatedScopedCSS} lower-bound="inclusive">
        .my-class { color: red; }
      </style>

  You can also drop the lower bound entirely with `lower-bound="none"`, which
  emits `@scope ([phx-css-...]) { ... }` (no `to` clause), applying the styles to
  the element and **all** its descendants, including those inside nested
  components. Use it only for deliberate parent-page overrides.

  ## How It Works

  1. Each style block gets a unique hash-based scope identifier (e.g., `phx-css-abc123`)
  2. The scope identifier is added as an attribute to all root tags in the template
  3. CSS @scope rules limit style application between the scope identifier and
     the global `phx-r` attribute (which LiveView adds to all root tags)
  4. This prevents styles from leaking out or into nested components

  ## Browser Support

  CSS @scope is supported in modern browsers. For older browsers, consider using
  global CSS with manual scoping via class names.
  """

  use Phoenix.LiveView.ColocatedCSS

  @impl true
  def transform("style", attrs, css, meta) do
    validate_opts!(attrs)

    {scope, css} = do_scope(css, attrs, meta)

    {:ok, css, [root_tag_attribute: {"phx-css-#{scope}", true}]}
  end

  defp validate_opts!(opts), do: Enum.each(opts, &validate_opt!/1)

  defp validate_opt!({"lower-bound", val}) when val in ["inclusive", "exclusive", "none"], do: :ok

  defp validate_opt!({"lower-bound", val}) do
    raise ArgumentError,
          ~s|expected "inclusive", "exclusive", or "none" for the `lower-bound` attribute of colocated css, got: #{inspect(val)}|
  end

  defp validate_opt!(_opt), do: :ok

  defp do_scope(css, opts, meta) do
    scope = hash("#{meta.module}_#{meta.line}: #{css}")

    upper_bound_selector = ~s|[phx-css-#{scope}]|

    css =
      case lower_bound_selector(opts) do
        nil -> "@scope (#{upper_bound_selector}) { #{css} }"
        boundary -> "@scope (#{upper_bound_selector}) to (#{boundary}) { #{css} }"
      end

    {scope, css}
  end

  defp lower_bound_selector(opts) do
    case opts do
      %{"lower-bound" => "none"} -> nil
      %{"lower-bound" => "inclusive"} -> "[#{root_tag_attribute()}] > *"
      _ -> "[#{root_tag_attribute()}]"
    end
  end

  defp hash(string) do
    # It is important that we do not pad
    # the Base32 encoded value as we use it in
    # an HTML attribute name and = (the padding character)
    # is not valid.
    Base.encode32(:crypto.hash(:md5, string), case: :lower, padding: false)
  end

  defp root_tag_attribute do
    case Application.get_env(:phoenix_live_view, :root_tag_attribute) do
      configured_attribute when is_binary(configured_attribute) ->
        configured_attribute

      configured_attribute ->
        message = """
        a global :root_tag_attribute must be configured to use scoped css

        Expected global :root_tag_attribute to be a string, got: #{inspect(configured_attribute)}

        The global :root_tag_attribute is usually configured to `"phx-r"`, but it needs to be explicitly enabled in your configuration:

            config :phoenix_live_view, root_tag_attribute: "phx-r"

        You can also use a different value than `"phx-r"`.
        """

        raise ArgumentError, message
    end
  end
end
