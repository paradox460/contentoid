defmodule Contentoid.PostProcessors do
  @moduledoc """
  Post-processors (`Contentoid.PostProcessors.PostProcessor`): listing and changing them, and picking
  the ones a download runs from its downloader's and schedule's assignments
  (`Contentoid.PostProcessors.Assignment`, cast with their owner's changeset).

  Every change is broadcast to `subscribe/0`rs as `{:post_processors, :changed}`.
  """

  import Ecto.Query

  alias Contentoid.Downloads.Download
  alias Contentoid.PostProcessors.Assignment
  alias Contentoid.PostProcessors.PostProcessor
  alias Contentoid.Repo

  @topic "post_processors"

  @doc "Subscribes the caller to `{:post_processors, :changed}`, sent after any post-processor changes."
  def subscribe, do: Phoenix.PubSub.subscribe(Contentoid.PubSub, @topic)

  @doc "Every post-processor, highest priority first."
  def list_post_processors do
    PostProcessor |> order_by(desc: :priority, asc: :name) |> Repo.all()
  end

  def get_post_processor!(id), do: Repo.get!(PostProcessor, id)

  def change_post_processor(%PostProcessor{} = post_processor, attrs \\ %{}),
    do: PostProcessor.changeset(post_processor, attrs)

  def create_post_processor(attrs) do
    %PostProcessor{} |> PostProcessor.changeset(attrs) |> Repo.insert() |> changed()
  end

  def update_post_processor(%PostProcessor{} = post_processor, attrs) do
    post_processor |> PostProcessor.changeset(attrs) |> Repo.update() |> changed()
  end

  @doc """
  Deletes a post-processor; its assignments go with it. A run already under way has it loaded and
  finishes with it.
  """
  def delete_post_processor(%PostProcessor{} = post_processor) do
    post_processor |> Repo.delete() |> changed()
  end

  @doc """
  What a download runs, as assignments with their post-processor: its downloader's and its
  schedule's, of enabled post-processors, highest priority first (an assignment's own priority, else
  its post-processor's). A post-processor assigned to both with the same arguments and mounts runs
  once, at the first one's place; differing in either, once for each.
  """
  @spec for_download(Download.t()) :: [Assignment.t()]
  def for_download(%Download{downloader_id: downloader_id, schedule_id: schedule_id}) do
    owners = for {owner, id} <- [downloader_id: downloader_id, schedule_id: schedule_id], id, do: {owner, id}

    if owners == [] do
      []
    else
      owned =
        owners
        |> Enum.map(fn {owner, id} -> dynamic([a], field(a, ^owner) == ^id) end)
        |> Enum.reduce(&dynamic(^&2 or ^&1))

      Repo.all(
        from a in Assignment,
          join: p in assoc(a, :post_processor),
          where: ^owned,
          where: p.enabled,
          order_by: [desc: coalesce(a.priority, p.priority), asc: p.name, asc: a.id],
          preload: [post_processor: p]
      )
      |> Enum.uniq_by(&{&1.post_processor_id, &1.arguments, &1.mounts})
    end
  end

  defp changed({:ok, _post_processor} = result) do
    Phoenix.PubSub.broadcast(Contentoid.PubSub, @topic, {:post_processors, :changed})
    result
  end

  defp changed(error), do: error
end
