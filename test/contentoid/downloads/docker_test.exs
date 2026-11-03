defmodule Contentoid.Downloads.DockerTest do
  use Contentoid.DataCase, async: true

  alias Contentoid.Downloads.Docker
  alias Contentoid.Downloads.Docker.Frames
  alias Contentoid.FakeDocker
  alias Contentoid.Message

  describe "Frames.split/1" do
    test "keeps stdout and stderr in order and holds back a cut frame" do
      frames = <<1, 0, 0, 0, 3::32, "out", 2, 0, 0, 0, 3::32, "err", 1, 0, 0, 0, 4::32, "mo">>

      assert {["out", "err"], <<1, 0, 0, 0, 4::32, "mo">> = rest} = Frames.split(frames)
      assert {["more"], ""} = Frames.split(rest <> "re")
    end

    test "waits for a whole header" do
      assert {[], <<1, 0, 0>>} = Frames.split(<<1, 0, 0>>)
    end
  end

  describe "ping/0" do
    test "is ok when the daemon answers" do
      FakeDocker.start()
      assert :ok = Docker.ping()
    end

    test "says when it doesn't" do
      FakeDocker.start(down?: true)

      assert {:error, %Message{msgid: "Docker isn't answering: %{reason}", bindings: %{"reason" => _detail}}} =
               Docker.ping()
    end
  end

  test "images_present/1 tells pulled images from missing ones" do
    image = "ghcr.io/mikf/gallery-dl:v1.32.19"
    FakeDocker.start(image?: false)
    assert Docker.images_present([image, image]) == %{image => false}

    :ok = Docker.pull(image)
    assert Docker.images_present([image]) == %{image => true}
  end

  # Without a tag the Engine API would pull every tag of the repository.
  test "pull/1 always names one tag, also behind a registry port" do
    FakeDocker.start(image?: false)

    for {image, pulled} <- [
          {"alpine", "alpine:latest"},
          {"localhost:5000/tool", "localhost:5000/tool:latest"},
          {"localhost:5000/tool:2", "localhost:5000/tool:2"}
        ] do
      assert :ok = Docker.pull(image)
      assert_received {:docker, :pulled, ^pulled}
    end
  end
end
