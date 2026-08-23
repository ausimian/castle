defmodule Castle.MakeReleasesTest do
  # The releases directory is an argument, so nothing here touches the working
  # directory and these can run alongside everything else. `Castle.make_releases/0`
  # derives it from `code:root_dir()`, which is what `:release_handler` resolves
  # its own relative paths against - and which, under `mix test`, is the OTP
  # installation, so the derivation itself is exercised at the boundary in
  # `CastleTest` rather than here.
  use ExUnit.Case, async: true

  alias Castle.Commands
  alias Castle.DeploymentStub
  alias Castle.ReleaseHandlerStub, as: Stub

  @moduletag :tmp_dir

  describe "make_releases/3" do
    test "leaves an existing RELEASES file alone", %{tmp_dir: dir} do
      rel_dir = rel_dir(dir)
      File.write!(Path.join(rel_dir, "RELEASES"), "")

      # The stub has no registered replies, so it raises if it is consulted.
      assert Commands.make_releases(rel_dir, Stub) == {:ok, []}
      assert Stub.calls(:which_releases) == []
    end

    test "refuses a release that did not bring its own ERTS", %{tmp_dir: dir} do
      # This is the operation the finding was about: with no ERTS of its own the
      # release runs the system emulator, code:root_dir() is the Erlang
      # installation, and this would create - or write over - the RELEASES file
      # of the installation itself.
      rel_dir = rel_dir(dir)
      handler = Stub.stub(:which_releases, [{~c"sample", ~c"0.1.0", [], :permanent}])
      Stub.stub(:create_RELEASES, :ok)

      assert {:error, message} = Commands.make_releases(rel_dir, handler, erts_less())
      assert message =~ "Cannot create #{Path.join(rel_dir, "RELEASES")}"
      assert message =~ "the deployment and the emulator's root are different directories"
      assert message =~ "cannot be upgraded by Castle"
      assert Stub.calls(:create_RELEASES) == []
      assert Stub.calls(:which_releases) == []
    end

    test "refuses it even where the file it looks for is already there", %{tmp_dir: dir} do
      # Which is the ordering that matters, and the reason the guard is the first
      # thing this does: an Erlang installation built by OTP has a
      # releases/RELEASES of its own, so looking first would find it, report
      # success, and never say that the deployment cannot be upgraded at all.
      rel_dir = rel_dir(dir)
      File.write!(Path.join(rel_dir, "RELEASES"), "")

      assert {:error, message} = Commands.make_releases(rel_dir, Stub, erts_less())
      assert message =~ "the deployment and the emulator's root are different directories"
    end

    test "creates it from the release running as permanent", %{tmp_dir: dir} do
      rel_dir = rel_dir(dir)
      handler = Stub.stub(:which_releases, [{~c"sample", ~c"0.1.0", [], :permanent}])
      Stub.stub(:create_RELEASES, :ok)

      assert Commands.make_releases(rel_dir, handler) == {:ok, []}

      # The release directory it was given, and the .rel file beneath it. The
      # root is *not* passed: create_RELEASES/3 is create_RELEASES("", RelDir,
      # RelFile, LibDirs), and the empty root is what makes the library paths in
      # the file relative, so that the release can be moved. A fourth argument
      # here would bake this machine's paths into it.
      assert Stub.calls(:create_RELEASES) == [
               [to_charlist(rel_dir), Path.join(rel_dir, "0.1.0/sample.rel"), []]
             ]
    end

    test "reports having nothing to create it from", %{tmp_dir: dir} do
      handler = Stub.stub(:which_releases, [])

      assert {:error, message} = Commands.make_releases(rel_dir(dir), handler)
      assert message =~ Path.join([dir, "releases", "RELEASES"])
      assert message =~ "no release is running as permanent"
    end

    test "reports more permanent releases than it can make sense of", %{tmp_dir: dir} do
      handler =
        Stub.stub(:which_releases, [
          {~c"sample", ~c"0.1.0", [], :permanent},
          {~c"sample", ~c"0.2.0", [], :permanent}
        ])

      assert {:error, message} = Commands.make_releases(rel_dir(dir), handler)
      assert message =~ "expected one permanent release, found 0.1.0, 0.2.0"
    end

    test "reports a failure to create it", %{tmp_dir: dir} do
      handler = Stub.stub(:which_releases, [{~c"sample", ~c"0.1.0", [], :permanent}])
      Stub.stub(:create_RELEASES, {:error, :eacces})

      assert {:error, message} = Commands.make_releases(rel_dir(dir), handler)
      assert message =~ "Cannot create #{Path.join(dir, "releases/RELEASES")}"
      assert message =~ "from #{Path.join(dir, "releases/0.1.0/sample.rel")}."
      assert message =~ "eacces"
    end
  end

  describe "a comparison the filesystem cannot settle" do
    # The remaining two answers come from the `Castle.Deployment.stat/1` seam
    # rather than from a fixture, because neither can be arranged reliably: an
    # `:eacces` needs a mode that root and some filesystems ignore, and a zero
    # inode needs a filesystem that reports no inode numbers, which is not
    # something a test can mount. The first attempt at the `:eacces` case built
    # the mode and then branched on whether the refusal mentioned it, so on a
    # runner that could traverse the directory it printed "skipped" and passed
    # having asserted nothing - green on the very regression it named.
    # Deterministic inputs or nothing.
    test "a stat refused for permissions is not evidence that the two differ" do
      deployment = DeploymentStub.stub("/deployment", "/installation")

      DeploymentStub.stub_stat(fn
        "/deployment" -> {:error, :eacces}
        path -> File.stat(path)
      end)

      handler = Stub.stub(:which_releases, [{~c"sample", ~c"0.1.0", [~c"kernel"], :permanent}])

      assert {:error, message} = Commands.make_releases("/unused", handler, deployment)

      assert message =~ "cannot tell whether the deployment and the emulator's root"
      assert message =~ "/deployment could not be read (eacces)"
      refute message =~ "are different directories"
      assert Stub.calls(:create_RELEASES) == []
    end

    test "a stat refused on the emulator's root says so about that path" do
      # The mirror of the case above, and the reason it is a clause of its own:
      # the refusal names the path whose lookup failed, so a version that
      # reported the other one would send an operator to look at a directory the
      # filesystem answered about perfectly well. The deployment's path is a real
      # directory here, so the first answer is a success and the second is the
      # one being described.
      deployment = DeploymentStub.stub(System.tmp_dir!(), "/installation")

      DeploymentStub.stub_stat(fn
        "/installation" -> {:error, :eacces}
        path -> File.stat(path)
      end)

      handler = Stub.stub(:which_releases, [{~c"sample", ~c"0.1.0", [~c"kernel"], :permanent}])

      assert {:error, message} = Commands.make_releases("/unused", handler, deployment)

      assert message =~ "cannot tell whether the deployment and the emulator's root"
      assert message =~ "/installation could not be read (eacces)"
      refute message =~ "#{System.tmp_dir!()} could not be read"
      refute message =~ "are different directories"
      assert Stub.calls(:create_RELEASES) == []
    end

    test "a filesystem reporting no inode numbers is not evidence either" do
      # Both paths stat cleanly and report the same device, so the only thing
      # between this and `:same` is the zero - and the only thing between it and
      # `:different` is that zero being read as an absence of evidence rather
      # than as a mismatch.
      deployment = DeploymentStub.stub("/deployment", "/installation")
      DeploymentStub.stub_stat({:ok, %File.Stat{major_device: 1, inode: 0}})

      handler = Stub.stub(:which_releases, [{~c"sample", ~c"0.1.0", [~c"kernel"], :permanent}])

      assert {:error, message} = Commands.make_releases("/unused", handler, deployment)

      assert message =~ "cannot tell whether the deployment and the emulator's root"
      assert message =~ "reports no inode numbers"
      refute message =~ "are different directories"
      assert Stub.calls(:create_RELEASES) == []
    end

    test "a zero inode on the second path alone is not evidence either" do
      # The two paths need not be on one filesystem, so the zero can come back
      # from either side on its own - and it has to be read as an absence of
      # evidence whichever side reports it. Two inodes that differ is the shape a
      # version reading the zero as a mismatch would find here, and it would then
      # assert a difference from a number that means "not answered".
      deployment = DeploymentStub.stub("/current", "/releases/1.2.3")

      DeploymentStub.stub_stat(fn
        "/current" -> {:ok, %File.Stat{major_device: 1, inode: 42}}
        _installation -> {:ok, %File.Stat{major_device: 1, inode: 0}}
      end)

      handler = Stub.stub(:which_releases, [{~c"sample", ~c"0.1.0", [~c"kernel"], :permanent}])

      assert {:error, message} = Commands.make_releases("/unused", handler, deployment)

      assert message =~ "cannot tell whether the deployment and the emulator's root"
      assert message =~ "reports no inode numbers"
      refute message =~ "are different directories"
      assert Stub.calls(:create_RELEASES) == []
    end

    @tag :tmp_dir
    test "two paths the filesystem says are one directory are accepted", %{tmp_dir: dir} do
      # The same seam the other way round, and the reason it is worth having:
      # this is the deployment reached through a symlink, where refusing would
      # be the failure an operator cannot work around. Identical device and a
      # non-zero inode, from two paths that do not match as strings.
      deployment = DeploymentStub.stub("/current", "/releases/1.2.3")
      DeploymentStub.stub_stat({:ok, %File.Stat{major_device: 1, inode: 42}})

      handler = Stub.stub(:which_releases, [{~c"sample", ~c"0.1.0", [~c"kernel"], :permanent}])
      Stub.stub(:create_RELEASES, :ok)

      assert {:ok, _} = Commands.make_releases(rel_dir(dir), handler, deployment)
      assert [[_, _, _]] = Stub.calls(:create_RELEASES)
    end
  end

  defp rel_dir(dir) do
    rel_dir = Path.join(dir, "releases")
    File.mkdir_p!(rel_dir)
    rel_dir
  end

  # A deployment whose launcher exported a root of its own while the emulator's
  # is elsewhere, which is what `include_erts: false` leaves behind. Both have to
  # be directories that exist and differ, or the comparison comes back
  # indeterminate rather than different and the refusal is the other one.
  defp erts_less,
    do: DeploymentStub.stub(System.tmp_dir!(), to_string(:code.root_dir()))
end
