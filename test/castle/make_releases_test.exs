defmodule Castle.MakeReleasesTest do
  # The releases directory is an argument, so nothing here touches the working
  # directory and these can run alongside everything else. `Castle.make_releases/0`
  # derives it from `code:root_dir()`, which is what `:release_handler` resolves
  # its own relative paths against - and which, under `mix test`, is the OTP
  # installation, so the derivation itself is exercised at the boundary in
  # `CastleTest` rather than here.
  use ExUnit.Case, async: true

  alias Castle.Commands
  alias Castle.ReleaseHandlerStub, as: Stub

  @moduletag :tmp_dir

  describe "make_releases/2" do
    test "leaves an existing RELEASES file alone", %{tmp_dir: dir} do
      rel_dir = rel_dir(dir)
      File.write!(Path.join(rel_dir, "RELEASES"), "")

      # The stub has no registered replies, so it raises if it is consulted.
      assert Commands.make_releases(rel_dir, Stub) == {:ok, []}
      assert Stub.calls(:which_releases) == []
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

  defp rel_dir(dir) do
    rel_dir = Path.join(dir, "releases")
    File.mkdir_p!(rel_dir)
    rel_dir
  end
end
