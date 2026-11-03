defmodule ContentoidWeb.ConnCase do
  @moduledoc """
  The case template for tests that need a connection. It imports `Phoenix.ConnTest` and
  verified routes.

  Each test runs in the SQL sandbox, so its database changes are rolled back when it ends.
  PostgreSQL allows these tests to run concurrently with `use ContentoidWeb.ConnCase, async: true`.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      use ContentoidWeb, :verified_routes

      import ContentoidWeb.ConnCase
      import Phoenix.ConnTest
      import Plug.Conn
      # The default endpoint for testing
      @endpoint ContentoidWeb.Endpoint
    end
  end

  setup tags do
    Contentoid.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
