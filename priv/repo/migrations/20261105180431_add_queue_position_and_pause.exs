defmodule Contentoid.Repo.Migrations.AddQueuePositionAndPause do
  use Ecto.Migration

  def up do
    alter table(:downloads) do
      add :position, :integer
    end

    alter table(:settings) do
      add :queue_paused, :boolean, null: false, default: false
    end

    # Downloads already waiting keep today's order: priority, then their jobs' order.
    execute """
    UPDATE downloads AS d SET position = r.rn
    FROM (
      SELECT d.id,
             row_number() OVER (ORDER BY d.priority DESC, j.scheduled_at ASC NULLS LAST, j.id ASC, d.id ASC) - 1 AS rn
      FROM downloads d LEFT JOIN oban_jobs j ON j.id = d.oban_job_id
      WHERE d.status = 'queued' AND (d.start_at IS NULL OR d.start_at <= now())
    ) AS r
    WHERE d.id = r.id
    """
  end

  def down do
    alter table(:downloads), do: remove(:position)
    alter table(:settings), do: remove(:queue_paused)
  end
end
