defmodule Contentoid.Downloads.Docker do
  @moduledoc """
  Runs downloaders' scripts in Docker containers, one per download, through the Docker Engine API
  (v1.41: Docker 20.10 and later, and Podman's Docker-compatible API) on the daemon's Unix socket.

  A run creates the container (pulling its image first if it's missing), starts it, follows its
  logs until it exits, reads its exit status and removes it. Removing a container stops everything
  its script started, because a container is its own process tree. A container doesn't depend on
  whoever started it, though, so download containers are named (`container_name/1`) and labelled:
  `Contentoid.Downloads.Runner` removes its container if the job dies, and
  `Contentoid.Downloads.Janitor` removes any left over at boot and shutdown (`remove_all/0`).

  Containers run with an init process (forwarding signals to the script) and as the user running
  Contentoid, so their files are theirs.

  Settings (`Contentoid.Settings`): the socket (default: `DOCKER_HOST` when it's `unix://`, else the
  first of `/var/run/docker.sock`, `~/.docker/run/docker.sock` and `~/.orbstack/run/docker.sock` that
  exists), the image pull timeout and the stop grace period. `config :contentoid,
  Contentoid.Downloads.Docker, req_options:` adds `Req` options (the tests' fake daemon).
  """

  use Gettext, backend: ContentoidWeb.Gettext

  alias Contentoid.Downloads.Docker.Frames
  alias Contentoid.Downloads.Docker.Tar
  alias Contentoid.Downloads.Download
  alias Contentoid.Message
  alias Contentoid.Settings

  @label "contentoid"
  @sockets ["/var/run/docker.sock", "~/.docker/run/docker.sock", "~/.orbstack/run/docker.sock"]

  @typedoc """
  The container to run, as Engine API `ContainerConfig` fields: at least `"Image"`, plus any of
  `"Entrypoint"`, `"Cmd"`, `"Env"` and `"HostConfig"` (`"Binds"`). Labels, init and user are added.
  """
  @type container :: %{required(String.t()) => term()}

  @doc "The name of a download's container."
  def container_name(%Download{id: id}), do: "contentoid-download-#{id}"

  @doc "The daemon's socket, or an error naming the setting to fix."
  @spec socket() :: {:ok, Path.t()} | {:error, Message.t()}
  def socket do
    case Settings.get_settings().docker_socket do
      nil ->
        case Enum.find(Enum.map(docker_host() ++ @sockets, &Path.expand/1), &File.exists?/1) do
          nil ->
            {:error,
             Message.new(gettext_noop("no Docker socket found; start Docker or set the Docker socket in Settings"))}

          path ->
            {:ok, path}
        end

      path ->
        {:ok, Path.expand(path)}
    end
  end

  defp docker_host do
    case System.get_env("DOCKER_HOST") do
      "unix://" <> path -> [path]
      _other -> []
    end
  end

  @doc """
  Runs `container` as `name`, streaming its stdout and stderr, merged, into the collectable `into`.
  Returns what was collected and the exit status, or an error message when Docker couldn't run it.

  Options: `files`, `{path, contents}` pairs put into the container before it starts, owned by
  root and read-only (`Contentoid.Downloads.Docker.Tar`); `on_pull`, called with the image before a
  missing image is pulled.
  """
  @spec run(String.t(), container(), Collectable.t(), keyword()) ::
          {Collectable.t(), non_neg_integer()} | {:error, Message.t()}
  def run(name, container, into, options \\ []) do
    on_pull = Keyword.get(options, :on_pull, fn _image -> :ok end)
    files = Keyword.get(options, :files, [])

    with {:ok, req} <- client() do
      # A container an earlier attempt left behind would hold the name.
      call(req, :delete, "/containers/#{name}", params: [force: true])
      body = prepare(container)

      with {:ok, id} <- create(req, name, body, on_pull),
           :ok <- put_files(req, id, files),
           {:ok, collected, status} <- follow(req, id, into) do
        call(req, :delete, "/containers/#{id}", params: [force: true])
        {collected, status}
      else
        {:error, message} ->
          call(req, :delete, "/containers/#{name}", params: [force: true])
          {:error, message}
      end
    end
  end

  defp put_files(_req, _id, []), do: :ok

  # Extracted at the root of the created (not yet started) container's filesystem.
  defp put_files(req, id, files) do
    archive = Tar.build(for {path, contents} <- files, do: {path, contents, 0o444})

    case Req.request(req,
           method: :put,
           url: "/containers/#{id}/archive",
           params: [path: "/"],
           headers: [{"content-type", "application/x-tar"}],
           body: archive
         ) do
      {:ok, %Req.Response{status: 200}} ->
        :ok

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error,
         Message.new(gettext_noop("can't put its files in place: %{reason}"), reason: error_message(status, body))}

      {:error, exception} ->
        {:error, unreachable(exception)}
    end
  end

  defp create(req, name, body, on_pull) do
    case Req.request(req, method: :post, url: "/containers/create", params: [name: name], json: body) do
      {:ok, %Req.Response{status: 201, body: %{"Id" => id}}} ->
        {:ok, id}

      {:ok, %Req.Response{status: 404}} ->
        on_pull.(body["Image"])

        with :ok <- pull(req, body["Image"]),
             {:ok, %{"Id" => id}} <- call(req, :post, "/containers/create", params: [name: name], json: body) do
          {:ok, id}
        end

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, error_message(status, body)}

      {:error, exception} ->
        {:error, unreachable(exception)}
    end
  end

  defp follow(req, id, into) do
    with {:ok, _started} <- call(req, :post, "/containers/#{id}/start"),
         {:ok, collected} <- follow_logs(req, id, into),
         {:ok, %{"StatusCode" => status}} <- call(req, :post, "/containers/#{id}/wait", receive_timeout: :infinity) do
      {:ok, collected, status}
    end
  end

  # Streams the container's logs into `into` until the container exits.
  defp follow_logs(req, id, into) do
    {acc, collector} = Collectable.into(into)

    stream = fn {:data, data}, {req, resp} ->
      if resp.status == 200 do
        {buffer, acc} = Req.Response.get_private(resp, :logs, {"", acc})
        {payloads, rest} = Frames.split(buffer <> data)
        acc = Enum.reduce(payloads, acc, &collector.(&2, {:cont, &1}))
        {:cont, {req, Req.Response.put_private(resp, :logs, {rest, acc})}}
      else
        {:cont, {req, Req.Response.update_private(resp, :error_body, data, &(&1 <> data))}}
      end
    end

    case Req.request(req,
           method: :get,
           url: "/containers/#{id}/logs",
           params: [follow: true, stdout: true, stderr: true],
           into: stream,
           receive_timeout: :infinity
         ) do
      {:ok, %Req.Response{status: 200} = resp} ->
        {_rest, acc} = Req.Response.get_private(resp, :logs, {"", acc})
        {:ok, collector.(acc, :done)}

      {:ok, resp} ->
        collector.(acc, :halt)
        {:error, error_message(resp.status, Req.Response.get_private(resp, :error_body, ""))}

      {:error, exception} ->
        collector.(acc, :halt)
        {:error, unreachable(exception)}
    end
  end

  @doc """
  Pulls `image` (a reference such as `ghcr.io/mikf/gallery-dl:v1.32.19`; no tag means `latest`).
  """
  @spec pull(String.t()) :: :ok | {:error, Message.t()}
  def pull(image) do
    with {:ok, req} <- client(), do: pull(req, image)
  end

  defp pull(req, image) do
    {name, tag} = split_reference(image)

    # The daemon answers 200 and streams progress as JSON objects; a failure partway is one of them.
    # A pull can be hundreds of megabytes.
    case Req.request(req,
           method: :post,
           url: "/images/create",
           params: [fromImage: name, tag: tag],
           decode_body: false,
           receive_timeout: to_timeout(minute: Settings.get_settings().pull_timeout_minutes)
         ) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        case Regex.run(~r/"error"\s*:\s*("(?:[^"\\]|\\.)*")/, body, capture: :all_but_first) do
          nil ->
            :ok

          [message] ->
            {:error,
             Message.new(gettext_noop("can't pull %{image}: %{reason}"), image: image, reason: JSON.decode!(message))}
        end

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error,
         Message.new(gettext_noop("can't pull %{image}: %{reason}"), image: image, reason: error_message(status, body))}

      {:error, exception} ->
        {:error, unreachable(exception)}
    end
  end

  # Without an explicit tag the Engine API pulls every tag of the repository.
  defp split_reference(image) do
    case String.split(image, "@", parts: 2) do
      [name, digest] ->
        {name, digest}

      [reference] ->
        case Regex.run(~r{^(.+):([^:/]+)$}, reference, capture: :all_but_first) do
          [name, tag] -> {name, tag}
          nil -> {reference, "latest"}
        end
    end
  end

  @doc """
  Stops and removes a container; a container that's already gone is fine. The script gets SIGTERM
  and the stop grace setting to save its resume state (aria2c's control file) before SIGKILL.
  Returns an error message when it couldn't.
  """
  @spec remove(String.t()) :: :ok | {:error, Message.t()}
  def remove(name) do
    grace = Settings.get_settings().stop_grace_seconds
    with {:ok, req} <- client(), do: stop_and_remove(req, name, grace)
  end

  @doc "Stops and removes every Contentoid container, in parallel. Returns how many there were."
  @spec remove_all() :: {:ok, non_neg_integer()} | {:error, Message.t()}
  def remove_all do
    filters = JSON.encode!(%{label: [@label]})
    grace = Settings.get_settings().stop_grace_seconds

    with {:ok, req} <- client(),
         {:ok, containers} <- call(req, :get, "/containers/json", params: [all: true, filters: filters]) do
      containers
      |> Task.async_stream(&stop_and_remove(req, &1["Id"], grace),
        timeout: to_timeout(second: grace + 10),
        on_timeout: :kill_task
      )
      |> Stream.run()

      {:ok, length(containers)}
    end
  end

  defp stop_and_remove(req, id, grace) do
    call(req, :post, "/containers/#{id}/stop", params: [t: grace], receive_timeout: to_timeout(second: grace + 5))

    case Req.request(req, method: :delete, url: "/containers/#{id}", params: [force: true]) do
      {:ok, %Req.Response{status: status}} when status in 200..299 or status == 404 -> :ok
      {:ok, %Req.Response{status: status, body: body}} -> {:error, error_message(status, body)}
      {:error, exception} -> {:error, unreachable(exception)}
    end
  end

  @doc "Whether the daemon answers."
  @spec ping() :: :ok | {:error, Message.t()}
  def ping do
    with {:ok, req} <- client(),
         {:ok, _pong} <- call(req, :get, "/_ping"),
         do: :ok
  end

  @doc "Whether each of `images` is on the daemon (true, false or an error), by image; none when Docker can't be reached."
  @spec images_present([String.t()]) :: %{String.t() => boolean() | {:error, Message.t()}}
  def images_present(images) do
    case client() do
      {:ok, req} ->
        images
        |> Enum.uniq()
        |> Task.async_stream(&{&1, image_present?(req, &1)}, timeout: :infinity, ordered: false)
        |> Map.new(fn {:ok, pair} -> pair end)

      {:error, _message} ->
        %{}
    end
  end

  defp image_present?(req, image) do
    case Req.request(req, method: :get, url: "/images/#{image}/json") do
      {:ok, %Req.Response{status: 200}} -> true
      {:ok, %Req.Response{status: 404}} -> false
      {:ok, %Req.Response{status: status, body: body}} -> {:error, error_message(status, body)}
      {:error, exception} -> {:error, unreachable(exception)}
    end
  end

  defp prepare(container) do
    container
    |> Map.put("Labels", %{@label => "download"})
    |> Map.update("HostConfig", %{"Init" => true}, &Map.put(&1, "Init", true))
    |> then(&if user = user(), do: Map.put(&1, "User", user), else: &1)
  end

  defp client do
    with {:ok, socket} <- socket() do
      # No retries: a retried log stream would repeat output, and a retried create would conflict.
      options = [base_url: "http://docker/v1.41", unix_socket: socket, retry: false]
      {:ok, Req.new(options ++ req_options())}
    end
  end

  defp call(req, method, url, options \\ []) do
    case Req.request(req, [method: method, url: url] ++ options) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 -> {:ok, body}
      {:ok, %Req.Response{status: status, body: body}} -> {:error, error_message(status, body)}
      {:error, exception} -> {:error, unreachable(exception)}
    end
  end

  defp unreachable(exception),
    do: Message.new(gettext_noop("Docker isn't answering: %{reason}"), reason: Exception.message(exception))

  # The daemon's own message, else its HTTP status.
  defp error_message(_status, %{"message" => message}), do: Message.text(message)

  defp error_message(status, body) when is_binary(body) and body != "" do
    case JSON.decode(body) do
      {:ok, %{"message" => message}} -> Message.text(message)
      _other -> http_status(status)
    end
  end

  defp error_message(status, _body), do: http_status(status)

  defp http_status(status), do: Message.new(gettext_noop("Docker answered HTTP %{status}"), status: status)

  # The user running Contentoid, so downloads belong to them on Linux too (Docker Desktop and
  # OrbStack map ownership either way). Asked once per VM.
  defp user do
    case :persistent_term.get({__MODULE__, :user}, :unset) do
      :unset ->
        user =
          with {uid, 0} <- System.cmd("id", ["-u"]),
               {gid, 0} <- System.cmd("id", ["-g"]),
               do: "#{String.trim(uid)}:#{String.trim(gid)}",
               else: (_failed -> nil)

        :persistent_term.put({__MODULE__, :user}, user)
        user

      user ->
        user
    end
  end

  defp req_options, do: Keyword.get(Application.get_env(:contentoid, __MODULE__, []), :req_options, [])
end
