defmodule Castle.CommandsTest do
  use ExUnit.Case, async: true

  alias Castle.Commands
  alias Castle.DeploymentStub
  alias Castle.InitStub
  alias Castle.PeerStub
  alias Castle.ReleaseHandlerStub, as: Stub

  describe "materialise/3" do
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
      assert message =~ "This system cannot be upgraded: 1.2.3 is running from a release record"
      assert message =~ "names no applications"
      assert message =~ "running its old code"
      assert message =~ "make sure the RELEASES file :release_handler reads is"

      # The remedy names the state the file has to be in, not the reason the
      # record was synthesised. A bare "restart" loops forever on a file that is
      # present and unreadable, because the hook that creates it is guarded on its
      # absence - and a case analysis of the cause, which is what this said first,
      # has no advice at all for a file that was absent at boot and has been
      # created readably since, where a plain restart is all that is needed.
      assert message =~ "Absent, or accepted, is what a restart needs."
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
               {:error, "This system cannot be upgraded: no release is running."}
    end
  end

  describe "unpack/3" do
    test "reports the version that was unpacked" do
      handler = real_record(:unpack_release, {:ok, ~c"1.2.3"})

      assert Commands.unpack("sample-1.2.3", handler) == {:ok, ["Unpacked 1.2.3 ok"]}
      assert Stub.calls(:unpack_release) == [[~c"sample-1.2.3"]]
    end

    test "reports a failure to unpack" do
      handler = real_record(:unpack_release, {:error, {:no_such_file, ~c"sample-1.2.3.tar.gz"}})

      assert {:error, message} = Commands.unpack("sample-1.2.3", handler)
      assert message =~ "Failed to unpack sample-1.2.3."
      assert message =~ "no_such_file"
    end

    test "refuses a system running on a record OTP synthesised, without unpacking" do
      # The handler is ready to unpack and must not be asked: unpack_release/1
      # ends in write_releases/3, so an unpack here would put the synthesised
      # record into RELEASES, and the next boot would read it back - which takes
      # away the restart the refusal names as the remedy, because
      # make_releases/3 does nothing once the file exists.
      handler = synthesised_record(:unpack_release, {:ok, ~c"1.2.3"})

      assert {:error, message} = Commands.unpack("sample-1.2.3", handler)
      assert message =~ "Cannot unpack sample-1.2.3: 1.2.2 is running from a release record"
      assert message =~ "the system has to be restarted"
      assert Stub.calls(:unpack_release) == []
    end

    test "asks the running node, in the call that does the unpacking" do
      # Which is the whole point: the check cannot be something a caller asks in
      # a call of its own, because the node that answers and the node that acts
      # need not be the same one. One call, one record, one decision.
      handler = real_record(:unpack_release, {:ok, ~c"1.2.3"})

      assert {:ok, _} = Commands.unpack("sample-1.2.3", handler)
      assert Stub.calls(:which_releases) == [[]]
    end
  end

  describe "install/4" do
    @tag :tmp_dir
    test "reports the version change", %{tmp_dir: dir} do
      handler = real_record(:install_release, {:ok, ~c"1.2.2", ~c"upgrade"})

      assert Commands.install("1.2.3", dir, handler) ==
               {:ok, ["Now running 1.2.3 (previously 1.2.2)."]}

      assert Stub.calls(:install_release) == [[~c"1.2.3"]]
    end

    @tag :tmp_dir
    test "reports a restart of the emulator as the success it is", %{tmp_dir: dir} do
      handler = real_record(:install_release, {:continue_after_restart, ~c"1.2.2", ~c"upgrade"})

      assert {:ok, lines} = Commands.install("1.2.3", dir, handler)
      assert Enum.join(lines, " ") =~ "Restarting to install 1.2.3 (previously 1.2.2)."
    end

    @tag :tmp_dir
    test "reports a failure to install", %{tmp_dir: dir} do
      handler = real_record(:install_release, {:error, {:no_such_release, ~c"1.2.3"}})

      assert {:error, message} = Commands.install("1.2.3", dir, handler)
      assert message =~ "Install of 1.2.3 failed."
      assert message =~ "no_such_release"
    end

    @tag :tmp_dir
    test "reports a result it does not recognise", %{tmp_dir: dir} do
      handler = real_record(:install_release, {:whatever, ~c"1.2.2"})

      assert {:error, message} = Commands.install("1.2.3", dir, handler)
      assert message =~ "Install of 1.2.3 returned an unexpected result."
    end

    @tag :tmp_dir
    test "refuses a system running on a record OTP synthesised, without installing",
         %{tmp_dir: dir} do
      # The mutation is install_release/1, and the handler here is ready to
      # perform it and report success - which is exactly what such an install
      # would do while leaving applications on their old code. So the refusal has
      # to come first, and nothing may reach the handler.
      handler = synthesised_record(:install_release, {:ok, ~c"1.2.2", ~c"upgrade"})

      assert {:error, message} = Commands.install("1.2.3", dir, handler)
      assert message =~ "Cannot install 1.2.3: 1.2.2 is running from a release record"
      assert message =~ "running its old code"
      assert message =~ "the system has to be restarted"
      assert Stub.calls(:install_release) == []
    end

    @tag :tmp_dir
    test "asks the running node once, in the call that does the installing", %{tmp_dir: dir} do
      # Once, and not twice: the record check and the classification that decides
      # whether to arm the restart marker are both about the release the system is
      # running, and two calls to which_releases/0 are two moments. That is the
      # same reason the check lives inside the operation at all.
      handler = real_record(:install_release, {:ok, ~c"1.2.2", ~c"upgrade"})

      assert {:ok, _} = Commands.install("1.2.3", dir, handler)
      assert Stub.calls(:which_releases) == [[]]
    end
  end

  # The marker the launcher's env.sh fragment consumes on the next start, and
  # which - together with the `new_start_erl.data` release_handler writes - is
  # what makes a reboot boot the version that was installed rather than the one
  # `releases/start_erl.data` still names.
  #
  # It is armed from the relup, before install_release/1 is asked for anything,
  # because the reply cannot answer the question: a one-stage restart is replied
  # to with the same `{ok, Vsn, Descr}` a completed hot upgrade is, and the reboot
  # has already been asked for by then.
  describe "the restart marker" do
    @tag :tmp_dir
    test "is armed for a one-stage restart transition", %{tmp_dir: dir} do
      relup!(dir, "1.2.3", [{~c"1.2.2", [], [:restart_emulator]}], [])
      handler = real_record(:install_release, {:ok, ~c"1.2.2", ~c"upgrade"})

      assert {:ok, lines} = Commands.install("1.2.3", dir, handler)
      assert File.read!(marker(dir)) == "1.2.3\n"

      # And the report says what happened rather than what a hot upgrade's reply
      # would have suggested: the same {ok, ...} means the emulator is going down.
      report = Enum.join(lines, " ")
      assert report =~ "Installed 1.2.3 (previously 1.2.2). The emulator is restarting."
      assert report =~ "1.2.3 is provisional until it is committed"
      assert report =~ "1.2.2 is still the version an ordinary restart boots"
      refute report =~ "Now running"
    end

    @tag :tmp_dir
    test "is armed from the from-release's relup for a downgrade", %{tmp_dir: dir} do
      # do_get_rh_script/4 looks for the from-version in the target's relup and,
      # failing that, for the to-version in the from-release's downgrade section.
      # A relup for 1.2.3 that has no entry for 1.2.2 and a relup for 1.2.2 whose
      # downgrade section names 1.2.1 is the second case.
      relup!(dir, "1.2.3", [], [])
      relup!(dir, "1.2.2", [], [{~c"1.2.1", [], [:restart_emulator]}])
      handler = real_record(:install_release, {:ok, ~c"1.2.2", ~c"downgrade"})

      assert {:ok, _} = Commands.install("1.2.1", dir, handler)
      assert File.read!(marker(dir)) == "1.2.1\n"
    end

    @tag :tmp_dir
    test "is not armed for a hot upgrade", %{tmp_dir: dir} do
      relup!(dir, "1.2.3", [{~c"1.2.2", [], [{:apply, {:m, :f, []}}]}], [])
      handler = real_record(:install_release, {:ok, ~c"1.2.2", ~c"upgrade"})

      assert {:ok, ["Now running 1.2.3 (previously 1.2.2)."]} =
               Commands.install("1.2.3", dir, handler)

      refute File.exists?(marker(dir))
    end

    @tag :tmp_dir
    test "is not armed for the two-stage restart", %{tmp_dir: dir} do
      # restart_new_emulator at the head of the script is the transition that
      # boots a hybrid temporary release, and the marker release_handler writes
      # for it names `__new_emulator__<current>` - a version directory with a
      # start.boot and a sys.config in it and none of the launcher's own files.
      # There is nothing there for the launcher to boot, so arming would point it
      # at a version it cannot start.
      relup!(dir, "1.2.3", [{~c"1.2.2", [], [:restart_new_emulator, {:apply, {:m, :f, []}}]}], [])
      handler = real_record(:install_release, {:continue_after_restart, ~c"1.2.2", ~c"upgrade"})

      assert {:ok, _} = Commands.install("1.2.3", dir, handler)
      refute File.exists?(marker(dir))
    end

    @tag :tmp_dir
    test "is not armed when there is no relup to classify from", %{tmp_dir: dir} do
      # do_get_rh_script/4 throws no_matching_relup for this, so the install fails
      # and says so. Nothing here has to report it, and nothing may arm on a guess.
      handler =
        real_record(:install_release, {:error, {:no_matching_relup, ~c"1.2.3", ~c"1.2.2"}})

      assert {:error, _} = Commands.install("1.2.3", dir, handler)
      refute File.exists?(marker(dir))
    end

    @tag :tmp_dir
    test "is cleared when the install fails", %{tmp_dir: dir} do
      # The case that makes the marker necessary in the first place, seen from the
      # other side: prepare_restart_new_emulator/7 writes new_start_erl.data
      # before it can fail, and nothing removes it. If the marker survived a
      # failure the two would agree, and the next restart of the system would boot
      # a version that was never installed.
      relup!(dir, "1.2.3", [{~c"1.2.2", [], [:restart_emulator]}], [])
      handler = real_record(:install_release, {:error, {:bad_relup_file, ~c"relup"}})

      assert {:error, message} = Commands.install("1.2.3", dir, handler)
      assert message =~ "Install of 1.2.3 failed."
      refute File.exists?(marker(dir))
    end

    @tag :tmp_dir
    test "is cleared when the install answers something unrecognised", %{tmp_dir: dir} do
      relup!(dir, "1.2.3", [{~c"1.2.2", [], [:restart_emulator]}], [])
      handler = real_record(:install_release, {:whatever, ~c"1.2.2"})

      assert {:error, _} = Commands.install("1.2.3", dir, handler)
      refute File.exists?(marker(dir))
    end

    @tag :tmp_dir
    test "refuses the install when it cannot be armed", %{tmp_dir: dir} do
      # A directory at the marker's name is what makes this deterministic; what it
      # stands for is a releases directory that cannot be written to. Going ahead
      # would reboot the system and come back on the version start_erl.data names,
      # losing the upgrade with nothing saying so - so the install is refused
      # before install_release/1 is asked for anything, which is the line
      # everything else here is on the right side of too.
      relup!(dir, "1.2.3", [{~c"1.2.2", [], [:restart_emulator]}], [])
      File.mkdir!(marker(dir))
      handler = real_record(:install_release, {:ok, ~c"1.2.2", ~c"upgrade"})

      assert {:error, message} = Commands.install("1.2.3", dir, handler)
      assert message =~ "Cannot install 1.2.3: the upgrade to 1.2.3 restarts the emulator"
      assert message =~ Path.join(dir, "castle-restart-pending")
      assert message =~ "losing the upgrade"
      assert Stub.calls(:install_release) == []
    end

    @tag :tmp_dir
    test "is not armed for a deployment the ERTS guard refuses", %{tmp_dir: dir} do
      relup!(dir, "1.2.3", [{~c"1.2.2", [], [:restart_emulator]}], [])
      handler = real_record(:install_release, {:ok, ~c"1.2.2", ~c"upgrade"})

      assert {:error, _} = Commands.install("1.2.3", dir, handler, erts_less())
      refute File.exists?(marker(dir))
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

  describe "commit/3" do
    test "reports what committing means" do
      handler = Stub.stub(:make_permanent, :ok)

      assert Commands.commit("1.2.3", handler) ==
               {:ok, ["Committed 1.2.3. System restarts will now boot into this version."]}

      assert Stub.calls(:make_permanent) == [[~c"1.2.3"]]
    end

    test "commits without asking whether the system can be upgraded from" do
      # Deliberate, and not an omission. make_permanent/1 cannot write the
      # synthesised record back - do_make_permanent/2 returns early for a release
      # that is already permanent and errors for every other status - while a
      # refusal here would strand a version installed while the record was still
      # good, leaving the previous release to come back at the next restart.
      handler = synthesised_record(:make_permanent, :ok)

      assert {:ok, _} = Commands.commit("1.2.3", handler)
      assert Stub.calls(:which_releases) == []
    end

    test "reports a failure to commit" do
      handler = Stub.stub(:make_permanent, {:error, {:bad_status, :unpacked}})

      assert {:error, message} = Commands.commit("1.2.3", handler)
      assert message =~ "Commit of 1.2.3 failed."
      assert message =~ "bad_status"
    end
  end

  describe "remove/3" do
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

  # A release built with `include_erts: false` runs the system emulator, so
  # `code:root_dir()` - and therefore every path `:release_handler` resolves - is
  # the Erlang installation rather than the deployment. Every operation that
  # would act on that tree has to refuse before it acts, and each of these
  # registers the reply that would have had it succeed, so what is asserted is
  # ordering: the handler stands ready and is never asked.
  #
  # The state cannot be reached without substituting the guard's input, because
  # `mix test` has no `RELEASE_ROOT` and the guard is inert without one. The
  # comparison itself is not substituted - `Castle.DeploymentStub` answers the
  # two roots and `Castle.Commands` does the rest - so these exercise the real
  # rule.
  describe "the ERTS guard" do
    test "refuses to unpack, without unpacking" do
      handler = real_record(:unpack_release, {:ok, ~c"1.2.3"})

      assert {:error, message} = Commands.unpack("sample-1.2.3", handler, erts_less())

      assert message =~
               "Cannot unpack sample-1.2.3: the deployment and the emulator's root are different directories"

      # Both directories are named, so that the operator can see which two the
      # guard compared rather than being told only that they differ.
      assert message =~ System.tmp_dir!()
      assert message =~ to_string(:code.root_dir())
      assert message =~ "cannot be upgraded by Castle"
      assert Stub.calls(:unpack_release) == []

      # And ahead of the record check, which on such a deployment is asking about
      # the Erlang installation's own release record and so cannot see anything
      # wrong. The refusal has to name the reason that is true.
      assert Stub.calls(:which_releases) == []
    end

    @tag :tmp_dir
    test "refuses to install, without installing", %{tmp_dir: dir} do
      handler = real_record(:install_release, {:ok, ~c"1.2.2", ~c"upgrade"})

      assert {:error, message} = Commands.install("1.2.3", dir, handler, erts_less())

      assert message =~
               "Cannot install 1.2.3: the deployment and the emulator's root are different directories"

      assert Stub.calls(:install_release) == []
      assert Stub.calls(:which_releases) == []
    end

    test "refuses to commit, without committing" do
      handler = Stub.stub(:make_permanent, :ok)

      assert {:error, message} = Commands.commit("1.2.3", handler, erts_less())

      assert message =~
               "Cannot commit 1.2.3: the deployment and the emulator's root are different directories"

      assert Stub.calls(:make_permanent) == []
    end

    test "refuses to remove, without removing" do
      # The one with the most to lose: remove_release/1 deletes, and every path
      # it deletes is resolved against code:root_dir() - so on this deployment it
      # is the Erlang installation's directories it would be asked to take away.
      handler = Stub.stub(:remove_release, :ok)

      assert {:error, message} = Commands.remove("1.2.3", handler, erts_less())

      assert message =~
               "Cannot remove 1.2.3: the deployment and the emulator's root are different directories"

      assert Stub.calls(:remove_release) == []
    end

    @tag :tmp_dir
    test "refuses to configure a version, without starting a peer", %{tmp_dir: dir} do
      # The version directory is real and has something in it, so the refusal
      # cannot be the one about a release that was never unpacked.
      unpacked(dir)
      peer = PeerStub.stub({:ok, []})

      assert {:error, message} = Commands.materialise(dir, peer, erts_less())
      assert message =~ "the deployment and the emulator's root are different directories"
      assert PeerStub.calls() == []
    end

    test "leaves the read-only diagnostics alone" do
      # An operator whose deployment has just been refused needs these to work in
      # order to make sense of the refusal, so neither takes the guard - there is
      # no deployment to hand them. Gating a diagnostic on the condition it
      # diagnoses leaves nothing to ask.
      handler =
        Stub.stub(:which_releases, [
          {~c"sample", ~c"1.2.3", [~c"kernel-10.5", ~c"stdlib-7.2"], :permanent}
        ])

      assert Commands.upgradable(handler) == {:ok, []}
      assert Commands.releases(handler) == {:ok, ["1.2.3  permanent"]}
    end

    test "is inert when nothing says where the deployment is" do
      # Which is what makes it safe to put in front of every mutating operation:
      # only a launcher `mix release` generated exports RELEASE_ROOT, so outside
      # a release there is nothing to compare and nothing is refused. An empty
      # value names no directory and is no evidence either.
      handler = Stub.stub(:remove_release, :ok)

      for release_root <- [nil, ""] do
        deployment = DeploymentStub.stub(release_root, "/usr/lib/erlang")

        assert Commands.remove("1.2.3", handler, deployment) == {:ok, ["Removed 1.2.3."]}
      end
    end

    test "is inert when the deployment is where the emulator's root is" do
      handler = Stub.stub(:remove_release, :ok)

      # Spelled the same way, and spelled differently for the same directory: a
      # trailing separator and a doubled one are what Path.expand/1 settles, and
      # an ordinary release has the two strings identical anyway - both come from
      # `pwd -P`, in the launcher and in the erl shim two levels below it.
      for release_root <- ["/opt/app", "/opt/app/", "/opt//app"] do
        deployment = DeploymentStub.stub(release_root, "/opt/app")

        assert Commands.remove("1.2.3", handler, deployment) == {:ok, ["Removed 1.2.3."]}
      end
    end

    @tag :tmp_dir
    test "is inert when the two spell one directory through a symlink", %{tmp_dir: dir} do
      # A deployment with a `current` symlink is ordinary, and refusing one that
      # does bring its own ERTS is the one failure of this guard that an operator
      # cannot work around - so where the strings disagree the filesystem is
      # asked, and it is the same directory.
      root = Path.join(dir, "1.2.3")
      link = Path.join(dir, "current")
      File.mkdir!(root)
      File.ln_s!(root, link)

      handler = Stub.stub(:remove_release, :ok)
      deployment = DeploymentStub.stub(link, root)

      assert Path.expand(link) != Path.expand(root)
      assert Commands.remove("1.2.3", handler, deployment) == {:ok, ["Removed 1.2.3."]}
    end
  end

  # What a node reports once its boot script has run to the end.
  defp booted, do: InitStub.stub({:starting, :started})

  # A handler whose running release was read from a RELEASES file, so it names
  # applications and the check unpack/3 and install/3 make passes, with `fun`
  # answering `reply`.
  defp real_record(fun, reply) do
    Stub.stub(:which_releases, [
      {~c"sample", ~c"1.2.2", [~c"kernel-10.5", ~c"stdlib-7.2"], :permanent}
    ])

    Stub.stub(fun, reply)
  end

  # The same, for a node whose record release_handler synthesised because it
  # could not read RELEASES: the application list is empty. `fun` is registered
  # with the reply it would have given, so that asserting it was never called
  # says something about ordering rather than about an unstubbed function
  # raising - the handler stands ready to succeed and must not be asked.
  defp synthesised_record(fun, reply) do
    Stub.stub(:which_releases, [{~c"sample", ~c"1.2.2", [], :permanent}])
    Stub.stub(fun, reply)
  end

  # A deployment that did not bring its own ERTS: the launcher exported a root
  # of its own and the emulator's is elsewhere.
  #
  # Both have to be directories that exist and differ, so that the comparison is
  # actually made and comes back `:different`. Two paths that are merely absent
  # produce the *indeterminate* refusal instead - a failed lookup is not evidence
  # of a difference - so a fixture built from names nothing has created would
  # assert the wrong message while looking like it asserted the right one.
  defp erts_less, do: DeploymentStub.stub(System.tmp_dir!(), to_string(:code.root_dir()))

  # Enough of an unpacked version directory for `materialise/3`: what is in it is
  # the peer's business, and the peer is a stub here. Everything it would look
  # for is covered against a real one in `Castle.PeerTest`.
  defp unpacked(dir), do: File.write!(Path.join(dir, "sys.config"), "[].\n")

  defp marker(rel_dir), do: Path.join(rel_dir, "castle-restart-pending")

  # A relup where `release_handler` reads one: `releases/<vsn>/relup`, holding a
  # single `{Vsn, Ups, Downs}` term. Written as a term rather than as text so that
  # what the classification consults is what `:file.consult/1` gives it, which is
  # the same thing `do_get_rh_script/4` will be given a moment later.
  defp relup!(rel_dir, vsn, ups, downs) do
    dir = Path.join(rel_dir, vsn)
    File.mkdir_p!(dir)

    plan = {to_charlist(vsn), ups, downs}
    File.write!(Path.join(dir, "relup"), :io_lib.format(~c"~tp.~n", [plan]))
  end
end
