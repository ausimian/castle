defmodule Castle.ErtsGuardTest do
  # The guard at the command boundary, through the real `Castle.Deployment` -
  # so `RELEASE_ROOT` is read out of the environment here rather than handed in,
  # which is what says that the variable is the seam and that a release exports
  # it. That makes the environment the node's rather than the process's, hence
  # `async: false`: every other test in this suite relies on there being no
  # RELEASE_ROOT, which is the state that makes the guard inert.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Castle.FileReason

  setup do
    on_exit(fn -> System.delete_env("RELEASE_ROOT") end)
  end

  describe "a deployment whose emulator is not its own" do
    # The deployment directory has to actually exist for these. Pointing
    # RELEASE_ROOT at a path that is not there produces the *indeterminate*
    # refusal rather than this one, since a failed lookup is not evidence that
    # two directories differ - which is the distinction the tri-state comparison
    # draws, and which an earlier version of these tests was accidentally
    # relying on being absent.
    @describetag :tmp_dir

    setup %{tmp_dir: dir} do
      # What `include_erts: false` leaves: the launcher exported its own
      # location, and the emulator it went on to run belongs to the Erlang
      # installation, which is where :release_handler resolves everything.
      deployment = Path.join(dir, "deployment")
      File.mkdir_p!(deployment)
      System.put_env("RELEASE_ROOT", deployment)
      :ok
    end

    test "every operation that would write to the wrong tree raises", %{tmp_dir: dir} do
      # No release named here exists, and none of these reaches
      # :release_handler - which is the point. Without the guard, make_releases/0
      # would find the Erlang installation's own releases/RELEASES and report
      # success, and remove/1 would be asking the handler to delete out of it.
      #
      # **Every command now names itself, and there is no asymmetry left to pin.**
      # There was one: `commit` used to answer "Cannot configure", because
      # `Castle.commit/1` composed `materialise/3` in front of the operation and
      # the configuration step's guard was the first one it met. That composition
      # is gone - it was racy, and `Commands.commit/5` materialises inside its own
      # serialised region now, behind its own guard - so what an operator asked
      # for is what the refusal names, for `commit` exactly as for `install`.
      #
      # This is the visible half of that move, and it is worth pinning in this
      # direction rather than deleting: a "Cannot configure" reappearing here
      # would mean a composition had come back at the boundary.
      refusals = [
        {&Castle.make_releases/0, "Cannot create"},
        {fn -> Castle.unpack("9.9.9") end, "Cannot unpack 9.9.9"},
        {fn -> Castle.install("9.9.9") end, "Cannot install 9.9.9"},
        {fn -> Castle.commit("9.9.9") end, "Cannot commit 9.9.9"},
        {fn -> Castle.remove("9.9.9") end, "Cannot remove 9.9.9"}
      ]

      for {command, refusal} <- refusals do
        error = assert_raise(Castle.Error, command)

        assert error.message =~ refusal

        assert error.message =~
                 "deployment root #{Path.join(dir, "deployment")} differs from emulator root"

        assert error.message =~ "Castle cannot upgrade this deployment"
      end
    end

    test "the refusal is exactly the approved wording", %{tmp_dir: dir} do
      # Asserted whole, not by fragments. Two directories are all the guard
      # observes, so the message may offer common causes but must not claim either
      # was established. It has made that mistake twice, once asserting a missing
      # ERTS and once asserting ERL_ROOTDIR as the only alternative.
      deployment = Path.join(dir, "deployment")
      root_dir = to_string(:code.root_dir())

      message = assert_raise(Castle.Error, &Castle.make_releases/0).message

      assert message ==
               "Cannot create #{Path.join(root_dir, "releases/RELEASES")}: deployment root " <>
                 "#{deployment} differs from emulator root #{root_dir}. :release_handler " <>
                 "resolves applications under the emulator root, so Castle cannot upgrade " <>
                 "this deployment. Make the roots match before retrying. Common causes " <>
                 "include include_erts: false, which uses a shared emulator, and ERL_ROOTDIR, " <>
                 "which overrides its root; other causes are possible. Changing RELDIR or " <>
                 "sasl releases_dir only moves release records."
    end

    test "the read-only diagnostics answer as they always did" do
      # An operator here needs to be able to ask what the node believes it is
      # running, or the refusal is all they ever get.
      assert capture_io(&Castle.upgradable/0) == ""
      assert capture_io(&Castle.releases/0) =~ ~r/^\S+\s+permanent$/m
    end
  end

  describe "a deployment the guard has nothing to say about" do
    # Both of these reach the real :release_handler and fail there, for a
    # release that does not exist - which is what says the guard let them
    # through. Neither has removed anything.
    test "one whose RELEASE_ROOT is the emulator's own root" do
      System.put_env("RELEASE_ROOT", to_string(:code.root_dir()))

      assert_raise Castle.Error, ~r/^Removal failed for 9\.9\.9:/, fn ->
        Castle.remove("9.9.9")
      end
    end

    test "one with no RELEASE_ROOT at all, which is anything but a release" do
      System.delete_env("RELEASE_ROOT")

      assert_raise Castle.Error, ~r/^Removal failed for 9\.9\.9:/, fn ->
        Castle.remove("9.9.9")
      end
    end
  end

  describe "a comparison the filesystem cannot settle" do
    # The paths have already failed to match as strings by the time the `stat`
    # runs, so anything other than a clean pair of answers used to fall into the
    # same branch as two directories that really are different - and be reported
    # as though the difference had been established. These say that an absence of
    # evidence is reported as one.
    @tag :tmp_dir
    test "a path that is not there is not evidence that the two differ", %{tmp_dir: dir} do
      System.put_env("RELEASE_ROOT", Path.join(dir, "never-created"))

      message = assert_raise(Castle.Error, &Castle.make_releases/0).message

      assert message =~ "could not verify that the deployment and emulator roots are the same"

      assert message =~
               "cannot inspect #{Path.join(dir, "never-created")}: #{FileReason.format(:enoent)}"

      # The distinction is the whole point: it must not claim the finding that
      # the version before this one claimed.
      refute message =~ "differs from emulator root"
    end

    @tag :tmp_dir
    test "two directories that both exist and differ are still reported as differing",
         %{tmp_dir: dir} do
      # The other half of the tri-state: making the indeterminate case its own
      # answer must not have cost the definite one. Nothing here is unreadable,
      # so the comparison is made and it succeeds in saying they differ.
      deployment = Path.join(dir, "deployment")
      File.mkdir_p!(deployment)

      System.put_env("RELEASE_ROOT", deployment)

      message = assert_raise(Castle.Error, &Castle.make_releases/0).message

      assert message =~ "differs from emulator root"
      refute message =~ "could not verify that the deployment and emulator roots are the same"
    end
  end
end
