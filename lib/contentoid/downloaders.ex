defmodule Contentoid.Downloaders do
  @moduledoc """
  Downloaders (`Contentoid.Downloaders.Downloader`): listing, matching a URL to one, and changing them.

  Every change keeps the downloader's download queue (`Contentoid.Downloads.Queues`) and its
  concurrency in Slots (`Contentoid.Downloads.Slots`) in step and is broadcast to `subscribe/0`rs as
  `{:downloaders, :changed}`.
  """

  import Ecto.Query

  alias Contentoid.Downloaders.Downloader
  alias Contentoid.Downloads.Download
  alias Contentoid.Downloads.Queues
  alias Contentoid.Downloads.Slots
  alias Contentoid.Repo
  alias Contentoid.Settings

  @topic "downloaders"

  @doc "Subscribes the caller to `{:downloaders, :changed}`, sent after any downloader changes."
  def subscribe, do: Phoenix.PubSub.subscribe(Contentoid.PubSub, @topic)

  @doc "Every downloader, highest priority first."
  def list_downloaders do
    Downloader |> order_by(desc: :priority, asc: :name) |> Repo.all()
  end

  @doc "The enabled downloaders, highest priority first; `filters` narrows them, e.g. `input: :url`."
  def list_enabled_downloaders(filters \\ []) do
    Downloader |> where(enabled: true) |> where(^filters) |> order_by(desc: :priority, asc: :name) |> Repo.all()
  end

  @doc "A downloader with its post-processor assignments."
  def get_downloader!(id), do: Downloader |> preload(:post_processor_assignments) |> Repo.get!(id)
  def get_downloader(id), do: Repo.get(Downloader, id)

  @doc """
  The highest-priority enabled URL downloader whose pattern matches `url`, or nil. `downloaders`,
  when given, is that list already loaded (`list_enabled_downloaders(input: :url)`), for matching
  several URLs with one query.
  """
  @spec match(String.t(), [Downloader.t()]) :: Downloader.t() | nil
  def match(url, downloaders \\ list_enabled_downloaders(input: :url)) do
    Enum.find(downloaders, fn downloader ->
      regex = Downloader.regex(downloader)
      regex && Regex.match?(regex, url)
    end)
  end

  @doc """
  The host path a mount `source` stands for: absolute paths as they are, `~` expanded, anything else
  relative to the download directory (`Contentoid.Settings.download_dir/0`), or an error when none is
  set.
  """
  @spec host_path(String.t()) :: {:ok, Path.t()} | {:error, Contentoid.Message.t()}
  def host_path(source) do
    cond do
      String.starts_with?(source, "/") -> {:ok, source}
      source == "~" or String.starts_with?(source, "~/") -> {:ok, Path.expand(source)}
      true -> with {:ok, dir} <- Settings.download_dir(), do: {:ok, Path.join(dir, source)}
    end
  end

  def change_downloader(%Downloader{} = downloader, attrs \\ %{}), do: Downloader.changeset(downloader, attrs)

  def create_downloader(attrs) do
    %Downloader{} |> Downloader.changeset(attrs) |> Repo.insert() |> changed()
  end

  @doc """
  Updates a downloader; `attrs` `post_processor_assignments`, when given, replaces its
  post-processor assignments (`Contentoid.PostProcessors.Assignment`).
  """
  def update_downloader(%Downloader{} = downloader, attrs) do
    downloader
    |> Repo.preload(:post_processor_assignments)
    |> Downloader.changeset(attrs)
    |> Repo.update()
    |> changed()
  end

  @doc """
  Deletes a downloader, unless it has downloads queued or running. Its finished downloads keep its
  name (`Download.downloader_name`).
  """
  def delete_downloader(%Downloader{} = downloader) do
    active? =
      Repo.exists?(from d in Download, where: d.downloader_id == ^downloader.id and d.status in [:queued, :running])

    if active? do
      {:error, :in_use}
    else
      Queues.stop(downloader)
      downloader |> Repo.delete() |> changed()
    end
  end

  defp changed({:ok, %Downloader{} = downloader} = result) do
    if Ecto.get_meta(downloader, :state) == :loaded do
      Queues.sync(downloader)
      Slots.set_concurrency(downloader.id, downloader.concurrency)
    end

    Phoenix.PubSub.broadcast(Contentoid.PubSub, @topic, {:downloaders, :changed})
    result
  end

  defp changed(error), do: error
end
