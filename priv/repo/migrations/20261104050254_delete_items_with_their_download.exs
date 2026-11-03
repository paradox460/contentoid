defmodule Contentoid.Repo.Migrations.DeleteItemsWithTheirDownload do
  use Ecto.Migration

  # An item is part of its download's record: deleting a finished download deletes its items, so
  # every item has a download. Items left with none by earlier deletions go now.
  def up do
    execute "DELETE FROM download_items WHERE download_id IS NULL"

    alter table(:download_items) do
      modify :download_id, references(:downloads, type: :binary_id, on_delete: :delete_all),
        null: false,
        from: references(:downloads, type: :binary_id, on_delete: :nilify_all)
    end
  end

  def down do
    alter table(:download_items) do
      modify :download_id, references(:downloads, type: :binary_id, on_delete: :nilify_all),
        null: true,
        from: references(:downloads, type: :binary_id, on_delete: :delete_all)
    end
  end
end
