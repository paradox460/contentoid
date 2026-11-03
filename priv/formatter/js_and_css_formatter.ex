defmodule JsAndCssFormatter do
  @moduledoc false
  # Format-only plugin for `mix format` (referenced from .formatter.exs as a
  # `:tag_formatters` entry). It deliberately lives outside `lib/` so it is not
  # compiled into the application: a compiled beam here gets lazy-loaded by the
  # HEEx compiler (via `Code.ensure_loaded?/1`) during `mix compile`, and when
  # CI restores a cached `_build` that stale beam triggers a "redefining module"
  # warning that fails `mix compile --warnings-as-errors`.
  #
  # Implements the `Phoenix.LiveView.HTMLFormatter.TagFormatter` behaviour
  # (render_tag/2), but the behaviour is not declared with `@behaviour` because
  # this file is loaded via `Code.require_file/1` before deps are on the code
  # path, where the behaviour module is not yet available.

  def render_tag({"script", attrs, content}, opts) do
    suffix =
      case attrs do
        %{":type" => _} ->
          # ColocatedHook / ColocatedJS: oxfmt picks its parser from the
          # file extension, so mirror the tag's `extension` attr (e.g. "ts")
          # onto the tmp file. Defaults to "js" for plain colocated JS.
          "index.#{Map.get(attrs, "extension", "js")}"

        _ ->
          "tmp.js"
      end

    format(content, suffix, opts)
  end

  def render_tag({"style", _attrs, content}, opts), do: format(content, "tmp.css", opts)

  # Formats `content` through a tmp file named for its parser (`suffix`).
  defp format(content, suffix, opts) do
    if formatter_available?() do
      tmp_file =
        Path.join(System.tmp_dir!(), "oxfmt_#{System.unique_integer([:positive])}_#{suffix}")

      try do
        File.write!(tmp_file, dedent(content))

        case run_oxfmt(tmp_file) do
          {output, 0} ->
            {:ok, String.trim(output)}

          {output, exit_status} ->
            raise "oxfmt failed (exit #{exit_status}) formatting #{opts[:file] || tmp_file}:\n#{output}"
        end
      after
        File.rm(tmp_file)
      end
    else
      :skip
    end
  end

  # Strip the tag's own indentation before oxfmt sees the content.
  #
  # oxfmt re-indents code to column 0 but copies comment and template-literal
  # interiors through byte for byte, since it can't know the leading spaces were
  # HEEx indentation and not intentional. `HTMLFormatter` then re-indents
  # every returned line to the tag's depth, so those untouched interior lines
  # gained the tag indent on *every* `mix format` run and marched right forever;
  # `mix format` never reached a fixed point, which `--check-formatted` reports as
  # a permanently unformatted file.
  #
  # Removing the common indent first makes the round trip stable: oxfmt's
  # output for already-formatted content is then byte-identical to its input, so
  # `HTMLFormatter` applies the tag indent exactly once.
  defp dedent(content) do
    lines = String.split(content, "\n")

    indent =
      lines
      |> Enum.reject(&(String.trim(&1) == ""))
      |> Enum.map(&(byte_size(&1) - byte_size(String.trim_leading(&1))))
      |> Enum.min(fn -> 0 end)

    if indent == 0 do
      content
    else
      Enum.map_join(lines, "\n", fn line ->
        if String.trim(line) == "", do: line, else: binary_slice(line, indent..-1//1)
      end)
    end
  end

  # Format `file` in place with the mise-managed oxfmt and return its contents.
  # oxfmt 0.72 has no stdin mode, so the tmp file (named for the parser: its
  # extension picks JS/TS/CSS) is rewritten and read back. The tmp file lives
  # outside the repo, so the repo's `.oxfmtrc.json` is passed explicitly and
  # `--ignore-path /dev/null` keeps `.gitignore` matching from skipping it. We go
  # through `mise exec` scoped to just the oxfmt tool so it works outside a
  # mise-activated shell (editor format-on-save, git hooks, CI) without
  # resolving the whole tool config, which would trigger unrelated installs and
  # postinstall hooks.
  defp run_oxfmt(file) do
    config = Path.expand("../../.oxfmtrc.json", __DIR__)

    case System.cmd(
           "mise",
           ["exec", "github:oxc-project/oxc", "--", "oxfmt", "--write", "-c", config] ++
             ["--no-error-on-unmatched-pattern", "--ignore-path", "/dev/null", file],
           stderr_to_stdout: true
         ) do
      {_, 0} -> {File.read!(file), 0}
      failure -> failure
    end
  end

  # Whether oxfmt can be launched via mise. Probed once per `mix format` run
  # and memoized. When unavailable, `render_tag/2` returns `:skip` so the tag's
  # contents are left untouched instead of failing the format step. An oxfmt
  # that runs but errors on content still raises.
  defp formatter_available? do
    case :persistent_term.get({__MODULE__, :oxfmt?}, :unknown) do
      :unknown ->
        available =
          try do
            match?(
              {_, 0},
              System.cmd("mise", ["exec", "github:oxc-project/oxc", "--", "oxfmt", "--version"], stderr_to_stdout: true)
            )
          rescue
            _ -> false
          end

        if !available do
          Mix.shell().info("oxfmt not resolvable via mise; skipping <script>/<style> formatting")
        end

        :persistent_term.put({__MODULE__, :oxfmt?}, available)
        available

      available ->
        available
    end
  end
end
