defmodule Contentoid.Repo.Migrations.CreatePostProcessorAssignments do
  @moduledoc """
  Post-processors are assigned with arguments, and one can be assigned to a downloader or schedule
  more than once (once per set of arguments), so the two join tables become one table of
  assignments with ids of their own. Existing assignments move over with no arguments. Going back
  keeps one assignment per post-processor and owner and loses the arguments.
  """
  use Ecto.Migration

  def up do
    create table(:post_processor_assignments, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :post_processor_id,
          references(:post_processors, type: :binary_id, on_delete: :delete_all), null: false

      # Exactly one owner.
      add :downloader_id, references(:downloaders, type: :binary_id, on_delete: :delete_all)
      add :schedule_id, references(:schedules, type: :binary_id, on_delete: :delete_all)
      # Freeform, split as a shell would and passed to the script as "$@"; nil for none.
      add :arguments, :text
      timestamps(type: :utc_datetime)
    end

    create constraint(:post_processor_assignments, :one_owner,
             check: "num_nonnulls(downloader_id, schedule_id) = 1"
           )

    create index(:post_processor_assignments, [:post_processor_id])
    create index(:post_processor_assignments, [:downloader_id])
    create index(:post_processor_assignments, [:schedule_id])

    # Postgres 18's uuidv7(): time-ordered like every other id (Contentoid.Schema).
    execute """
    INSERT INTO post_processor_assignments (id, post_processor_id, downloader_id, inserted_at, updated_at)
    SELECT uuidv7(), post_processor_id, downloader_id, now(), now() FROM downloader_post_processors
    """

    execute """
    INSERT INTO post_processor_assignments (id, post_processor_id, schedule_id, inserted_at, updated_at)
    SELECT uuidv7(), post_processor_id, schedule_id, now(), now() FROM schedule_post_processors
    """

    drop table(:downloader_post_processors)
    drop table(:schedule_post_processors)
  end

  def down do
    for {table, owner, owner_table} <- [
          {:downloader_post_processors, :downloader_id, :downloaders},
          {:schedule_post_processors, :schedule_id, :schedules}
        ] do
      create table(table, primary_key: false) do
        add owner, references(owner_table, type: :binary_id, on_delete: :delete_all),
          primary_key: true

        add :post_processor_id,
            references(:post_processors, type: :binary_id, on_delete: :delete_all),
            primary_key: true
      end

      create index(table, [:post_processor_id])

      execute """
      INSERT INTO #{table} (#{owner}, post_processor_id)
      SELECT DISTINCT #{owner}, post_processor_id FROM post_processor_assignments WHERE #{owner} IS NOT NULL
      """
    end

    drop table(:post_processor_assignments)
  end
end
