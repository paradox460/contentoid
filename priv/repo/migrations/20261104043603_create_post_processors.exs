defmodule Contentoid.Repo.Migrations.CreatePostProcessors do
  use Ecto.Migration

  def change do
    create table(:post_processors, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :priority, :integer, null: false, default: 0
      add :enabled, :boolean, null: false, default: true
      # new_files: only when the download has files; always: after every successful download.
      add :trigger, :string, null: false, default: "new_files"
      add :image, :string, null: false
      add :script, :text, null: false
      add :mounts, {:array, :map}, null: false, default: []
      add :volumes, {:array, :map}, null: false, default: []
      add :files, {:array, :map}, null: false, default: []
      timestamps(type: :utc_datetime)
    end

    create unique_index(:post_processors, [:name])

    create table(:downloader_post_processors, primary_key: false) do
      add :downloader_id, references(:downloaders, type: :binary_id, on_delete: :delete_all),
        primary_key: true

      add :post_processor_id,
          references(:post_processors, type: :binary_id, on_delete: :delete_all),
          primary_key: true
    end

    create index(:downloader_post_processors, [:post_processor_id])

    create table(:schedule_post_processors, primary_key: false) do
      add :schedule_id, references(:schedules, type: :binary_id, on_delete: :delete_all),
        primary_key: true

      add :post_processor_id,
          references(:post_processors, type: :binary_id, on_delete: :delete_all),
          primary_key: true
    end

    create index(:schedule_post_processors, [:post_processor_id])

    alter table(:downloads) do
      # download → post_processing once the downloader exits 0 and post-processors apply.
      add :phase, :string, null: false, default: "download"
      # The output mount's host directory, recorded when post-processing starts.
      add :output_dir, :text
    end
  end
end
