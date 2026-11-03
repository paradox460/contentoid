defmodule Contentoid.Settings.Setting do
  @moduledoc """
  How downloads run, edited on the Settings page. At most one row; with none, every field is its
  default (`Contentoid.Settings.get_settings/0`).
  """
  use Contentoid.Schema
  use Gettext, backend: ContentoidWeb.Gettext

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "settings" do
    # Nil: the configured default (dev and test config, `DOWNLOAD_DIR` in production).
    field :download_dir, :string
    # Nil: detected (`Contentoid.Downloads.Docker.socket/0`).
    field :docker_socket, :string
    field :max_concurrent_downloads, :integer, default: 4
    field :log_lines, :integer, default: 200
    field :stop_grace_seconds, :integer, default: 2
    field :pull_timeout_minutes, :integer, default: 30
    # Set by Contentoid.Downloads.pause_queue/0 and resume_queue/0, never by the Settings form.
    field :queue_paused, :boolean, default: false

    timestamps(type: :utc_datetime)
  end

  @path_format ~r{^(/|~(/|$))}

  @doc false
  def changeset(setting, attrs) do
    setting
    |> cast(attrs, [
      :download_dir,
      :docker_socket,
      :max_concurrent_downloads,
      :log_lines,
      :stop_grace_seconds,
      :pull_timeout_minutes
    ])
    |> validate_required([:max_concurrent_downloads, :log_lines, :stop_grace_seconds, :pull_timeout_minutes])
    # Not checked to exist: the daemon may be down, and the runner creates directories itself.
    |> validate_format(:download_dir, @path_format,
      message: dgettext_noop("errors", "must be an absolute path or start with ~")
    )
    |> validate_format(:docker_socket, @path_format,
      message: dgettext_noop("errors", "must be an absolute path or start with ~")
    )
    |> validate_number(:max_concurrent_downloads, greater_than: 0, less_than_or_equal_to: 100)
    |> validate_number(:log_lines, greater_than: 0, less_than_or_equal_to: 10_000)
    # The cap keeps `Contentoid.Downloads.Janitor`'s shutdown bounded.
    |> validate_number(:stop_grace_seconds, greater_than_or_equal_to: 0, less_than_or_equal_to: 30)
    |> validate_number(:pull_timeout_minutes, greater_than: 0, less_than_or_equal_to: 1_440)
    |> unique_constraint(:id,
      name: :settings_singleton_index,
      message: dgettext_noop("errors", "were just saved elsewhere; reload the page")
    )
  end
end
