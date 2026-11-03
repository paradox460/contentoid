defmodule Contentoid.Repo.Migrations.CreateDownloads do
  use Ecto.Migration

  def change do
    create table(:downloads, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :url, :text, null: false
      add :grabber, :string, null: false
      add :status, :string, null: false
      add :progress, :float
      add :progress_text, :string
      add :files, {:array, :text}, null: false, default: []
      add :error, :text
      add :log, :text
      add :exit_status, :integer
      add :oban_job_id, :bigint
      add :started_at, :utc_datetime
      add :finished_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:downloads, [:status])
    create index(:downloads, [:inserted_at, :id])
  end
end
