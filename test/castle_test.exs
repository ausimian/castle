defmodule CastleTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  doctest Castle

  # These go through the real :release_handler, which is running here because
  # castle depends on sasl. No release named below exists, and nothing that
  # reports a failure has changed anything, so what these pin down is what the
  # command boundary does with the answer it gets.
  describe "the command boundary" do
    test "raises, rather than returning, when an operation fails" do
      assert_raise Castle.Error, ~r/^Unpack failed for no-such-release-9\.9\.9:/, fn ->
        Castle.unpack("no-such-release-9.9.9")
      end

      assert_raise Castle.Error, ~r/^Removal failed for 9\.9\.9:/, fn ->
        Castle.remove("9.9.9")
      end
    end

    # The check rests on a claim about OTP's own data: a release record read from
    # a RELEASES file names applications, and only the record release_handler
    # synthesises when it cannot read one names none. The release_handler running
    # here read the OTP installation's own RELEASES file, so what this checks is
    # that claim, against a real record rather than a stub. The unpack above
    # depends on it too, now that unpack/1 makes the same check for itself: on an
    # installation with no releases/RELEASES it would be refused for the record
    # instead of for the release that does not exist, and this test says why.
    test "confirms a system whose record came from a RELEASES file, silently" do
      assert [{_, _, [_ | _], _} | _] = :release_handler.which_releases()
      assert capture_io(&Castle.upgradable/0) == ""
    end

    # The configuration of the target has to exist before the target is handed
    # to :release_handler, so materialising it comes first and a failure to
    # materialise it stops there. What is raised says so: it is the refusal to
    # configure a version that was never unpacked, not the refusal to install
    # one, which is what install_release/1 would have answered had it been
    # asked.
    test "does not install a version whose configuration could not be materialised" do
      for command <- [&Castle.install/1, &Castle.commit/1] do
        assert_raise Castle.Error,
                     ~r/^Cannot configure 9\.9\.9: .*Unpack the release first\.$/,
                     fn ->
                       command.("9.9.9")
                     end
      end
    end

    test "prints what a successful operation has to report" do
      assert capture_io(&Castle.releases/0) =~ ~r/^\S+\s+permanent$/m
    end

    test "confirms the release that is running, silently" do
      [{_, vsn, _, _}] = :release_handler.which_releases(:permanent)

      # Through the real :init as well as the real :release_handler: a VM that
      # has finished booting reports {:starting, :started}, which is the shape
      # the confirmation has to accept.
      assert {_internal, :started} = :init.get_status()
      assert capture_io(fn -> assert Castle.running(to_string(vsn)) == :ok end) == ""
    end

    test "raises when asked about a version that is not the one running" do
      assert_raise Castle.Error, ~r/^9\.9\.9 is not the running release\./, fn ->
        Castle.running("9.9.9")
      end
    end
  end
end
