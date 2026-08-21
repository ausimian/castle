defmodule CastleTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  doctest Castle

  # These go through the real :release_handler, which is running here because
  # castle depends on sasl. No release named below exists, and nothing that
  # reports a failure has changed anything, so what these pin down is what the
  # command boundary does with the answer it gets.
  describe "the command boundary" do
    test "raises, rather than returning, when an operation fails" do
      assert_raise Castle.Error, ~r/^Failed to unpack no-such-release-9\.9\.9\./, fn ->
        Castle.unpack("no-such-release-9.9.9")
      end

      assert_raise Castle.Error, ~r/^Removal of 9\.9\.9 failed\./, fn ->
        Castle.remove("9.9.9")
      end
    end

    test "raises when the configuration of the target version cannot be read" do
      assert_raise Castle.Error, ~r/9\.9\.9\/build\.config/, fn -> Castle.generate("9.9.9") end
    end

    test "does not install a version whose configuration could not be generated" do
      assert_raise Castle.Error, ~r/9\.9\.9\/build\.config/, fn -> Castle.install("9.9.9") end
    end

    test "prints what a successful operation has to report" do
      assert capture_io(&Castle.releases/0) =~ ~r/^\S+\s+permanent$/m
    end
  end
end
