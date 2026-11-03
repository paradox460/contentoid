defmodule Contentoid.Repo.Migrations.AddSchedulePriorityAndJitter do
  use Ecto.Migration

  def change do
    alter table(:schedules) do
      # 0-9, higher runs first; copied to the downloads it starts.
      add :priority, :integer, null: false, default: 0
      # A due run starts after a random delay of up to this many seconds.
      add :jitter_seconds, :integer, null: false, default: 0
    end

    alter table(:downloads) do
      # 0-9, higher runs first (as Oban's job priority, inverted); a schedule's, or 0.
      add :priority, :integer, null: false, default: 0
    end

    alter table(:post_processor_assignments) do
      # Overrides the post-processor's own priority for this assignment's runs; nil keeps it.
      add :priority, :integer
    end

    create constraint(:schedules, :priority_range, check: "priority BETWEEN 0 AND 9")
    create constraint(:schedules, :jitter_not_negative, check: "jitter_seconds >= 0")
    create constraint(:downloads, :priority_range, check: "priority BETWEEN 0 AND 9")
  end
end
