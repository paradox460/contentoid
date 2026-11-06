defmodule Contentoid.Repo.Migrations.AddStepsToDownloads do
  use Ecto.Migration

  def change do
    alter table(:downloads) do
      # Each post-processor run of the latest attempt: status, times, log (`Download.Step`).
      add :steps, {:array, :map}, null: false, default: []
    end
  end
end
