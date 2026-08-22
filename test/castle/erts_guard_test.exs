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

        assert error.message =~
                 "the deployment and the emulator's root are different directories"

        assert error.message =~ "cannot be upgraded by Castle"
      end
    end

    test "the refusal asserts no cause, and no resolution it cannot deliver" do
      # Two directories are all the guard observes, so the message may not claim
      # to know why they differ. This has been got wrong twice - once asserting
      # a missing ERTS, once asserting ERL_ROOTDIR as the only alternative - and
      # both read as a bug in the guard rather than as the refusal they were.
      # Asserted as the absence of the assertions, because that is the defect:
      # any wording that offers the causes as examples passes, and any wording
      # that closes the set fails.
      message = assert_raise(Castle.Error, &Castle.make_releases/0).message

      refute message =~ "this release does not bring its own ERTS"
      refute message =~ "Otherwise ERL_ROOTDIR is set"
      refute message =~ ~r/Either way/

      # Both are still named, as examples - dropping them would be the other way
      # to pass this test, and would leave an operator with nothing to check.
      assert message =~ "include_erts: false"
      assert message =~ "ERL_ROOTDIR"
      assert message =~ "there may be others"

      # And it may not promise that relocating the records is a way out. RELDIR
      # and the sasl releases_dir parameter do move them - `init/1` reads both
      # ahead of the root - so a message anchoring *everything* to the emulator
      # would be false. What is anchored there is the applications, which is why
      # the refusal holds regardless.
      assert message =~ "RELDIR"
      assert message =~ "extracts applications"
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
