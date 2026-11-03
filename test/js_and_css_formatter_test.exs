defmodule JsAndCssFormatterTest do
  # `mix format`'s tag formatter for `<style>`/`<script>`, loaded via
  # `Code.require_file/1` from `.formatter.exs` rather than compiled from `lib/`.
  use ExUnit.Case, async: true

  # The module is loaded at runtime by `Code.require_file/1`, so the compiler cannot see it.
  @compile {:no_warn_undefined, JsAndCssFormatter}

  setup_all do
    if !Code.ensure_loaded?(JsAndCssFormatter) do
      Code.require_file(Path.expand("../priv/formatter/js_and_css_formatter.ex", __DIR__))
    end

    :ok
  end

  # `HTMLFormatter` hands the tag body over still carrying its HEEx indentation
  # and re-indents whatever comes back. oxfmt normalizes code to column 0 but
  # copies comment interiors through byte for byte, so unless the indent is
  # stripped first, those interior lines collect the tag indent on every run and
  # `mix format` never reaches a fixed point.
  defp render(tag, content) do
    case JsAndCssFormatter.render_tag({tag, %{}, content}, file: "test.ex") do
      {:ok, formatted} -> formatted
      :skip -> :skip
    end
  end

  # What `HTMLFormatter` does around the plugin: re-indent every line to the
  # tag's depth. Formatting is only stable if this round trip is a fixed point.
  defp reindent(content, indent) do
    pad = String.duplicate(" ", indent)

    content
    |> String.split("\n")
    |> Enum.map_join("\n", fn
      "" -> ""
      line -> pad <> line
    end)
  end

  defp round_trip(tag, content, indent) do
    case render(tag, content) do
      :skip -> :skip
      formatted -> reindent(formatted, indent)
    end
  end

  describe "render_tag/2 idempotence" do
    test "a multi-line CSS comment does not drift further right on each pass" do
      first =
        round_trip(
          "style",
          """
                /*
                    A comment whose body spans lines. oxfmt leaves the interior alone.
                    So the indent here is whatever the source had.
                  */
                aside:scope {
                  flex: 0 0 auto;
                }
          """,
          6
        )

      if first == :skip do
        # No oxfmt available (`render_tag/2` returns `:skip`); nothing to assert.
        assert true
      else
        second = round_trip("style", first, 6)
        third = round_trip("style", second, 6)

        assert second == first
        assert third == second
      end
    end

    test "a multi-line JS comment and template literal survive repeated passes" do
      first =
        round_trip(
          "script",
          """
                /*
                    A block comment body.
                    Second line.
                  */
                export default {
                  mounted() {
                    this.el.textContent = `line one
                    line two`;
                  }
                };
          """,
          6
        )

      if first == :skip do
        assert true
      else
        second = round_trip("script", first, 6)

        assert second == first
        # The template literal's interior newline must not be re-indented away.
        assert first =~ "line two`"
      end
    end
  end
end
