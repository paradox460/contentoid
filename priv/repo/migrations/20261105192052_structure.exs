defmodule Contentoid.Repo.Migrations.Structure do
  @moduledoc false
  # Every migration up to 0.0.1's last, squashed into priv/repo/structure.sql. It takes that last
  # migration's version, so a database that ran the originals has it recorded and skips this; a new
  # one runs it. The release has no psql, so the file runs as one PL/pgSQL EXECUTE, which takes
  # several statements, in the migration's transaction.
  use Ecto.Migration

  def up do
    sql = File.read!(Application.app_dir(:contentoid, "priv/repo/structure.sql"))
    execute("DO $do$ BEGIN EXECUTE $structure$#{sql}$structure$; END $do$")
  end

  def down,
    do:
      raise(
        Ecto.MigrationError,
        "the squashed 0.0.1 structure can't be rolled back; drop the database"
      )
end
