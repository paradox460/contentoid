defmodule Contentoid.Schema do
  @moduledoc """
  The base every persisted schema in this app uses instead of `Ecto.Schema` directly.

  Primary keys are V7 UUIDs with `precision: :monotonic` instead of the default `:millisecond`, so
  `id` can break ties when ordering by `inserted_at`. With millisecond precision, rows inserted in
  the same millisecond would come back in random order.

  Monotonic encodes sub-millisecond order in the 12 `rand_a` bits and advances a shared `:atomics`
  counter, so ids strictly increase per node. That costs one compare-exchange per insert, too little
  to measure next to the query itself.

  Timestamps aren't set here. Most schemas use :utc_datetime, a few use :utc_datetime_usec, and some
  tables have none.

  Embedded schemas keep `use Ecto.Schema`, since they have no primary key to generate.

      defmodule Contentoid.Thing do
        use Contentoid.Schema

        schema "things" do
          timestamps(type: :utc_datetime)
        end
      end
  """

  @uuid_options [version: 7, precision: :monotonic]

  @doc """
  A primary key of the same version `use Contentoid.Schema` autogenerates.

  It's for the rare `Repo.insert_all/3` path, which bypasses schema autogeneration and would otherwise
  fall back to `Ecto.UUID.generate/0`, whose default is v4. Keeping the version in one place means a
  bulk insert can't drift from every other row in the table.
  """
  @spec generate_id() :: Ecto.UUID.t()
  def generate_id, do: Ecto.UUID.generate(@uuid_options)

  defmacro __using__(_opts) do
    quote do
      use Ecto.Schema

      @primary_key {:id, Ecto.UUID, autogenerate: unquote(@uuid_options)}
      @foreign_key_type Ecto.UUID
    end
  end
end
