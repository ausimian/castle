defmodule Castle.ErtsGuardTest do
  # The guard at the command boundary, through the real `Castle.Deployment` -
  # so `RELEASE_ROOT` is read out of the environment here rather than handed in,
  # which is what says that the variable is the seam and that a release exports
  # it. That makes the environment the node's rather than the process's, hence
  # `async: false`: every other test in this suite relies on there being no
  # RELEASE_ROOT, which is the state that makes the guard inert.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  setup do
    on_exit(fn -> System.delete_env("RELEASE_ROOT") end)
  end

  describe "a deployment whose emulator is not its own" do
    setup do
      # What `include_erts: false` leaves: the launcher exported its own
      # location, and the emulator it went on to run belongs to the Erlang
      # installation, which is where :release_handler resolves everything.
      System.put_env("RELEASE_ROOT", "/opt/castle-erts-guard-test")
      :ok
    end

    test "every operation that would write to the wrong tree raises" do
      # No release named here exists, and none of these reaches
      # :release_handler - which is the point. Without the guard, make_releases/0
      # would find the Erlang installation's own releases/RELEASES and report
      # success, and remove/1 would be asking the handler to delete out of it.
      refusals = [
        {&Castle.make_releases/0, "Cannot create"},
        {fn -> Castle.unpack("9.9.9") end, "Cannot unpack 9.9.9"},
        {fn -> Castle.install("9.9.9") end, "Cannot configure 9.9.9"},
        {fn -> Castle.commit("9.9.9") end, "Cannot configure 9.9.9"},
        {fn -> Castle.remove("9.9.9") end, "Cannot remove 9.9.9"}
      ]

      for {command, refusal} <- refusals do
        error = assert_raise(Castle.Error, command)

        assert error.message =~ refusal
        assert error.message =~ "this release does not bring its own ERTS."
        assert error.message =~ "cannot be upgraded by Castle."
      end
    end

    test "the read-only diagnostics answer as they always did" do
      # An operator here needs to be able to ask what the node believes it is
      # running, or the refusal is all they ever get.
      assert capture_io(&Castle.upgradable/0) == ""
      assert capture_io(&Castle.releases/0) =~ ~r/^\S+\s+permanent$/m
    end
  end

  describe "a deployment the guard has nothing to say about" do
    # Both of these reach the real :release_handler and are refused by it, for a
    # release that does not exist - which is what says the guard let them
    # through. Neither has removed anything.
    test "one whose RELEASE_ROOT is the emulator's own root" do
      System.put_env("RELEASE_ROOT", to_string(:code.root_dir()))

      assert_raise Castle.Error, ~r/^Removal of 9\.9\.9 failed\./, fn ->
        Castle.remove("9.9.9")
      end
    end

    test "one with no RELEASE_ROOT at all, which is anything but a release" do
      System.delete_env("RELEASE_ROOT")

      assert_raise Castle.Error, ~r/^Removal of 9\.9\.9 failed\./, fn ->
        Castle.remove("9.9.9")
      end
    end
  end
end
