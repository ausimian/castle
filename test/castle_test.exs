defmodule CastleTest do
  use ExUnit.Case
  doctest Castle

  test "greets the world" do
    assert Castle.hello() == :world
  end
end
