defmodule Castle.CommandsTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

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
      # `materialise/3` on its own, with the release handler ready to accept an
      # install that must not be asked for. Everything able to refuse belongs on
      # this side of the mutation, and a configuration that could not be
      # materialised is the whole of what this adds to that list.
      #
      # This is the step's own contract rather than an ordering claim about
      # `install/5`: the ordering inside the install is asserted where the install
      # is, by the marker and configuration cases below. `Castle.commit/1` is the
      # caller that still composes this in front of an operation.
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

  describe "install/5" do
    @tag :tmp_dir
    test "reports the version change", %{tmp_dir: dir} do
      handler = real_record(:install_release, {:ok, ~c"1.2.2", ~c"upgrade"})

      assert Commands.install("1.2.3", dir, handler, configured(dir)) ==
               {:ok, ["Now running 1.2.3 (previously 1.2.2)."]}

      assert Stub.calls(:install_release) == [[~c"1.2.3"]]
    end

    @tag :tmp_dir
    test "reports a restart of the emulator as the success it is", %{tmp_dir: dir} do
      handler = real_record(:install_release, {:continue_after_restart, ~c"1.2.2", ~c"upgrade"})

      assert {:ok, lines} = Commands.install("1.2.3", dir, handler, configured(dir))
      assert Enum.join(lines, " ") =~ "Restarting to install 1.2.3 (previously 1.2.2)."
    end

    @tag :tmp_dir
    test "reports a failure to install", %{tmp_dir: dir} do
      handler = real_record(:install_release, {:error, {:no_such_release, ~c"1.2.3"}})

      assert {:error, message} = Commands.install("1.2.3", dir, handler, configured(dir))
      assert message =~ "Install of 1.2.3 failed."
      assert message =~ "no_such_release"
    end

    @tag :tmp_dir
    test "reports a result it does not recognise", %{tmp_dir: dir} do
      handler = real_record(:install_release, {:whatever, ~c"1.2.2"})

      assert {:error, message} = Commands.install("1.2.3", dir, handler, configured(dir))
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

      assert {:error, message} = Commands.install("1.2.3", dir, handler, configured(dir))
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

      assert {:ok, _} = Commands.install("1.2.3", dir, handler, configured(dir))
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

      assert {:ok, lines} = Commands.install("1.2.3", dir, handler, configured(dir))

      # The version on the first line, which is all the hook reads, and the
      # attempt on the second, which is what makes the file this install's rather
      # than this version's. Asserted as two lines rather than as a whole string
      # so that the attempt stays opaque here: what it is made of is
      # `Castle.Commands.attempt/0`'s business, and the only property this suite
      # rests on is that it is there and that it differs between attempts.
      assert [vsn, attempt] = File.read!(marker(dir)) |> String.split("\n", trim: true)
      assert vsn == "1.2.3"
      assert attempt != ""

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

      assert {:ok, _} = Commands.install("1.2.1", dir, handler, configured(dir, "1.2.1"))
      assert armed_version(dir) == "1.2.1"
    end

    @tag :tmp_dir
    test "is not armed for a hot upgrade", %{tmp_dir: dir} do
      relup!(dir, "1.2.3", [{~c"1.2.2", [], [{:apply, {:m, :f, []}}]}], [])
      handler = real_record(:install_release, {:ok, ~c"1.2.2", ~c"upgrade"})

      assert {:ok, ["Now running 1.2.3 (previously 1.2.2)."]} =
               Commands.install("1.2.3", dir, handler, configured(dir))

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

      assert {:ok, _} = Commands.install("1.2.3", dir, handler, configured(dir))
      refute File.exists?(marker(dir))
    end

    @tag :tmp_dir
    test "is not armed when there is no relup to classify from", %{tmp_dir: dir} do
      # do_get_rh_script/4 throws no_matching_relup for this, so the install fails
      # and says so. Nothing here has to report it, and nothing may arm on a guess.
      handler =
        real_record(:install_release, {:error, {:no_matching_relup, ~c"1.2.3", ~c"1.2.2"}})

      assert {:error, _} = Commands.install("1.2.3", dir, handler, configured(dir))
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

      assert {:error, message} = Commands.install("1.2.3", dir, handler, configured(dir))
      assert message =~ "Install of 1.2.3 failed."
      refute File.exists?(marker(dir))
    end

    @tag :tmp_dir
    test "is cleared when the install answers something unrecognised", %{tmp_dir: dir} do
      relup!(dir, "1.2.3", [{~c"1.2.2", [], [:restart_emulator]}], [])
      handler = real_record(:install_release, {:whatever, ~c"1.2.2"})

      assert {:error, _} = Commands.install("1.2.3", dir, handler, configured(dir))
      refute File.exists?(marker(dir))
    end

    @tag :tmp_dir
    test "refuses the install when something else holds the name", %{tmp_dir: dir} do
      # A directory at the marker's name is what makes this deterministic; a
      # fixture here may not turn on a mode that root or a filesystem can ignore.
      # Going ahead would reboot the system and come back on the version
      # start_erl.data names, losing the upgrade with nothing saying so - so the
      # install is refused before install_release/1 is asked for anything, which
      # is the line everything else here is on the right side of too.
      relup!(dir, "1.2.3", [{~c"1.2.2", [], [:restart_emulator]}], [])
      File.mkdir!(marker(dir))
      handler = real_record(:install_release, {:ok, ~c"1.2.2", ~c"upgrade"})

      assert {:error, message} = Commands.install("1.2.3", dir, handler, configured(dir))
      assert message =~ "Cannot install 1.2.3: #{marker(dir)}"
      assert message =~ "there is already a directory at that path"
      assert Stub.calls(:install_release) == []
    end

    @tag :tmp_dir
    test "refuses the install when it cannot be armed", %{tmp_dir: dir} do
      # The other half of that: the marker's name is free, and OTP's file - which
      # has to be cleared before the marker is armed - cannot be got rid of. A
      # directory at *its* name is the deterministic stand-in for a releases
      # directory nothing may write to, and the refusal has to come before
      # install_release/1 for the same reason.
      relup!(dir, "1.2.3", [{~c"1.2.2", [], [:restart_emulator]}], [])
      File.mkdir!(provisional(dir))
      handler = real_record(:install_release, {:ok, ~c"1.2.2", ~c"upgrade"})

      assert {:error, message} = Commands.install("1.2.3", dir, handler, configured(dir))
      assert message =~ "Cannot install 1.2.3: the upgrade to 1.2.3 restarts the emulator"
      assert message =~ provisional(dir)
      assert message =~ "would pair with the marker this install is about to arm"
      refute File.exists?(marker(dir))
      assert Stub.calls(:install_release) == []
    end

    @tag :tmp_dir
    test "is not armed for a deployment the ERTS guard refuses", %{tmp_dir: dir} do
      relup!(dir, "1.2.3", [{~c"1.2.2", [], [:restart_emulator]}], [])
      handler = real_record(:install_release, {:ok, ~c"1.2.2", ~c"upgrade"})

      assert {:error, _} = Commands.install("1.2.3", dir, handler, PeerStub, erts_less())
      refute File.exists?(marker(dir))
    end

    @tag :tmp_dir
    test "leaves nothing of its own in the releases directory", %{tmp_dir: dir} do
      # The marker is staged in a working directory of its own and hard-linked
      # into place - the way `Castle.Peer` publishes `sys.config.pristine`, and
      # for the same reasons: a link publishes a file that is already complete,
      # and refuses rather than replaces. What that must not leave behind is the
      # staging, so the only `castle-` name here afterwards is the marker itself.
      relup!(dir, "1.2.3", [{~c"1.2.2", [], [:restart_emulator]}], [])
      handler = real_record(:install_release, {:ok, ~c"1.2.2", ~c"upgrade"})

      assert {:ok, _} = Commands.install("1.2.3", dir, handler, configured(dir))
      assert Path.wildcard(Path.join(dir, "castle-*")) == [marker(dir)]
    end

    @tag :tmp_dir
    test "refuses the install when something with no ordinary name holds it",
         %{tmp_dir: dir} do
      # The last of `File.lstat/1`'s five types, and the one whose atom is not a
      # noun: a named pipe, a socket, anything the emulator has no name for all
      # come back as `:other`, and the refusal has to read as a sentence without
      # knowing which. A fifo, because it is the one of them a test can make with
      # no privileges and no mode involved.
      relup!(dir, "1.2.3", [{~c"1.2.2", [], [:restart_emulator]}], [])
      assert {_, 0} = System.cmd("mkfifo", [marker(dir)])
      assert %File.Stat{type: :other} = File.lstat!(marker(dir))
      handler = real_record(:install_release, {:ok, ~c"1.2.2", ~c"upgrade"})

      assert {:error, message} = Commands.install("1.2.3", dir, handler, configured(dir))
      assert message =~ "there is already something of another kind at that path"
      assert Stub.calls(:install_release) == []
    end
  end

  # Two files that merely agree on a version are not evidence that one install
  # produced them. `new_start_erl.data` is written before the reboot and removed
  # by nothing, so a failed attempt leaves OTP's half of the pair behind, and a
  # retry to the same version used to arm a fresh marker beside it - after which a
  # restart before `install_release/1` was reached presented a matching pair for
  # an install that never happened.
  #
  # What makes the pair an attempt's rather than a version's: OTP's file is
  # cleared before the marker is armed, the marker is published exclusively so two
  # attempts cannot share it, and the marker names the attempt that wrote it so
  # that no attempt removes another's.
  describe "the restart marker, as this attempt's" do
    @tag :tmp_dir
    test "clears the file a failed attempt left before arming", %{tmp_dir: dir} do
      # The reviewer's sequence, run: an attempt to 1.2.3 gets as far as OTP
      # writing new_start_erl.data and then fails, and the same version is
      # installed again. The retry has to leave that file gone, because until it
      # is written afresh there is no pair for a restart to act on.
      relup!(dir, "1.2.3", [{~c"1.2.2", [], [:restart_emulator]}], [])
      handler = real_record(:install_release, prepares_then_fails(dir, "1.2.3"))

      assert {:error, _} = Commands.install("1.2.3", dir, handler, configured(dir))
      refute File.exists?(marker(dir)), "the marker survived a failed install"
      assert File.exists?(provisional(dir)), "the fixture did not leave OTP's file behind"

      # The retry, which must not be able to pair with what the first left.
      Stub.stub(:install_release, {:ok, ~c"1.2.2", ~c"upgrade"})

      assert {:ok, _} = Commands.install("1.2.3", dir, handler, configured(dir))
      assert armed_version(dir) == "1.2.3"

      refute File.exists?(provisional(dir)),
             "a stale new_start_erl.data survived the arming that came after it"
    end

    @tag :tmp_dir
    test "is alone on disk until install_release/1 has written OTP's half",
         %{tmp_dir: dir} do
      # What a hard restart between the arming and the reboot finds, observed
      # from inside the only call that happens between them. A marker with no
      # `new_start_erl.data` beside it is not a pair, so the hook does nothing
      # with it and the system comes back on the permanent version - which is the
      # direction this protocol is built to fail in. The state is unobservable
      # from outside the call, because a successful install leaves the marker
      # armed either way.
      relup!(dir, "1.2.3", [{~c"1.2.2", [], [:restart_emulator]}], [])
      File.write!(provisional(dir), "16.0 1.2.3")

      handler =
        real_record(:install_release, fn _args ->
          send(self(), {:when_asked, File.exists?(marker(dir)), File.exists?(provisional(dir))})
          {:ok, ~c"1.2.2", ~c"upgrade"}
        end)

      assert {:ok, _} = Commands.install("1.2.3", dir, handler, configured(dir))
      assert_received {:when_asked, true, false}
    end

    @tag :tmp_dir
    test "refuses while another restart install is pending", %{tmp_dir: dir} do
      # One at a time. Two attempts sharing the marker overwrite and disarm each
      # other, and the survivor's marker says nothing about which of them reached
      # :release_handler. The install is refused with nothing touched - notably
      # not the pending marker, and not OTP's file, which the refusal has to fall
      # in front of rather than after.
      relup!(dir, "1.2.3", [{~c"1.2.2", [], [:restart_emulator]}], [])
      File.write!(marker(dir), "1.2.4\nsomeone-elses-attempt\n")
      File.write!(provisional(dir), "16.0 1.2.4")
      handler = real_record(:install_release, {:ok, ~c"1.2.2", ~c"upgrade"})

      assert {:error, message} = Commands.install("1.2.3", dir, handler, configured(dir))
      assert message =~ "a restart install is pending - it names 1.2.4"
      assert message =~ "consumed by the next start of this deployment"
      assert File.read!(marker(dir)) == "1.2.4\nsomeone-elses-attempt\n"
      assert File.exists?(provisional(dir))
      assert Stub.calls(:install_release) == []
    end

    @tag :tmp_dir
    test "does not remove a marker it did not arm", %{tmp_dir: dir} do
      # Any start of the deployment consumes the marker, whether or not it goes on
      # to boot, so a marker at that path when an install fails is not
      # necessarily the one that install armed. Removing it by name would take a
      # later attempt's reboot away. Arranged by replacing the marker from inside
      # install_release/1, which is the only moment between the arming and the
      # disarming.
      relup!(dir, "1.2.3", [{~c"1.2.2", [], [:restart_emulator]}], [])

      foreign = "1.2.4\nsomeone-elses-attempt\n"

      handler =
        real_record(:install_release, fn _args ->
          File.rm!(marker(dir))
          File.write!(marker(dir), foreign)
          {:error, :whatever}
        end)

      assert {:error, _} = Commands.install("1.2.3", dir, handler, configured(dir))
      assert File.read!(marker(dir)) == foreign
    end
  end

  # Arming is one thing and *settling* is another, and the second used to happen
  # only when `install_release/1` returned. An exit, a throw or a raise went past
  # the two branches that disarmed, leaving the marker armed - and, where
  # `prepare_restart_new_emulator/7` had already written `new_start_erl.data`,
  # leaving the complete pair the launcher acts on. That is the "boots a version
  # nothing installed" hazard the whole protocol exists to prevent, reached through
  # the one path that does not return.
  #
  # The second half is that failing to settle it has to be *said*. A best-effort
  # removal whose result nobody looks at, and an unreadable marker classified as
  # somebody else's, both end with an operator meeting a stranded marker as a
  # surprise boot.
  describe "the restart marker, when the install does not return" do
    @tag :tmp_dir
    test "is settled when install_release/1 raises", %{tmp_dir: dir} do
      # The discriminator, and it needs OTP's file written before the raise: with
      # the marker left behind the two agree, and the next start boots 1.2.3 with
      # the release records calling it unpacked. The exception itself is let out
      # unchanged - Castle has nothing to add to it - so what this asserts is that
      # it arrived *and* that the filesystem was settled on the way.
      relup!(dir, "1.2.3", [{~c"1.2.2", [], [:restart_emulator]}], [])

      handler =
        real_record(:install_release, fn _args ->
          File.write!(provisional(dir), "16.0 1.2.3")
          raise "the relup blew up"
        end)

      assert_raise RuntimeError, "the relup blew up", fn ->
        Commands.install("1.2.3", dir, handler, configured(dir))
      end

      refute File.exists?(marker(dir)), "the marker survived an install that raised"

      assert File.exists?(provisional(dir)),
             "the fixture did not leave OTP's half of the pair behind"
    end

    @tag :tmp_dir
    test "is settled when install_release/1 exits", %{tmp_dir: dir} do
      # The other two classes go the same way. An `exit` is the one a real
      # `:release_handler` produces most readily - a `gen_server` call to a process
      # that went down while the upgrade was running.
      relup!(dir, "1.2.3", [{~c"1.2.2", [], [:restart_emulator]}], [])
      handler = real_record(:install_release, fn _args -> exit(:killed) end)

      assert catch_exit(Commands.install("1.2.3", dir, handler, configured(dir))) == :killed
      refute File.exists?(marker(dir))
    end

    @tag :tmp_dir
    test "is settled when install_release/1 throws", %{tmp_dir: dir} do
      relup!(dir, "1.2.3", [{~c"1.2.2", [], [:restart_emulator]}], [])
      handler = real_record(:install_release, fn _args -> throw(:no_matching_relup) end)

      assert catch_throw(Commands.install("1.2.3", dir, handler, configured(dir))) ==
               :no_matching_relup

      refute File.exists?(marker(dir))
    end

    @tag :tmp_dir
    test "gives the serialised region up on the way out", %{tmp_dir: dir} do
      # `:global.trans/3` is `try Fun() after del_lock(...)`, so an exception
      # releases the lock rather than wedging every later install. That is
      # `global`'s guarantee and not Castle's, and it is worth a test anyway: the
      # re-raise is a *new* way of leaving the region, and the failure it would
      # cause - every subsequent install blocking for ever - is not one this suite
      # would otherwise notice.
      #
      # The second install has to come from another process. The lock is keyed on
      # the requester, so two calls from the test process would be reentrant and
      # this would pass against a leaked lock.
      relup!(dir, "1.2.3", [{~c"1.2.2", [], [:restart_emulator]}], [])
      raising = real_record(:install_release, fn _args -> raise "the relup blew up" end)

      assert_raise RuntimeError, "the relup blew up", fn ->
        Commands.install("1.2.3", dir, raising, configured(dir))
      end

      second = installer(dir, "1.2.2", as: :second, install: prepares_then_reboots(dir))

      assert {{:ok, _}, [[~c"1.2.3"]], _} = Task.await(second, 30_000)
      assert armed_version(dir) == "1.2.3"
    end

    @tag :tmp_dir
    test "does not disarm the marker a successful restart install left", %{tmp_dir: dir} do
      # The reason this is `try/catch/else` and not `try/after`. An `after` cannot
      # see which way the block went, so it would take away the marker whose whole
      # purpose is to outlive this call - and the install would report a reboot
      # that the next start had nothing to act on.
      relup!(dir, "1.2.3", [{~c"1.2.2", [], [:restart_emulator]}], [])
      handler = real_record(:install_release, prepares_then_reboots(dir))

      assert {:ok, _} = Commands.install("1.2.3", dir, handler, configured(dir))
      assert armed_version(dir) == "1.2.3"
      assert File.exists?(provisional(dir))
    end
  end

  # Being unable to settle the marker is an outcome Castle has to have something
  # to say about and no way to cause, so it is reached through
  # `Castle.Deployment.read/1` and `rm/1` - the seam `stat/1` established, and for
  # the reason it gives. A fixture would need a mode, and root and some
  # filesystems ignore modes, so it would only sometimes describe the state it
  # names and would pass either way.
  describe "the restart marker, when it cannot be settled" do
    @tag :tmp_dir
    test "says so when this attempt's marker cannot be removed", %{tmp_dir: dir} do
      # A failed install that leaves the marker where it is, beside the
      # `new_start_erl.data` its own preparation wrote. Silence here is an operator
      # restarting a system whose install failed and getting the version it failed
      # to reach.
      relup!(dir, "1.2.3", [{~c"1.2.2", [], [:restart_emulator]}], [])
      handler = real_record(:install_release, prepares_then_fails(dir, "1.2.3"))

      assert {:error, message} =
               Commands.install(
                 "1.2.3",
                 dir,
                 handler,
                 configured(dir),
                 unremovable_marker(dir)
               )

      # The failure the operator asked about is still reported - this is a second
      # fact, not a replacement for the first.
      assert message =~ "Install of 1.2.3 failed."
      assert message =~ "bad_relup_file"

      # And then what it means. The marker, why it is still there, and what the
      # next start will now do about it.
      assert message =~ "The restart marker this install armed is still there"
      assert message =~ marker(dir)
      assert message =~ "could not be removed (permission denied)"
      assert message =~ "the next ordinary start of this system will boot the version"
      assert message =~ "Remove the marker before restarting this system"

      # The marker really is still there, so the message is not describing a state
      # it also cleaned up.
      assert armed_version(dir) == "1.2.3"
    end

    @tag :tmp_dir
    test "says so when it cannot tell whether the marker is its own", %{tmp_dir: dir} do
      # An unreadable marker used to be classified as another attempt's and left
      # alone, which reads as caution and is not: a marker that cannot be read is
      # no evidence about whose it is, and the file it might be is the one the next
      # start acts on. So it refuses to remove it *and* refuses to be quiet.
      relup!(dir, "1.2.3", [{~c"1.2.2", [], [:restart_emulator]}], [])
      handler = real_record(:install_release, prepares_then_fails(dir, "1.2.3"))

      assert {:error, message} =
               Commands.install(
                 "1.2.3",
                 dir,
                 handler,
                 configured(dir),
                 unreadable_marker(dir)
               )

      assert message =~ "Install of 1.2.3 failed."
      assert message =~ "cannot be accounted for"
      assert message =~ "could not be read (I/O error)"
      assert message =~ "will not remove a marker that may be a later attempt's"
      assert message =~ "Remove the marker before restarting this system"
    end

    @tag :tmp_dir
    test "says so, and says what happened, when the install raised as well",
         %{tmp_dir: dir} do
      # The two findings meeting. An exception is normally let out unchanged,
      # because `Castle` is the boundary that raises and Castle has nothing to add
      # to it - but a stranded marker is the thing an operator most needs told, and
      # a stacktrace is where it would be buried. So this one branch reports
      # instead, with the exception folded in rather than dropped.
      relup!(dir, "1.2.3", [{~c"1.2.2", [], [:restart_emulator]}], [])

      handler =
        real_record(:install_release, fn _args ->
          File.write!(provisional(dir), "16.0 1.2.3")
          raise "the relup blew up"
        end)

      assert {:error, message} =
               Commands.install(
                 "1.2.3",
                 dir,
                 handler,
                 configured(dir),
                 unremovable_marker(dir)
               )

      assert message =~
               "Install of 1.2.3 raised, and the restart marker it armed could not be settled."

      assert message =~ "The restart marker this install armed is still there"
      assert message =~ "Remove the marker before restarting this system"

      # The exception is not lost, and neither is where it came from.
      assert message =~ "The failure itself:"
      assert message =~ "the relup blew up"
      assert message =~ "(RuntimeError)"

      assert armed_version(dir) == "1.2.3"
    end

    @tag :tmp_dir
    test "is quiet about a marker a start of the deployment consumed", %{tmp_dir: dir} do
      # The ordinary case that must not be reported: any start or daemon of the
      # deployment consumes the marker, so a failed install can perfectly well find
      # nothing at the path. That is the outcome disarming wanted, not a failure to
      # reach it - so `:enoent` is success, from both the read and the removal.
      relup!(dir, "1.2.3", [{~c"1.2.2", [], [:restart_emulator]}], [])

      handler =
        real_record(:install_release, fn _args ->
          File.rm!(marker(dir))
          {:error, {:bad_relup_file, ~c"relup"}}
        end)

      assert {:error, message} = Commands.install("1.2.3", dir, handler, configured(dir))
      assert message == "Install of 1.2.3 failed. {:bad_relup_file, ~c\"relup\"}"
      refute message =~ "restart marker"
    end
  end

  # The steps of the arming protocol are one caller's sequence, and two callers
  # can run it at once: `release_handler` serialises `install_release/1`, but that
  # is downstream of the read, the classification and the arming, so both callers
  # get past the marker check before either publishes. The loser then clears the
  # winner's `new_start_erl.data` after the winner's preparation wrote it, the
  # winner's reboot comes back on the permanent release, and the loser says
  # nothing has been changed while having changed it.
  #
  # So the whole install is serialised on the node, and these are about the region
  # rather than about the marker: what they hold is that a second caller cannot
  # get as far as the *lookup* while the first is inside.
  describe "the restart marker, with two callers" do
    @tag :tmp_dir
    test "serialises them, so both cannot pass the initial lookup", %{tmp_dir: dir} do
      # The barrier is `which_releases/0`, which is the first thing inside the
      # region and the only seam in front of the arming - so a caller held there
      # has taken the region and armed nothing, which is exactly the state two of
      # them used to be able to occupy at once. Messages rather than sleeps: what
      # is asserted is an order, and a test that waits for one is a test that
      # sometimes asserts nothing.
      relup!(dir, "1.2.3", [{~c"1.2.2", [], [:restart_emulator]}], [])

      first = installer(dir, "1.2.2", as: :first, hold: true, install: prepares_then_reboots(dir))
      assert_receive {:looked_up, :first}

      second = installer(dir, "1.2.2", as: :second)
      assert_receive {:started, :second}

      # The discriminator, and the whole of what the region buys. Without it the
      # second caller reads the running release, classifies the same transition
      # and passes `unclaimed/3` here, while the first is still in front of its
      # own arming - after which one of them destroys the other's evidence.
      refute_receive {:looked_up, :second}, 200

      send(first.pid, :proceed)
      assert {{:ok, lines}, [[~c"1.2.3"]], _} = Task.await(first, 30_000)
      assert Enum.join(lines, " ") =~ "The emulator is restarting."

      # Only now does the second caller look, and what it finds is a marker beside
      # the file OTP's preparation wrote - a finished attempt waiting for its
      # reboot. It is refused, which is the message it would have been given
      # before as well; the difference is that it is now said about a pair that is
      # complete rather than said while taking half of it away.
      assert_receive {:looked_up, :second}, 10_000
      assert {{:error, message}, [], _} = Task.await(second, 30_000)
      assert message =~ "a restart install is pending - it names 1.2.3"

      assert armed_version(dir) == "1.2.3"

      assert File.exists?(provisional(dir)),
             "the waiting caller cleared the reboot's own new_start_erl.data"
    end

    @tag :tmp_dir
    test "leaves the target configured by the one that installed it", %{tmp_dir: dir} do
      # The defect this describes was not in the marker protocol at all: it was in
      # `Castle.install/1` composing `materialise/3` and `install/4`, so two
      # callers both materialised before either reached the lock. Materialising
      # ends by renaming a resolved configuration onto the target's `sys.config` -
      # a replace, necessarily, because that is the file `:release_handler` reads -
      # so the loser's providers overwrote the configuration the winner's
      # provisional release was about to boot, and the loser was then refused for
      # the winner's marker. The install that was refused decided what the install
      # that succeeded booted.
      #
      # **So this one goes through `Castle.install/5`, and that is the point of the
      # arguments it takes.** Every other case here drives `Commands.install/5`,
      # which is the right level for them - but the composition was one layer up,
      # in the function `bin/castle` actually calls, and a case that never calls it
      # would stay green while somebody put `materialise/3` back in front of the
      # install. The two callers here are two `rpc`s, which is what they would be.
      #
      # Two providers that yield *distinguishable* results is what makes it
      # visible. With both callers answering `{:ok, []}` the end state is identical
      # whichever of them ran, which is why every existing test passed against it.
      relup!(dir, "1.2.3", [{~c"1.2.2", [], [:restart_emulator]}], [])

      first =
        installer(dir, "1.2.2",
          as: :first,
          hold: true,
          through: :boundary,
          install: prepares_then_reboots(dir),
          configure: configures("[{first, resolved}].\n")
        )

      assert_receive {:looked_up, :first}

      second =
        installer(dir, "1.2.2",
          as: :second,
          through: :boundary,
          configure: configures("[{second, resolved}].\n")
        )

      assert_receive {:started, :second}
      refute_receive {:looked_up, :second}, 200

      send(first.pid, :proceed)
      assert {{:ok, _}, [[~c"1.2.3"]], [_configured]} = Task.await(first, 30_000)

      # The refused caller is refused *before* it materialises, which is the half
      # that moving the materialisation inside the lock would not have fixed on its
      # own: inside the region but ahead of `unclaimed/3`, it would still have
      # replaced the configuration on its way to being told no.
      assert {{:error, message}, [], []} = Task.await(second, 30_000)
      assert message =~ "a restart install is pending - it names 1.2.3"

      # And the discriminator. The version waiting for its reboot holds the
      # configuration of the install that armed it.
      assert configuration(dir, "1.2.3") == "[{first, resolved}].\n"
    end

    @tag :tmp_dir
    test "hands the region on when the first install fails", %{tmp_dir: dir} do
      # The other direction, and what says the region is given up on every way
      # out rather than only on the happy one: a failed install disarms, so the
      # caller that was waiting finds the path free and arms its own marker.
      relup!(dir, "1.2.3", [{~c"1.2.2", [], [:restart_emulator]}], [])

      failing = {:error, {:bad_relup_file, ~c"relup"}}
      first = installer(dir, "1.2.2", as: :first, hold: true, install: failing)
      assert_receive {:looked_up, :first}

      second = installer(dir, "1.2.2", as: :second, install: prepares_then_reboots(dir))
      assert_receive {:started, :second}
      refute_receive {:looked_up, :second}, 200

      send(first.pid, :proceed)
      assert {{:error, _}, [[~c"1.2.3"]], _} = Task.await(first, 30_000)
      assert {{:ok, _}, [[~c"1.2.3"]], _} = Task.await(second, 30_000)

      assert armed_version(dir) == "1.2.3"
    end

    @tag :tmp_dir
    test "classifies each of them from the release it found running", %{tmp_dir: dir} do
      # One relup, two answers. From 1.2.1 the transition to 1.2.3 restarts the
      # emulator and from 1.2.2 it is hot, so what the classification decides
      # depends on the release the caller found running - and an install that
      # completed in between would move it, arming a marker for a reboot OTP will
      # not make or taking a reboot with none armed. Which is the second reason
      # the region reaches past the arming to `install_release/1`.
      relup!(
        dir,
        "1.2.3",
        [{~c"1.2.2", [], [{:apply, {:m, :f, []}}]}, {~c"1.2.1", [], [:restart_emulator]}],
        []
      )

      restarting =
        installer(dir, "1.2.1", as: :restarting, hold: true, install: prepares_then_reboots(dir))

      assert_receive {:looked_up, :restarting}

      hot = installer(dir, "1.2.2", as: :hot)
      assert_receive {:started, :hot}
      refute_receive {:looked_up, :hot}, 200

      send(restarting.pid, :proceed)
      assert {{:ok, lines}, _, _} = Task.await(restarting, 30_000)
      assert Enum.join(lines, " ") =~ "The emulator is restarting."
      armed = File.read!(marker(dir))

      # The hot caller arms nothing of its own, so it neither adopts nor disarms
      # the marker the restarting one left: the reboot that is still owed happens
      # on the version that asked for it.
      assert {{:ok, ["Now running 1.2.3 (previously 1.2.2)."]}, _, _} = Task.await(hot, 30_000)
      assert File.read!(marker(dir)) == armed
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

  describe "commit/5" do
    # Every case here names a `configured(dir)`, for the reason the install cases
    # do: materialising is a step *of* the commit now rather than something
    # composed in front of it at the boundary. It moved because the composition
    # was racy - a duplicate install of the version being committed could
    # materialise between the two calls, and its configuration would be what the
    # newly permanent release booted. See `Castle.commit/1`.
    @tag :tmp_dir
    test "reports what committing means", %{tmp_dir: dir} do
      handler = Stub.stub(:make_permanent, :ok)
      configured(dir)

      assert Commands.commit("1.2.3", dir, handler, PeerStub) ==
               {:ok, ["Committed 1.2.3. System restarts will now boot into this version."]}

      assert Stub.calls(:make_permanent) == [[~c"1.2.3"]]
    end

    @tag :tmp_dir
    test "configures the version before making it permanent", %{tmp_dir: dir} do
      # The ordering, asserted the way the install cases assert theirs: the
      # handler stands ready to succeed, and what is checked is that the peer was
      # asked first. A commit that made a version permanent and *then* configured
      # it would leave the system permanently on a configuration nothing had
      # resolved yet.
      handler = Stub.stub(:make_permanent, :ok)
      configured(dir)

      assert {:ok, _} = Commands.commit("1.2.3", dir, handler, PeerStub)
      assert PeerStub.calls() == [Path.join(dir, "1.2.3")]
    end

    @tag :tmp_dir
    test "does not make it permanent if it cannot be configured", %{tmp_dir: dir} do
      # And the other half: a configuration that cannot be resolved has to stop
      # the commit, or the version becomes permanent with whatever was there
      # before.
      handler = Stub.stub(:make_permanent, :ok)

      File.mkdir_p!(Path.join(dir, "1.2.3"))
      |> then(fn _ -> unpacked(Path.join(dir, "1.2.3")) end)

      PeerStub.stub({:error, "DATABASE_URL is not set"})

      assert {:error, message} = Commands.commit("1.2.3", dir, handler, PeerStub)
      assert message =~ "DATABASE_URL is not set"
      assert Stub.calls(:make_permanent) == []
    end

    @tag :tmp_dir
    test "commits without asking whether the system can be upgraded from", %{tmp_dir: dir} do
      # Deliberate, and not an omission. make_permanent/1 cannot write the
      # synthesised record back - do_make_permanent/2 returns early for a release
      # that is already permanent and errors for every other status - while a
      # refusal here would strand a version installed while the record was still
      # good, leaving the previous release to come back at the next restart.
      handler = synthesised_record(:make_permanent, :ok)
      configured(dir)

      assert {:ok, _} = Commands.commit("1.2.3", dir, handler, PeerStub)
      assert Stub.calls(:which_releases) == []
    end

    @tag :tmp_dir
    test "reports a failure to commit", %{tmp_dir: dir} do
      handler = Stub.stub(:make_permanent, {:error, {:bad_status, :unpacked}})
      configured(dir)

      assert {:error, message} = Commands.commit("1.2.3", dir, handler, PeerStub)
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

      assert {:error, message} = Commands.install("1.2.3", dir, handler, PeerStub, erts_less())

      assert message =~
               "Cannot install 1.2.3: the deployment and the emulator's root are different directories"

      assert Stub.calls(:install_release) == []
      assert Stub.calls(:which_releases) == []
    end

    test "refuses to commit, without committing or starting a peer" do
      # `PeerStub` is unstubbed and raises if it is reached, so "refuses before it
      # configures anything" is asserted by the guard holding rather than by a
      # separate look - the same shape as the install case above, and it applies
      # to `commit` now that materialising is a step inside it.
      handler = Stub.stub(:make_permanent, :ok)

      assert {:error, message} =
               Commands.commit("1.2.3", "/unused", handler, PeerStub, erts_less())

      assert message =~
               "Cannot commit 1.2.3: the deployment and the emulator's root are different directories"

      assert Stub.calls(:make_permanent) == []
      assert PeerStub.calls() == []
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

  # What `which_releases/0` reports for a node running `vsn` on a record it read
  # from a RELEASES file: it names applications, so the check `unpack/3` and
  # `install/5` make passes.
  defp running_record(vsn) do
    [{~c"sample", to_charlist(vsn), [~c"kernel-10.5", ~c"stdlib-7.2"], :permanent}]
  end

  # A handler whose running release was read from a RELEASES file, so it names
  # applications and the check unpack/3 and install/5 make passes, with `fun`
  # answering `reply`.
  defp real_record(fun, reply) do
    Stub.stub(:which_releases, running_record("1.2.2"))
    Stub.stub(fun, reply)
  end

  # An `install/5` of 1.2.3 in a task of its own, from a node running `from`,
  # reporting where it got to over messages so that two of them can be
  # interleaved deterministically. It answers
  # `{result, install_release calls, materialise calls}`, because all three are
  # per-process: `Castle.ReleaseHandlerStub` and `Castle.PeerStub` keep their
  # replies and their record of calls in the dictionary of whichever process
  # called them, and here that is the task rather than the test.
  #
  # `hold: true` stops the caller inside `which_releases/0` until it is sent
  # `:proceed`. That is the seam the interleaving needs: the first thing the
  # serialised region does and the last one before anything is written.
  #
  # `configure:` is what this caller's peer does, and it is a reply rather than a
  # fixed `{:ok, []}` so that a test can give two callers materialisations whose
  # results are told apart. That is the only way to see *whose* configuration a
  # version ended up with, which is the thing composing materialisation in front
  # of the lock got wrong.
  #
  # `through: :boundary` runs `Castle.install/5` instead of `Commands.install/5`.
  # That distinction is load bearing rather than tidy: the defect was
  # `Castle.install/1` composing `materialise/3` and the install, so a case that
  # only ever calls `Commands.install/5` cannot see it come back. One case uses it,
  # and says why.
  defp installer(rel_dir, from, opts) do
    test = self()
    name = Keyword.fetch!(opts, :as)
    lookup = lookup(test, name, from, Keyword.get(opts, :hold, false))
    reply = Keyword.get(opts, :install, {:ok, ~c"1.2.2", ~c"upgrade"})
    configure = Keyword.get(opts, :configure, {:ok, []})
    through = Keyword.get(opts, :through, :commands)

    Task.async(fn ->
      Stub.stub(:which_releases, lookup)
      Stub.stub(:install_release, reply)
      PeerStub.stub(configure)

      send(test, {:started, name})

      {invoke(through, rel_dir), Stub.calls(:install_release), PeerStub.calls()}
    end)
  end

  defp invoke(:commands, rel_dir), do: Commands.install("1.2.3", rel_dir, Stub, PeerStub)

  # Through `Castle.install/5`, which is the function `bin/castle` reaches over
  # `rpc` and the only place a composition in front of the serialised region could
  # live. It is a command boundary rather than an operation, so it *prints* what
  # succeeded and *raises* what failed; both are turned back into the shape
  # `Commands.install/5` returns so that a case can be written either way round.
  #
  # `with_io/1` rather than `capture_io/1` because the result is wanted as well as
  # the output, and it runs in the task's own process because that is whose group
  # leader has to be swapped.
  defp invoke(:boundary, rel_dir) do
    case with_io(fn -> attempt(rel_dir) end) do
      {{:error, _} = refusal, _output} -> refusal
      {:ok, output} -> {:ok, String.split(output, "\n", trim: true)}
    end
  end

  defp attempt(rel_dir) do
    Castle.install("1.2.3", rel_dir, Stub, PeerStub)
  rescue
    error in Castle.Error -> {:error, Exception.message(error)}
  end

  # The `which_releases/0` a caller is given: it says that the lookup happened
  # and, when the caller is the one being held, waits there until it is let go.
  defp lookup(test, name, from, hold?) do
    fn _args ->
      send(test, {:looked_up, name})
      if hold?, do: await_proceed()
      running_record(from)
    end
  end

  defp await_proceed, do: receive(do: (:proceed -> :ok))

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

  # A deployment whose ERTS guard is inert - no `RELEASE_ROOT`, which is what
  # `mix test` runs in and what every case that omits this argument already gets -
  # and whose filesystem refuses one operation on the marker.
  #
  # `nil` for both roots rather than the real ones, deliberately: `ensure_own_erts/2`
  # returns early on a `release_root` of `nil` without asking for the other, so a
  # `root_dir` that is never read is a `root_dir` this fixture is not claiming
  # anything about.
  #
  # The refusal is scoped to the marker by path, so that nothing else these
  # installs do is affected by it - the version directory, OTP's file and the
  # working directory the marker is staged in all go through `File` directly.
  defp unremovable_marker(rel_dir) do
    DeploymentStub.stub(nil, nil)
    DeploymentStub.stub_rm(refusing(marker(rel_dir), :eacces, &File.rm/1))
  end

  defp unreadable_marker(rel_dir) do
    DeploymentStub.stub(nil, nil)
    DeploymentStub.stub_read(refusing(marker(rel_dir), :eio, &File.read/1))
  end

  # `reason` for `path`, and the real operation for anything else.
  defp refusing(path, reason, real) do
    fn asked -> if asked == path, do: {:error, reason}, else: real.(asked) end
  end

  # Enough of an unpacked version directory for `materialise/3`: what is in it is
  # the peer's business, and the peer is a stub here. Everything it would look
  # for is covered against a real one in `Castle.PeerTest`.
  defp unpacked(dir), do: File.write!(Path.join(dir, "sys.config"), "[].\n")

  # A target `install/5` can materialise: the version directory unpacked, which is
  # what `materialise/3` looks for before it will reach a peer at all, and a peer
  # that says it configured it.
  #
  # Every install case names one, and that is the point rather than an
  # inconvenience. Materialising is a *step of the install* now, not something
  # composed in front of it, so a case that did not say what the peer did would not
  # have said what the version it installed is configured with - and that is
  # exactly the thing the composition got wrong.
  defp configured(rel_dir, vsn \\ "1.2.3") do
    dir = Path.join(rel_dir, vsn)
    File.mkdir_p!(dir)
    unpacked(dir)

    PeerStub.stub({:ok, []})
  end

  # A peer that writes a distinguishable `sys.config` into the version directory,
  # the way the real one ends by renaming a resolved configuration onto it.
  #
  # This is what makes "whose configuration is the version left holding" an
  # observable question. `Castle.PeerStub` answering `{:ok, []}` cannot: the end
  # state is the same whichever caller materialised, which is why no test saw the
  # composition being wrong.
  defp configures(contents) do
    fn rel_vsn_dir ->
      File.write!(Path.join(rel_vsn_dir, "sys.config"), contents)
      {:ok, []}
    end
  end

  # What the target's `sys.config` says, which is whichever materialisation wrote
  # it last.
  defp configuration(rel_dir, vsn) do
    rel_dir |> Path.join(vsn) |> Path.join("sys.config") |> File.read!()
  end

  defp marker(rel_dir), do: Path.join(rel_dir, "castle-restart-pending")
  defp provisional(rel_dir), do: Path.join(rel_dir, "new_start_erl.data")

  # The version the marker names, which is its first line and the only part the
  # launcher's hook reads.
  defp armed_version(rel_dir) do
    rel_dir |> marker() |> File.read!() |> String.split("\n") |> hd()
  end

  # An `install_release/1` that does what `prepare_restart_new_emulator/7` does
  # before it fails: writes `new_start_erl.data` naming the target, and then
  # errors. That is the state no end-state fixture can produce, because the file
  # only comes into being while the call is in flight - and it is the state that
  # made the pair correlate by version rather than by attempt.
  defp prepares_then_fails(rel_dir, vsn) do
    fn _args ->
      File.write!(provisional(rel_dir), "16.0 #{vsn}")
      {:error, {:bad_relup_file, ~c"relup"}}
    end
  end

  # The same preparation, succeeding: `new_start_erl.data` written and the reply a
  # one-stage restart is given, which is the one a completed hot upgrade is given
  # too. That is the state a second caller must not be able to take apart - the
  # marker and OTP's file, both this attempt's, waiting for a reboot that has been
  # asked for and has not happened yet.
  defp prepares_then_reboots(rel_dir) do
    fn [vsn] ->
      File.write!(provisional(rel_dir), "16.0 #{vsn}")
      {:ok, ~c"1.2.2", ~c"upgrade"}
    end
  end

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
