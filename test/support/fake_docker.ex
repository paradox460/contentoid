defmodule Contentoid.FakeDocker do
  @moduledoc """
  A fake Docker Engine API for tests, plugged into `Contentoid.Downloads.Docker` through `Req.Test`
  (`config/test.exs`). It runs no script; a container acts on what follows `contentoid` in its
  command, joined with spaces (`Cmd: [script, "contentoid", url]`, or an arguments download's words):

    * `fail`: logs a line, reports the error `This video is unavailable` and exits 1
    * `quiet-fail`: logs `ERROR: gone` and exits 2, reporting no error
    * `half-fail`: reports `first.mp4` as finished, then an error, and exits 1
    * `playlist`: reports two files with their own URLs, `https://videos.test/watch?v=1` (a path
      with spaces) and `…v=2`
    * `hang`: streams nothing until the container is stopped or removed, then exits 137 (killed)
    * `nothing`: logs `nothing new` and exits 0, reporting no file
    * anything else: reports progress, creates `video.mp4` in the host directory bound at
      `$CONTENTOID_OUTPUT`, reports it at its container path and exits 0

  A post-processor's image `fake/post:KIND` acts on its files (`CONTENTOID_FILES`) instead:
  `move` reports each moved into the directory its first argument names (`/library` without one),
  `remove` reports each removed, `transcode` reports a new `/contentoid/output/video.mkv`, `fail`
  reports `ffmpeg failed` and exits 1, and anything else logs `ok` and exits 0.

  Output comes as multiplexed frames over several chunks, cut mid-frame.

  Everything is reported to the process that called `start/1`: `{:docker, :created, body}`,
  `{:docker, :archive, id, files}` (files as `{path, contents, mode, uid}`), `{:docker, :started, id}`,
  `{:docker, :stopped, id}`, `{:docker, :removed, id}` and `{:docker, :pulled, image}`.
  """

  alias Contentoid.Downloads.Docker

  @doc """
  Stubs the Engine API for the calling test, and sets a socket in Settings so socket detection never
  fails before the stub (the socket is never opened; needs the DB sandbox). Options: `image?: false`
  makes every image missing until pulled; `pull_error: message` makes pulls fail with it;
  `archive_error: message` refuses files put into a container; `down?: true` makes the daemon refuse
  connections.
  """
  def start(options \\ []) do
    {:ok, _settings} = Contentoid.Settings.update_settings(%{docker_socket: "/nonexistent/docker.sock"})
    owner = self()
    {:ok, agent} = Agent.start_link(fn -> %{containers: %{}, pulled: MapSet.new(), owner: owner, options: options} end)
    Req.Test.stub(Docker, &handle(agent, &1))
    agent
  end

  # Its test over (the agent is linked to it), a lingering process gets a refused connection.
  defp handle(agent, conn) do
    if not Process.alive?(agent) or option(agent, :down?) do
      Req.Test.transport_error(conn, :econnrefused)
    else
      conn = Plug.Conn.fetch_query_params(conn)
      route(agent, conn.method, conn.path_info, conn)
    end
  end

  defp route(_agent, "GET", ["v1.41", "_ping"], conn), do: Plug.Conn.send_resp(conn, 200, "OK")

  defp route(agent, "GET", ["v1.41", "images" | rest], conn) do
    image = rest |> Enum.drop(-1) |> Enum.join("/")

    if present?(agent, image),
      do: Req.Test.json(conn, %{"Id" => "sha256:fake"}),
      else: conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{message: "No such image: #{image}"})
  end

  defp route(agent, "POST", ["v1.41", "images", "create"], conn) do
    image = "#{conn.query_params["fromImage"]}:#{conn.query_params["tag"]}"

    case option(agent, :pull_error) do
      nil ->
        Agent.update(agent, &Map.update!(&1, :pulled, fn pulled -> MapSet.put(pulled, image) end))
        send(Agent.get(agent, & &1.owner), {:docker, :pulled, image})
        Plug.Conn.send_resp(conn, 200, ~s({"status":"Pulling from #{image}"}\n{"status":"Downloaded newer image"}\n))

      message ->
        Plug.Conn.send_resp(
          conn,
          200,
          ~s({"status":"Pulling"}\n{"errorDetail":{"message":"#{message}"},"error":"#{message}"}\n)
        )
    end
  end

  defp route(agent, "POST", ["v1.41", "containers", "create"], conn) do
    {:ok, raw, conn} = Plug.Conn.read_body(conn)
    body = JSON.decode!(raw)

    if present?(agent, body["Image"]) do
      id = conn.query_params["name"] || "container-#{System.unique_integer([:positive])}"
      Agent.update(agent, &put_in(&1, [:containers, id], %{body: body, waiter: nil, ended?: false, removed?: false}))
      send(Agent.get(agent, & &1.owner), {:docker, :created, body})
      conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"Id" => id})
    else
      conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{message: "No such image: #{body["Image"]}"})
    end
  end

  defp route(agent, "POST", ["v1.41", "containers", id, "start"], conn) do
    send(Agent.get(agent, & &1.owner), {:docker, :started, id})
    Plug.Conn.send_resp(conn, 204, "")
  end

  # Files arrive as a tar extracted at `path`, read back here as Docker would.
  defp route(agent, "PUT", ["v1.41", "containers", id, "archive"], conn) do
    {:ok, tar, conn} = Plug.Conn.read_body(conn)

    case option(agent, :archive_error) do
      nil ->
        {:ok, table} = :erl_tar.table({:binary, tar}, [:verbose])
        {:ok, contents} = :erl_tar.extract({:binary, tar}, [:memory])
        contents = Map.new(contents)
        root = conn.query_params["path"]

        files =
          for {name, :regular, _size, _mtime, mode, uid, _gid} <- table,
              do: {Path.join(root, to_string(name)), contents[name], mode, uid}

        send(Agent.get(agent, & &1.owner), {:docker, :archive, id, files})
        Plug.Conn.send_resp(conn, 200, "")

      message ->
        conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{message: message})
    end
  end

  defp route(agent, "GET", ["v1.41", "containers", id, "logs"], conn) do
    %{body: body} = container(agent, id)

    case behaviour(body) do
      :hang ->
        waiter = self()

        # Stopped or removed before the logs were asked for: nothing to wait for.
        ended? =
          Agent.get_and_update(agent, fn state ->
            if state.containers[id].ended?,
              do: {true, state},
              else: {false, put_in(state, [:containers, id, :waiter], waiter)}
          end)

        if !ended? do
          receive do
            {:ended, ^id} -> :ok
          end
        end

        Plug.Conn.send_resp(conn, 200, "")

      {output, _status} ->
        create_files(body)
        frames = Enum.map_join(output, fn {stream, text} -> frame(stream, text) end)
        # Cut the stream mid-frame, as a socket might.
        {first, rest} = String.split_at(frames, div(byte_size(frames), 3))
        conn = Plug.Conn.send_chunked(conn, 200)
        {:ok, conn} = Plug.Conn.chunk(conn, first)
        {:ok, conn} = Plug.Conn.chunk(conn, rest)
        conn
    end
  end

  defp route(agent, "POST", ["v1.41", "containers", id, "wait"], conn) do
    status =
      case {container(agent, id), behaviour(container(agent, id).body)} do
        {%{ended?: true}, _behaviour} -> 137
        {_container, :hang} -> 137
        {_container, {_output, status}} -> status
      end

    Req.Test.json(conn, %{"StatusCode" => status})
  end

  defp route(agent, "GET", ["v1.41", "containers", "json"], conn) do
    ids = for {id, %{removed?: false}} <- Agent.get(agent, & &1.containers), do: %{"Id" => id}
    Req.Test.json(conn, ids)
  end

  defp route(agent, "POST", ["v1.41", "containers", id, "stop"], conn) do
    case end_container(agent, id, removed?: false) do
      %{} ->
        send(Agent.get(agent, & &1.owner), {:docker, :stopped, id})
        Plug.Conn.send_resp(conn, 204, "")

      nil ->
        Plug.Conn.send_resp(conn, 304, "")
    end
  end

  defp route(agent, "DELETE", ["v1.41", "containers", id], conn) do
    case end_container(agent, id, removed?: true) do
      %{} ->
        send(Agent.get(agent, & &1.owner), {:docker, :removed, id})
        Plug.Conn.send_resp(conn, 204, "")

      nil ->
        conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{message: "No such container: #{id}"})
    end
  end

  # Ends a container (and, `removed?: true`, removes it) and wakes its logs request, in one step so
  # a logs request can't slip in between. Returns the container, or nil when there was nothing to do.
  defp end_container(agent, id, removed?: removed?) do
    ended =
      Agent.get_and_update(agent, fn state ->
        case state.containers[id] do
          %{removed?: false} = container when removed? or not container.ended? ->
            ended = %{container | ended?: true, removed?: removed?, waiter: nil}
            {container, put_in(state, [:containers, id], ended)}

          _nothing_to_do ->
            {nil, state}
        end
      end)

    with %{ended?: false, waiter: waiter} when is_pid(waiter) <- ended, do: send(waiter, {:ended, id})
    ended
  end

  defp container(agent, id), do: Agent.get(agent, &get_in(&1, [:containers, id]))
  defp option(agent, key), do: Agent.get(agent, &Keyword.get(&1.options, key))

  # As the daemon does, an image named without a tag is `:latest`.
  defp present?(agent, image) do
    tagged = if image =~ ~r{:[^:/]+$} or image =~ "@", do: image, else: image <> ":latest"
    option(agent, :image?) != false or tagged in Agent.get(agent, & &1.pulled)
  end

  # `{output, exit_status}`, output as `{stream, text}` (1 stdout, 2 stderr), or `:hang`.
  defp behaviour(%{"Image" => "fake/post:" <> kind, "Cmd" => [_script, "contentoid" | args]} = body) do
    files = String.split(env(body, "CONTENTOID_FILES") || "", "\n", trim: true)

    case kind do
      "move" ->
        into = List.first(args, "/library")
        {for(file <- files, do: {1, report(%{moved: [file, Path.join(into, Path.basename(file))]})}), 0}

      "remove" ->
        {for(file <- files, do: {1, report(%{removed: file})}), 0}

      "transcode" ->
        {[{1, report(%{file: "/contentoid/output/video.mkv"})}], 0}

      "fail" ->
        {[{2, report(%{error: "ffmpeg failed"})}], 1}

      _ok ->
        {[{1, "ok\n"}], 0}
    end
  end

  defp behaviour(%{"Cmd" => [_script, "contentoid" | args]} = body) do
    url = Enum.join(args, " ")
    output = env(body, "CONTENTOID_OUTPUT")

    cond do
      url =~ "hang" ->
        :hang

      url =~ "quiet-fail" ->
        {[{1, "starting\n"}, {2, "ERROR: gone\n"}], 2}

      # One file finished before the run failed.
      url =~ "half-fail" ->
        {[{1, report(%{file: "#{output}/first.mp4"})}, {2, report(%{error: "connection lost"})}], 1}

      # A playlist: each video's own URL, one path with spaces.
      url =~ "playlist" ->
        {[
           {1, report(%{file: "#{output}/One video [1].mp4", url: "https://videos.test/watch?v=1"})},
           {1, report(%{file: "#{output}/two.mp4", url: "https://videos.test/watch?v=2"})}
         ], 0}

      url =~ "nothing" ->
        {[{1, "nothing new\n"}], 0}

      url =~ "fail" ->
        {[{1, "[site] abc: Downloading webpage\n"}, {2, report(%{error: "This video is unavailable"})}], 1}

      # Progress redrawn with a bare \r, as tools do.
      true ->
        {[
           {1,
            String.trim_trailing(report(%{progress: "  25.0%", text: "1.0MiB/s ETA 00:03"})) <>
              "\r" <> report(%{progress: 100, text: "1.0MiB/s ETA 00:00"})},
           {1, report(%{file: "#{output}/video.mp4"})}
         ], 0}
    end
  end

  # One protocol line (`Contentoid.Downloads.Protocol`): the message named by the map's one
  # protocol key, which holds its main value, and the rest as further fields.
  defp report(%{moved: [from, to]}), do: line(%{contentoid: "moved", from: from, to: to})
  defp report(%{removed: path}), do: line(%{contentoid: "removed", path: path})
  defp report(%{error: message}), do: line(%{contentoid: "error", message: message})
  defp report(%{progress: percent} = fields), do: line(%{contentoid: "progress", percent: percent, text: fields[:text]})
  defp report(%{file: path} = fields), do: line(%{contentoid: "file", path: path, url: fields[:url]})

  defp line(message), do: JSON.encode!(message) <> "\n"

  defp create_files(%{"Image" => "fake/post:" <> _kind}), do: :ok

  defp create_files(%{"Cmd" => [_script, "contentoid" | args], "HostConfig" => %{"Binds" => binds}} = body) do
    if not (Enum.join(args, " ") =~ ~r/fail|hang|nothing/) do
      target = env(body, "CONTENTOID_OUTPUT")
      [host_dir] = for bind <- binds, [host, ^target | _mode] <- [String.split(bind, ":")], do: host
      File.touch!(Path.join(host_dir, "video.mp4"))
    end
  end

  defp env(%{"Env" => env}, name) do
    Enum.find_value(env, fn variable ->
      case String.split(variable, "=", parts: 2) do
        [^name, value] -> value
        _other -> nil
      end
    end)
  end

  defp frame(stream, text), do: <<stream, 0, 0, 0, byte_size(text)::32-big>> <> text
end
