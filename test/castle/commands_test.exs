defmodule Castle.CommandsTest do
  use ExUnit.Case, async: true

  alias Castle.Commands
  alias Castle.ConfigProviderStub
  alias Castle.ReleaseHandlerStub, as: Stub

  describe "generate/1" do
    @tag :tmp_dir
    test "expands the build configuration through the config providers", %{tmp_dir: dir} do
      write_build_config(dir,
        castle: [config_providers: [{ConfigProviderStub, merge: [sample: [greeting: "runtime"]]}]],
        sample: [greeting: "build", untouched: true]
      )

      assert Commands.generate(dir) == {:ok, []}

      config = read_sys_config(dir)
      assert config[:sample][:greeting] == "runtime"
      assert config[:sample][:untouched] == true
    end

    @tag :tmp_dir
    test "writes the build configuration as-is when there are no providers", %{tmp_dir: dir} do
      write_build_config(dir, sample: [greeting: "build"])

      assert Commands.generate(dir) == {:ok, []}
      assert read_sys_config(dir) == [sample: [greeting: "build"]]
    end

    @tag :tmp_dir
    test "reports a missing build configuration", %{tmp_dir: dir} do
      assert {:error, message} = Commands.generate(dir)
      assert message =~ Path.join(dir, "build.config")
      assert message =~ "no such file or directory"
    end

    @tag :tmp_dir
    test "reports an unreadable build configuration", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "build.config"), "]].\n")

      assert {:error, message} = Commands.generate(dir)
      assert message =~ Path.join(dir, "build.config")
    end

    @tag :tmp_dir
    test "reports a build configuration holding more than one term", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "build.config"), "[].\n[].\n")

      assert {:error, message} = Commands.generate(dir)
      assert message =~ "expected one term, found 2"
    end

    @tag :tmp_dir
    test "reports a sys.config it cannot write", %{tmp_dir: dir} do
      write_build_config(dir, sample: [greeting: "build"])
      # Whatever the reason, the operator has to be told which file it was.
      File.mkdir_p!(Path.join(dir, "sys.config"))

      assert {:error, message} = Commands.generate(dir)
      assert message =~ Path.join(dir, "sys.config")
    end

    @tag :tmp_dir
    test "lets a failing config provider speak for itself", %{tmp_dir: dir} do
      write_build_config(dir,
        castle: [config_providers: [{ConfigProviderStub, raise: "DATABASE_URL is not set"}]]
      )

      assert_raise RuntimeError, "DATABASE_URL is not set", fn -> Commands.generate(dir) end
      refute File.exists?(Path.join(dir, "sys.config"))
    end
  end

  describe "unpack/2" do
    test "reports the version that was unpacked" do
      handler = Stub.stub(:unpack_release, {:ok, ~c"1.2.3"})

      assert Commands.unpack("sample-1.2.3", handler) == {:ok, ["Unpacked 1.2.3 ok"]}
      assert Stub.calls(:unpack_release) == [[~c"sample-1.2.3"]]
    end

    test "reports a failure to unpack" do
      handler = Stub.stub(:unpack_release, {:error, {:no_such_file, ~c"sample-1.2.3.tar.gz"}})

      assert {:error, message} = Commands.unpack("sample-1.2.3", handler)
      assert message =~ "Failed to unpack sample-1.2.3."
      assert message =~ "no_such_file"
    end
  end

  describe "install/2" do
    test "reports the version change" do
      handler = Stub.stub(:install_release, {:ok, ~c"1.2.2", ~c"upgrade"})

      assert Commands.install("1.2.3", handler) ==
               {:ok, ["Now running 1.2.3 (previously 1.2.2)."]}

      assert Stub.calls(:install_release) == [[~c"1.2.3"]]
    end

    test "reports a restart of the emulator as the success it is" do
      handler = Stub.stub(:install_release, {:continue_after_restart, ~c"1.2.2", ~c"upgrade"})

      assert {:ok, lines} = Commands.install("1.2.3", handler)
      assert Enum.join(lines, " ") =~ "Restarting to install 1.2.3 (previously 1.2.2)."
    end

    test "reports a failure to install" do
      handler = Stub.stub(:install_release, {:error, {:no_such_release, ~c"1.2.3"}})

      assert {:error, message} = Commands.install("1.2.3", handler)
      assert message =~ "Install of 1.2.3 failed."
      assert message =~ "no_such_release"
    end

    test "reports a result it does not recognise" do
      handler = Stub.stub(:install_release, {:whatever, ~c"1.2.2"})

      assert {:error, message} = Commands.install("1.2.3", handler)
      assert message =~ "Install of 1.2.3 returned an unexpected result."
    end
  end

  describe "running/2" do
    test "confirms the version an install has made current" do
      handler =
        Stub.stub(:which_releases, [
          {~c"sample", ~c"1.2.3", [], :current},
          {~c"sample", ~c"1.2.2", [], :permanent}
        ])

      assert Commands.running("1.2.3", handler) == {:ok, []}
    end

    test "confirms the version a commit has made permanent" do
      handler =
        Stub.stub(:which_releases, [
          {~c"sample", ~c"1.2.3", [], :permanent},
          {~c"sample", ~c"1.2.2", [], :old}
        ])

      assert Commands.running("1.2.3", handler) == {:ok, []}
    end

    test "refuses the permanent version while another one is current" do
      # Committing 1.2.2 and then installing 1.2.3 leaves 1.2.2 permanent, but
      # it is 1.2.3 that is running.
      handler =
        Stub.stub(:which_releases, [
          {~c"sample", ~c"1.2.3", [], :current},
          {~c"sample", ~c"1.2.2", [], :permanent}
        ])

      assert Commands.running("1.2.2", handler) ==
               {:error, "1.2.2 is not the running release. 1.2.3 is."}
    end

    test "refuses a version left unpacked by a continuation that rolled back" do
      handler =
        Stub.stub(:which_releases, [
          {~c"sample", ~c"1.2.3", [], :unpacked},
          {~c"sample", ~c"1.2.2", [], :permanent}
        ])

      assert Commands.running("1.2.3", handler) ==
               {:error, "1.2.3 is not the running release. 1.2.2 is."}
    end

    test "refuses a version that is only tmp_current, before the restart" do
      # release_handler writes the target as tmp_current and then reboots. The
      # upgrade has not happened yet, and may still roll back.
      handler =
        Stub.stub(:which_releases, [
          {~c"sample", ~c"1.2.3", [], :tmp_current},
          {~c"sample", ~c"1.2.2", [], :permanent}
        ])

      assert Commands.running("1.2.3", handler) ==
               {:error, "1.2.3 is not the running release. 1.2.2 is."}
    end

    test "refuses a version the system has never heard of" do
      handler = Stub.stub(:which_releases, [{~c"sample", ~c"1.2.2", [], :permanent}])

      assert Commands.running("9.9.9", handler) ==
               {:error, "9.9.9 is not the running release. 1.2.2 is."}
    end

    test "refuses everything when nothing is running" do
      handler = Stub.stub(:which_releases, [{~c"sample", ~c"1.2.3", [], :unpacked}])

      assert Commands.running("1.2.3", handler) ==
               {:error, "1.2.3 is not the running release. No release is running."}
    end
  end

  describe "commit/2" do
    test "reports what committing means" do
      handler = Stub.stub(:make_permanent, :ok)

      assert Commands.commit("1.2.3", handler) ==
               {:ok, ["Committed 1.2.3. System restarts will now boot into this version."]}

      assert Stub.calls(:make_permanent) == [[~c"1.2.3"]]
    end

    test "reports a failure to commit" do
      handler = Stub.stub(:make_permanent, {:error, {:bad_status, :unpacked}})

      assert {:error, message} = Commands.commit("1.2.3", handler)
      assert message =~ "Commit of 1.2.3 failed."
      assert message =~ "bad_status"
    end
  end

  describe "remove/2" do
    test "reports the version that was removed" do
      handler = Stub.stub(:remove_release, :ok)

      assert Commands.remove("1.2.3", handler) == {:ok, ["Removed 1.2.3."]}
      assert Stub.calls(:remove_release) == [[~c"1.2.3"]]
    end

    test "reports a failure to remove" do
      handler = Stub.stub(:remove_release, {:error, {:no_such_release, ~c"1.2.3"}})

      assert {:error, message} = Commands.remove("1.2.3", handler)
      assert message =~ "Removal of 1.2.3 failed."
      assert message =~ "no_such_release"
    end
  end

  describe "releases/1" do
    test "lines the statuses up past the longest version" do
      handler =
        Stub.stub(:which_releases, [
          {~c"sample", ~c"0.1.10", [], :permanent},
          {~c"sample", ~c"0.1.9", [], :old}
        ])

      assert Commands.releases(handler) == {:ok, ["0.1.10  permanent", "0.1.9   old"]}
    end

    test "reports nothing at all when no release is installed" do
      handler = Stub.stub(:which_releases, [])

      assert Commands.releases(handler) == {:ok, []}
    end
  end

  defp write_build_config(dir, config) do
    File.write!(
      Path.join(dir, "build.config"),
      :io_lib.format(~c"%% coding: utf-8~n~tp.~n", [config])
    )
  end

  defp read_sys_config(dir) do
    assert {:ok, [config]} = :file.consult(to_charlist(Path.join(dir, "sys.config")))
    config
  end
end
