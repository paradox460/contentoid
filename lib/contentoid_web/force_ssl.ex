defmodule ContentoidWeb.ForceSSL do
  @moduledoc """
  `Plug.SSL` (redirect plain HTTP to HTTPS, HSTS) when `config :contentoid, :force_ssl` holds its
  options, and nothing when it's nil. Production sets it from `FORCE_SSL` (`config/runtime.exs`).

  Phoenix's own endpoint `:force_ssl` is compile-time, which would bake the choice into the release
  image; this reads it once at the first request instead.
  """
  @behaviour Plug

  @impl true
  def init(options), do: options

  @impl true
  def call(conn, _options) do
    case ssl_options() do
      nil -> conn
      options -> Plug.SSL.call(conn, options)
    end
  end

  defp ssl_options do
    case :persistent_term.get(__MODULE__, :unset) do
      :unset ->
        options =
          with options when is_list(options) <- Application.get_env(:contentoid, :force_ssl), do: Plug.SSL.init(options)

        :persistent_term.put(__MODULE__, options)
        options

      options ->
        options
    end
  end
end
