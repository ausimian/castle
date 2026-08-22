defmodule Castle.CommandsTest do
  use ExUnit.Case, async: true

  alias Castle.Commands
  alias Castle.InitStub
  alias Castle.PeerStub
  alias Castle.ReleaseHandlerStub, as: Stub

  describe "materialise/2" do
    @tag :tmp_dir
    test "hands an unpacked version to the peer", %{tmp_dir: dir} do
      unpacked(dir)

      assert Commands.materialise(dir, PeerStub.stub({:ok, []})) == {:ok, []}
      assert PeerStub.calls() == [dir]
    end

    @tag :tmp_dir
    test "reports what the peer could not do", %{tmp_dir: dir} do
      unpacked(dir)
      peer = PeerStub.stub({:error, "DATABASE_URL is not set"})

      assert Commands.materialise(dir, peer) == {:error, "DATABASE_URL is not set"}
    end

    @tag :tmp_dir
    test "leaves nothing for install_release/1 to be given", %{tmp_dir: dir} do
      # The order `Castle.install/1` composes these in, with the release handler
      # ready to accept an install that must not be asked for. Everything able
      # to refuse belongs on this side of the mutation, and a configuration that
      # could not be materialised is the whole of what this adds to that list.
      unpacked(dir)
      peer = PeerStub.stub({:error, "the compile environment does not agree"})
      Stub.stub(:install_release, {:ok, ~c"1.2.2", ~c"upgrade"})

      assert {:error, message} = Commands.materialise(dir, peer)
      assert message =~ "the compile environment does not agree"
      assert Stub.calls(:install_release) == []
    end

    @tag :tmp_dir
    test "reports a version that has not been unpacked", %{tmp_dir: dir} do
      # The peer stub has no registered reply, so it raises if it is reached.
      missing = Path.join(dir, "9.9.9")

      assert {:error, message} = Commands.materialise(missing, PeerStub)
      assert message =~ "Cannot configure 9.9.9: #{missing} does not exist."
      assert message =~ "Unpack the release first"
      assert PeerStub.calls() == []
    end

    @tag :tmp_dir
    test "reports a version directory with nothing in it", %{tmp_dir: dir} do
      # Which is not the same thing as a version that was unpacked and then had
      # its configuration removed - the peer names the file that is missing for
      # that - so it does not claim to be, and it does say what to do about it.
      empty = Path.join(dir, "9.9.9")
      File.mkdir!(empty)

      assert {:error, message} = Commands.materialise(empty, PeerStub)
      assert message =~ "Cannot configure 9.9.9: #{empty} is empty."
      assert message =~ "Unpack the release first"
      assert PeerStub.calls() == []
    end
  end

  describe "upgradable/1" do
    test "confirms a system whose release record was read from RELEASES" do
      handler =
        Stub.stub(:which_releases, [
          {~c"sample", ~c"1.2.3", [~c"kernel-10.5", ~c"stdlib-7.2"], :permanent}
        ])

      assert Commands.upgradable(handler) == {:ok, []}
    end

    test "refuses a system running on a record OTP synthesised" do
      # release_handler could not read RELEASES when it started, so it built a
      # record out of the boot script's name and version, whose libs field is
      # empty - and mk_lib_name([]) is [], which no real record reports.
      handler = Stub.stub(:which_releases, [{~c"sample", ~c"1.2.3", [], :permanent}])

      assert {:error, message} = Commands.upgradable(handler)
      assert message =~ "1.2.3 is running from a release record OTP built from the boot script"
      assert message =~ "names no applications"
      assert message =~ "running its old code"
      assert message =~ "Restart the system before upgrading it"
    end

    test "asks the release the system is running, and not another one" do
      # The synthesised record is the permanent one, and an install leaves its
      # target current - so which release is asked has to be the running one,
      # the way running/3 selects it, or a system that has already upgraded once
      # would be refused for the state of the record it came from.
      handler =
        Stub.stub(:which_releases, [
          {~c"sample", ~c"1.2.3", [~c"kernel-10.5"], :current},
          {~c"sample", ~c"1.2.2", [], :permanent}
        ])

      assert Commands.upgradable(handler) == {:ok, []}
    end

    test "refuses a system with no release running at all" do
      handler = Stub.stub(:which_releases, [{~c"sample", ~c"1.2.3", [], :unpacked}])

      assert Commands.upgradable(handler) ==
               {:error, "No release is running, so this system cannot be upgraded."}
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

  describe "running/3" do
    test "confirms the version an install has made current" do
      handler =
        Stub.stub(:which_releases, [
          {~c"sample", ~c"1.2.3", [], :current},
          {~c"sample", ~c"1.2.2", [], :permanent}
        ])

      assert Commands.running("1.2.3", handler, booted()) == {:ok, []}
    end

    test "confirms the version a commit has made permanent" do
      handler =
        Stub.stub(:which_releases, [
          {~c"sample", ~c"1.2.3", [], :permanent},
          {~c"sample", ~c"1.2.2", [], :old}
        ])

      assert Commands.running("1.2.3", handler, booted()) == {:ok, []}
    end

    test "refuses the permanent version while another one is current" do
      # Committing 1.2.2 and then installing 1.2.3 leaves 1.2.2 permanent, but
      # it is 1.2.3 that is running.
      handler =
        Stub.stub(:which_releases, [
          {~c"sample", ~c"1.2.3", [], :current},
          {~c"sample", ~c"1.2.2", [], :permanent}
        ])

      assert Commands.running("1.2.2", handler, booted()) ==
               {:error, "1.2.2 is not the running release. 1.2.3 is."}
    end

    test "refuses a version left unpacked by a continuation that rolled back" do
      handler =
        Stub.stub(:which_releases, [
          {~c"sample", ~c"1.2.3", [], :unpacked},
          {~c"sample", ~c"1.2.2", [], :permanent}
        ])

      assert Commands.running("1.2.3", handler, booted()) ==
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

      assert Commands.running("1.2.3", handler, booted()) ==
               {:error, "1.2.3 is not the running release. 1.2.2 is."}
    end

    test "refuses a version the system has never heard of" do
      handler = Stub.stub(:which_releases, [{~c"sample", ~c"1.2.2", [], :permanent}])

      assert Commands.running("9.9.9", handler, booted()) ==
               {:error, "9.9.9 is not the running release. 1.2.2 is."}
    end

    test "refuses a version whose boot has not finished" do
      # A node that restarted into the new version answers rpc from the moment
      # kernel is up, and release_handler has made the version current by the
      # time sasl has started - so it can be seen like this, with applications
      # still to start and the boot still able to fail back to the release that
      # was permanent before.
      handler = Stub.stub(:which_releases, [{~c"sample", ~c"1.2.3", [], :current}])
      init = InitStub.stub({:starting, :applications_loaded})

      assert Commands.running("1.2.3", handler, init) ==
               {:error,
                "1.2.3 is the running release but has not finished booting: :applications_loaded."}
    end

    test "confirms that same version once its boot has finished" do
      handler = Stub.stub(:which_releases, [{~c"sample", ~c"1.2.3", [], :current}])

      # The internal status says nothing: it stays :starting for as long as the
      # boot process lives, which is the whole life of a release started by its
      # boot script. Only the provided status, which the script's last
      # {progress, _} sets, answers the question.
      for status <- [{:starting, :started}, {:started, :started}] do
        assert Commands.running("1.2.3", handler, InitStub.stub(status)) == {:ok, []}
      end
    end

    test "refuses everything when nothing is running" do
      handler = Stub.stub(:which_releases, [{~c"sample", ~c"1.2.3", [], :unpacked}])

      assert Commands.running("1.2.3", handler, booted()) ==
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

  # What a node reports once its boot script has run to the end.
  defp booted, do: InitStub.stub({:starting, :started})

  # Enough of an unpacked version directory for `materialise/2`: what is in it is
  # the peer's business, and the peer is a stub here. Everything it would look
  # for is covered against a real one in `Castle.PeerTest`.
  defp unpacked(dir), do: File.write!(Path.join(dir, "sys.config"), "[].\n")
end
