defmodule Contentoid.Repo.Migrations.AddTotalProgressToDownloads do
  use Ecto.Migration

  def change do
    alter table(:downloads) do
      # How far the whole download is, when the tool can tell (`[contentoid:total]`); `progress` is
      # the current file's.
      add :total_progress, :float
      add :total_text, :string
      # The file being downloaded now (`[contentoid:start]`), as a host path.
      add :current_file, :text
    end
  end
end
