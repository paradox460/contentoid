defmodule Contentoid.Repo.Migrations.AddMountsToPostProcessorAssignments do
  use Ecto.Migration

  def change do
    alter table(:post_processor_assignments) do
      # Bound in addition to the post-processor's own mounts, for this assignment's runs.
      add :mounts, {:array, :map}, null: false, default: []
    end
  end
end
