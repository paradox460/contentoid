defmodule Contentoid.Repo.Migrations.WidenDownloadProgressText do
  use Ecto.Migration

  def change do
    # Free text from a tool's `progress`/`total` messages, or a post-processor run's label (its
    # arguments included): no 255-character cap.
    alter table(:downloads) do
      modify :progress_text, :text, from: :string
      modify :total_text, :text, from: :string
    end
  end
end
