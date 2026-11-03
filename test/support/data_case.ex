defmodule Contentoid.DataCase do
  @moduledoc """
  The case template for tests that use the data layer. Shared test helpers go here.

  Each test runs in the SQL sandbox, so its database changes are rolled back when it ends.
  PostgreSQL allows these tests to run concurrently with `use Contentoid.DataCase, async: true`.
  """

  use ExUnit.CaseTemplate

  alias Contentoid.Repo
  alias Ecto.Adapters.SQL.Sandbox

  using do
    quote do
      import Contentoid.DataCase
      import Ecto
      import Ecto.Changeset
      import Ecto.Query

      alias Contentoid.Repo
    end
  end

  setup tags do
    Contentoid.DataCase.setup_sandbox(tags)
    :ok
  end

  @doc """
  Starts the SQL sandbox owner, shared unless the test is async.
  """
  def setup_sandbox(tags) do
    pid = Sandbox.start_owner!(Repo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)
  end

  @doc """
  Turns changeset errors into a map of messages, with bindings filled in.

      assert {:error, changeset} = Accounts.create_user(%{password: "short"})
      assert "password is too short" in errors_on(changeset).password
      assert %{password: ["password is too short"]} = errors_on(changeset)

  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
