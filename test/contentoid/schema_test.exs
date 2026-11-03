defmodule Contentoid.SchemaTest do
  use ExUnit.Case, async: true

  alias Contentoid.Schema

  test "generate_id/0 yields a version 7 UUID" do
    assert version(Schema.generate_id()) == "7"
  end

  test "successive ids are strictly increasing" do
    ids = for _ <- 1..1000, do: Schema.generate_id()

    assert ids == Enum.sort(ids)
    assert ids == Enum.uniq(ids)
  end

  defp version(<<_::binary-size(14), version::binary-size(1), _::binary>>), do: version
end
