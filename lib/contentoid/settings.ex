defmodule Contentoid.Settings do
  @moduledoc """
  How downloads run: the download directory, the Docker socket, the global download limit, the log
  lines kept per download and Docker timings. One row, edited on the Settings page; no row means
  every default.

  Settings are read from the database at each use (one single-row query per run or Docker call), so
  saved changes apply to downloads that start afterwards. The download limit applies at once
  (`Contentoid.Downloads.Slots.set_limit/1`).
  """

  use Gettext, backend: ContentoidWeb.Gettext

  alias Contentoid.Downloads.Slots
  alias Contentoid.Message
  alias Contentoid.Repo
  alias Contentoid.Settings.Setting

  @doc "The saved settings, or the defaults when none are saved."
  @spec get_settings() :: Setting.t()
  def get_settings, do: Repo.one(Setting) || %Setting{}

  @doc "A changeset for editing `setting`."
  def change_settings(%Setting{} = setting, attrs \\ %{}), do: Setting.changeset(setting, attrs)

  @doc "Saves the settings, applying a changed download limit at once."
  @spec update_settings(map()) :: {:ok, Setting.t()} | {:error, Ecto.Changeset.t()}
  def update_settings(attrs) do
    current = get_settings()

    with {:ok, updated} <- current |> Setting.changeset(attrs) |> Repo.insert_or_update() do
      if updated.max_concurrent_downloads != current.max_concurrent_downloads,
        do: Slots.set_limit(updated.max_concurrent_downloads)

      {:ok, updated}
    end
  end

  @doc "Saves whether the download queue is paused (`Contentoid.Downloads.pause_queue/0`)."
  @spec put_queue_paused(boolean()) :: {:ok, Setting.t()} | {:error, Ecto.Changeset.t()}
  def put_queue_paused(paused) when is_boolean(paused) do
    get_settings()
    |> Ecto.Changeset.change(queue_paused: paused)
    |> Ecto.Changeset.unique_constraint(:id, name: :settings_singleton_index)
    |> Repo.insert_or_update()
  end

  @doc """
  The directory relative mount sources resolve under: the setting, else
  `config :contentoid, Contentoid.Settings, default_download_dir:` (dev and test config,
  `DOWNLOAD_DIR` in production).
  """
  @spec download_dir() :: {:ok, Path.t()} | {:error, Message.t()}
  def download_dir do
    case get_settings().download_dir ||
           Keyword.get(Application.get_env(:contentoid, __MODULE__, []), :default_download_dir) do
      nil -> {:error, Message.new(gettext_noop("no download directory set: set it in Settings"))}
      dir -> {:ok, Path.expand(dir)}
    end
  end
end
