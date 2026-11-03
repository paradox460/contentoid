defmodule Contentoid.HostPaths do
  @moduledoc """
  Contentoid hands mount sources (the download directory, downloaders' and post-processors' mounts)
  to the Docker daemon as host paths, and also creates and checks them itself. Run in a container,
  the two only agree when each host directory is bind-mounted into Contentoid's own container at
  the same path (`docs/deployment.md`).

  `warning/1` says when a path can't be one of those: Contentoid runs in a container (Docker's
  `/.dockerenv`, Podman's `/run/.containerenv`) and the path is on no mount but the container's own
  root filesystem. It can't tell a mount at a different host path; that's for the deployment to get
  right.
  """

  use Gettext, backend: ContentoidWeb.Gettext

  alias Contentoid.Message
  alias Contentoid.Paths

  @container_markers ["/.dockerenv", "/run/.containerenv"]
  @mountinfo "/proc/self/mountinfo"

  @doc "Why `path` won't work as a host path here, or nil when it can (or there's no telling)."
  @spec warning(Path.t()) :: Message.t() | nil
  def warning(path) do
    if Enum.any?(@container_markers, &File.exists?/1) do
      case File.read(@mountinfo) do
        {:ok, mountinfo} -> warning(path, mountinfo)
        {:error, _reason} -> nil
      end
    end
  end

  @doc false
  # `mountinfo` as in `/proc/self/mountinfo`, inside a container.
  @spec warning(Path.t(), String.t()) :: Message.t() | nil
  def warning(path, mountinfo) do
    if mount_point(path, mountinfo) == "/" do
      Message.new(
        gettext_noop(
          "Contentoid runs in a container and %{path} isn't on a mount, so files would land inside " <>
            "Contentoid's container while Docker creates an empty %{path} on the host. Bind-mount the " <>
            "host directory into Contentoid's container at the same path."
        ),
        path: path
      )
    end
  end

  # The mount point `path` is under, the longest that matches.
  defp mount_point(path, mountinfo) do
    mountinfo
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case String.split(line, " ") do
        [_id, _parent, _device, _root, point | _rest] -> [unescape(point)]
        _malformed -> []
      end
    end)
    |> Enum.filter(&Paths.under?(path, &1))
    |> Enum.max_by(&String.length/1, fn -> "/" end)
  end

  # The kernel writes space, tab, newline and backslash as octal escapes (`\040`).
  defp unescape(field) do
    Regex.replace(~r/\\([0-7]{3})/, field, fn _escape, octal -> <<String.to_integer(octal, 8)>> end)
  end
end
