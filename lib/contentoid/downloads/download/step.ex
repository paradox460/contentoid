defmodule Contentoid.Downloads.Download.Step do
  @moduledoc """
  One post-processor run of the download's latest post-processing attempt, in run order. Planned
  as `pending` when post-processing starts, then `running` → `succeeded` | `failed`, or `skipped`
  (a `new_files` trigger with no files, or after an earlier step failed). A retry replaces them.
  """
  use Ecto.Schema

  @type t :: %__MODULE__{}

  # No changeset: only the runner writes steps, through `update_all`.
  @primary_key false
  embedded_schema do
    # The run's label (`Contentoid.Downloads.Runner`).
    field :name, :string
    field :status, Ecto.Enum, values: [:pending, :running, :succeeded, :failed, :skipped], default: :pending
    field :started_at, :utc_datetime
    field :finished_at, :utc_datetime
    field :exit_status, :integer
    # Its last `log_lines` lines (Settings); nil when it printed nothing.
    field :log, :string
  end
end
