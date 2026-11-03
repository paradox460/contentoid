defmodule Contentoid.Repo.Migrations.LocalizableMessages do
  @moduledoc """
  Stored errors become `Contentoid.Message`s, translated when shown. Existing English text is kept
  verbatim as a `text` message.
  """
  use Ecto.Migration

  def up do
    execute "ALTER TABLE downloads ALTER COLUMN error TYPE jsonb USING CASE WHEN error IS NULL THEN NULL ELSE jsonb_build_object('text', error) END"

    execute "ALTER TABLE schedules ALTER COLUMN last_error TYPE jsonb USING CASE WHEN last_error IS NULL THEN NULL ELSE jsonb_build_object('text', last_error) END"
  end

  def down do
    execute "ALTER TABLE downloads ALTER COLUMN error TYPE varchar USING COALESCE(error->>'text', error->>'msgid')"

    execute "ALTER TABLE schedules ALTER COLUMN last_error TYPE varchar USING COALESCE(last_error->>'text', last_error->>'msgid')"
  end
end
