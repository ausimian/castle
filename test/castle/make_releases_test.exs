defmodule Castle.MakeReleasesTest do
  # make_releases/1 resolves the releases directory relative to the working
  # directory, the way the launcher's env.sh fragment calls it, and the working
  # directory belongs to the whole VM.
  use ExUnit.Case, async: false

  alias Castle.Commands
  alias Castle.ReleaseHandlerStub, as: Stub

  @moduletag :tmp_dir

  describe "make_releases/1" do
    test "leaves an existing RELEASES file alone", %{tmp_dir: dir} do
      File.mkdir_p!(Path.join(dir, "releases"))
      File.write!(Path.join([dir, "releases", "RELEASES"]), "")

      # The stub has no registered replies, so it raises if it is consulted.
      assert make_releases(dir, Stub) == {:ok, []}
      assert Stub.calls(:which_releases) == []
    end

    test "creates it from the release running as permanent", %{tmp_dir: dir} do
      handler = Stub.stub(:which_releases, [{~c"sample", ~c"0.1.0", [], :permanent}])
      Stub.stub(:create_RELEASES, :ok)

      assert make_releases(dir, handler) == {:ok, []}
      assert Stub.calls(:create_RELEASES) == [[~c"releases", "releases/0.1.0/sample.rel", []]]
    end

    test "reports having nothing to create it from", %{tmp_dir: dir} do
      handler = Stub.stub(:which_releases, [])

      assert {:error, message} = make_releases(dir, handler)
      assert message =~ "releases/RELEASES"
      assert message =~ "no release is running as permanent"
    end

    test "reports more permanent releases than it can make sense of", %{tmp_dir: dir} do
      handler =
        Stub.stub(:which_releases, [
          {~c"sample", ~c"0.1.0", [], :permanent},
          {~c"sample", ~c"0.2.0", [], :permanent}
        ])

      assert {:error, message} = make_releases(dir, handler)
      assert message =~ "expected one permanent release, found 0.1.0, 0.2.0"
    end

    test "reports a failure to create it", %{tmp_dir: dir} do
      handler = Stub.stub(:which_releases, [{~c"sample", ~c"0.1.0", [], :permanent}])
      Stub.stub(:create_RELEASES, {:error, :eacces})

      assert {:error, message} = make_releases(dir, handler)
      assert message =~ "Cannot create releases/RELEASES from releases/0.1.0/sample.rel."
      assert message =~ "eacces"
    end
  end

  defp make_releases(dir, handler) do
    File.cd!(dir, fn -> Commands.make_releases(handler) end)
  end
end
