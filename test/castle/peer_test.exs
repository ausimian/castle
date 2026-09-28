defmodule Castle.PeerTest do
  # These start real VMs, and two of them set environment variables that the
  # peer inherits, which belong to the whole node.
  use ExUnit.Case, async: false

  alias Castle.Commands
  alias Castle.FileReason
  alias Castle.IoSink
  alias Castle.PeerProviderStub
  alias Castle.SyntheticRelease

  # Compiled into an application of its own by the test that needs two versions
  # of it, so it is not here to be found at compile time.
  @compile {:no_warn_undefined, Castle.VersionedProviderStub}

  @moduletag :tmp_dir
  @moduletag timeout: 120_000

  describe "materialise/1" do
    test "resolves the target's configuration through the target's providers", %{tmp_dir: root} do
      runtime = Path.join(root, "runtime.exs")

      File.write!(runtime, """
      import Config
      config :sample, greeting: System.get_env("CASTLE_PEER_TEST_GREETING", "unset")
      config :sample, resolved_in: to_string(node())
      """)

      System.put_env("CASTLE_PEER_TEST_GREETING", "from the peer")
      on_exit(fn -> System.delete_env("CASTLE_PEER_TEST_GREETING") end)

      vsn_dir =
        SyntheticRelease.build(root,
          config:
            with_providers([{Config.Reader, path: runtime, env: :prod}],
              sample: [greeting: "compile-time", untouched: true]
            )
        )

      assert Castle.Peer.materialise(vsn_dir) == {:ok, []}

      config = read_sys_config(vsn_dir)
      assert config[:sample][:greeting] == "from the peer"
      assert config[:sample][:untouched] == true

      # Not the node running the test: a VM of its own, and one with no node
      # name at all, since nothing here starts distribution.
      assert config[:sample][:resolved_in] == "nonode@nohost"

      # The configuration is assembled beside sys.config and moved onto it, so
      # nothing is left in the version directory afterwards.
      assert Enum.filter(File.ls!(vsn_dir), &String.starts_with?(&1, "castle-")) == []
    end

    test "runs the target's provider module, not the running node's", %{tmp_dir: root} do
      module = Castle.VersionedProviderStub

      {_running_app, running} =
        SyntheticRelease.provider_app(
          Path.join(root, "running"),
          :versioned_provider,
          "1.0.0",
          module,
          provider_source(module, "the running node")
        )

      {target_app, _target} =
        SyntheticRelease.provider_app(
          Path.join(root, "target"),
          :versioned_provider,
          "1.0.0",
          module,
          provider_source(module, "the target release")
        )

      # The node running the test is left holding the other version of the same
      # module, which is the case this whole mechanism exists for: the answer
      # has to come from the version being installed.
      :code.purge(module)
      :code.delete(module)
      {:module, ^module} = :code.load_binary(module, ~c"running", running)
      on_exit(fn -> :code.purge(module) end)

      assert Castle.VersionedProviderStub.load([], []) ==
               [sample: [resolved_by: "the running node"]]

      vsn_dir =
        SyntheticRelease.build(root,
          apps: [target_app],
          config: with_providers([{module, []}], [])
        )

      assert Castle.Peer.materialise(vsn_dir) == {:ok, []}
      assert read_sys_config(vsn_dir)[:sample][:resolved_by] == "the target release"
    end

    test "does not leave the marker that would stop a cold boot configuring itself",
         %{tmp_dir: root} do
      vsn_dir = SyntheticRelease.build(root, config: with_providers([{PeerProviderStub, []}], []))

      assert Castle.Peer.materialise(vsn_dir) == {:ok, []}

      # Elixir writes this on its way to the reboot that a release does after
      # configuring itself, and reads it to know the providers have already run.
      # This was not a boot, and a version whose sys.config carries it would
      # never run its providers again.
      refute Keyword.has_key?(read_sys_config(vsn_dir)[:elixir], :config_provider_booted)
    end

    test "keeps the header the launcher reads", %{tmp_dir: root} do
      vsn_dir =
        SyntheticRelease.build(root,
          header: "%% coding: utf-8\n%% RUNTIME_CONFIG=true\n",
          config: with_providers([{PeerProviderStub, merge: [sample: [ok: true]]}], [])
        )

      assert Castle.Peer.materialise(vsn_dir) == {:ok, []}

      contents = File.read!(Path.join(vsn_dir, "sys.config"))
      assert contents =~ "%% coding: utf-8\n%% RUNTIME_CONFIG=true\n"
      assert read_sys_config(vsn_dir)[:sample][:ok] == true
    end

    test "survives a provider that writes to standard error", %{tmp_dir: root} do
      runtime = Path.join(root, "runtime.exs")

      # A detached peer's standard error is the null device, so this is only
      # heard at all because it is relayed through the peer's user process and
      # over the control connection. Not ASCII, deliberately: what a provider
      # says about what it could not find has to arrive as written.
      File.write!(runtime, """
      import Config
      IO.puts(:stderr, "café — naïve, and still fine")
      config :sample, greeting: "resolved"
      """)

      vsn_dir =
        SyntheticRelease.build(root,
          config: with_providers([{Config.Reader, path: runtime, env: :prod}], [])
        )

      {result, forwarded} = IoSink.with_group_leader(fn -> Castle.Peer.materialise(vsn_dir) end)

      assert result == {:ok, []}
      assert forwarded =~ "café — naïve, and still fine"
      assert read_sys_config(vsn_dir)[:sample][:greeting] == "resolved"
    end

    test "survives a provider that writes outside the io system", %{tmp_dir: root} do
      # The door the standard-error relay cannot cover, and the reason the
      # control connection is a socket: `:erlang.display_string/1` and a write
      # straight to a file descriptor, both with characters that a stream
      # shared with the framing would have been unable to tell from framing.
      vsn_dir =
        SyntheticRelease.build(root,
          config:
            with_providers(
              [{PeerProviderStub, raw: "café — naïve ✅", merge: [sample: [ok: true]]}],
              []
            )
        )

      assert Castle.Peer.materialise(vsn_dir) == {:ok, []}
      assert read_sys_config(vsn_dir)[:sample][:ok] == true
    end

    test "leaves a release that has no providers exactly as it was", %{tmp_dir: root} do
      vsn_dir = SyntheticRelease.build(root, config: [sample: [greeting: "compile-time"]])
      sys_config = Path.join(vsn_dir, "sys.config")
      before = File.read!(sys_config)

      assert Castle.Peer.materialise(vsn_dir) == {:ok, []}
      assert File.read!(sys_config) == before
    end
  end

  describe "the peer" do
    test "is stopped once it has answered", %{tmp_dir: root} do
      marker = Path.join(root, "peer.pid")

      vsn_dir =
        SyntheticRelease.build(root,
          config: with_providers([{PeerProviderStub, marker: marker}], [])
        )

      assert Castle.Peer.materialise(vsn_dir) == {:ok, []}
      assert gone?(File.read!(marker))
    end

    test "is stopped when the configuration cannot be evaluated", %{tmp_dir: root} do
      marker = Path.join(root, "peer.pid")

      vsn_dir =
        SyntheticRelease.build(root,
          config:
            with_providers([{PeerProviderStub, marker: marker, raise: "DATABASE_URL is not set"}],
              sample: [greeting: "compile-time"]
            )
        )

      sys_config = Path.join(vsn_dir, "sys.config")
      before = File.read!(sys_config)

      # Captured because the peer's own output is forwarded to whoever asked for
      # the install, which is what makes a provider that failed say so - here,
      # the test - rather than dying quietly in a VM nobody can see.
      {result, forwarded} = IoSink.with_group_leader(fn -> Castle.Peer.materialise(vsn_dir) end)

      assert {:error, message} = result
      assert message =~ "DATABASE_URL is not set"
      assert forwarded =~ "ERROR! Config provider Castle.PeerProviderStub failed with:"

      assert gone?(File.read!(marker))

      # Nothing was written, and nothing was left behind to be written later.
      assert File.read!(sys_config) == before
      assert Enum.filter(File.ls!(vsn_dir), &String.starts_with?(&1, "castle-")) == []
    end
  end

  describe "the preflight" do
    test "reports a version directory with no sys.config", %{tmp_dir: root} do
      vsn_dir = SyntheticRelease.build(root)
      File.rm!(Path.join(vsn_dir, "sys.config"))

      assert {:error, message} = Castle.Peer.materialise(vsn_dir)
      assert message =~ Path.join(vsn_dir, "sys.config")
      assert message =~ "has no configuration to evaluate"
    end

    test "reports a version directory with no preboot script", %{tmp_dir: root} do
      vsn_dir = SyntheticRelease.build(root)
      File.rm!(Path.join(vsn_dir, "preboot.boot"))

      assert {:error, message} = Castle.Peer.materialise(vsn_dir)
      assert message =~ Path.join(vsn_dir, "preboot.boot")
    end

    test "reports a release whose emulator is not there", %{tmp_dir: root} do
      vsn_dir = SyntheticRelease.build(root)
      erts = "erts-#{:erlang.system_info(:version)}"
      File.rm!(Path.join([root, erts, "bin", "erl"]))

      assert {:error, message} = Castle.Peer.materialise(vsn_dir)
      assert message =~ Path.join([root, erts, "bin", "erl"])
      assert message =~ "does not bring its own ERTS"
    end

    test "reports a version directory with no release file", %{tmp_dir: root} do
      vsn_dir = SyntheticRelease.build(root)
      for path <- Path.wildcard(Path.join(vsn_dir, "*.rel")), do: File.rm!(path)

      assert {:error, message} = Castle.Peer.materialise(vsn_dir)
      assert message =~ "Cannot find a release file"
    end

    # Every version this path is asked to configure was unpacked from a tarball,
    # and an unpacked version directory holds two release files: the one Mix put
    # inside the tarball's version directory, and the copy `release_handler`
    # makes of the tarball's own `<name>-<vsn>.rel` beside it. That pair is not
    # ambiguous, and refusing it refused every install - which is what the rest
    # of this file now builds by default.
    test "reads the release file in a version directory that was unpacked", %{tmp_dir: root} do
      vsn_dir = SyntheticRelease.build(root)

      assert Enum.sort(rel_files(vsn_dir)) == ["synthetic-1.0.0.rel", "synthetic.rel"]

      # The two hold the same bytes, which is why nothing but a difference
      # planted between them can show which one was read.
      assert File.read!(Path.join(vsn_dir, "synthetic-1.0.0.rel")) ==
               File.read!(Path.join(vsn_dir, "synthetic.rel"))

      assert Castle.Peer.materialise(vsn_dir) == {:ok, []}
    end

    test "reads the copy unpacking left, and not Mix's", %{tmp_dir: root} do
      vsn_dir = SyntheticRelease.build(root)

      # Mix's copy, made to name an emulator that is not there. It is the copy
      # `release_handler` admitted the version on that says what the version is -
      # `RELEASES` was written from those bytes - so that is the one to read, and
      # preferring this one would refuse a release that boots.
      File.write!(
        Path.join(vsn_dir, "synthetic.rel"),
        :io_lib.format(~c"~tp.~n", [
          {:release, {~c"synthetic", ~c"1.0.0"}, {:erts, ~c"0.0.0"}, []}
        ])
      )

      assert Castle.Peer.materialise(vsn_dir) == {:ok, []}
    end

    test "reads the one release file a version Mix assembled has", %{tmp_dir: root} do
      vsn_dir = SyntheticRelease.build(root, shape: :assembled)

      assert rel_files(vsn_dir) == ["synthetic.rel"]
      assert Castle.Peer.materialise(vsn_dir) == {:ok, []}
    end

    test "refuses two release files that are not one release's", %{tmp_dir: root} do
      vsn_dir = SyntheticRelease.build(root, shape: :assembled)
      File.cp!(Path.join(vsn_dir, "synthetic.rel"), Path.join(vsn_dir, "other.rel"))

      assert {:error, message} = Castle.Peer.materialise(vsn_dir)
      assert message =~ "Cannot determine the release file"
      assert message =~ "synthetic.rel"
      assert message =~ "other.rel"
    end

    test "refuses a copy that belongs to another version", %{tmp_dir: root} do
      # What is accepted is a release file and the copy made of it *for this
      # version*, since the version directory's own name is the version. A name
      # that merely looks like such a copy is two release files.
      vsn_dir = SyntheticRelease.build(root, shape: :assembled)
      File.cp!(Path.join(vsn_dir, "synthetic.rel"), Path.join(vsn_dir, "synthetic-2.0.0.rel"))

      assert {:error, message} = Castle.Peer.materialise(vsn_dir)
      assert message =~ "Cannot determine the release file"
      assert message =~ "synthetic-2.0.0.rel"
    end

    test "refuses a third release file beside the pair", %{tmp_dir: root} do
      vsn_dir = SyntheticRelease.build(root)
      File.cp!(Path.join(vsn_dir, "synthetic.rel"), Path.join(vsn_dir, "other.rel"))

      assert {:error, message} = Castle.Peer.materialise(vsn_dir)
      assert message =~ "Cannot determine the release file"
      assert message =~ "other.rel"
    end

    test "reports a release file that does not hold one release", %{tmp_dir: root} do
      # The emulator to evaluate the configuration with comes out of the release
      # file, and the shape is matched rather than picked over, so anything else
      # in the file has to be refused rather than read around. A second term
      # appended to the release is what `:file.consult/1` reveals and the pattern
      # rejects - and naming what was there is what tells an operator whether they
      # are looking at a damaged release or at the wrong file altogether.
      vsn_dir = SyntheticRelease.build(root)
      authoritative = Path.join(vsn_dir, "synthetic-1.0.0.rel")
      File.write!(authoritative, File.read!(authoritative) <> "{appended_by_hand}.\n")

      assert {:error, message} = Castle.Peer.materialise(vsn_dir)
      assert message =~ "Cannot read #{authoritative} as a release file. It holds ["
      assert message =~ "{:appended_by_hand}"
    end

    test "reports a release file it cannot read at all", %{tmp_dir: root} do
      # Not the same answer, and it must not be: a file that will not parse says
      # nothing about what it holds, so the message says what the read said
      # instead of describing terms nobody got.
      vsn_dir = SyntheticRelease.build(root)
      authoritative = Path.join(vsn_dir, "synthetic-1.0.0.rel")
      File.write!(authoritative, "{release,\n")

      assert {:error, message} = Castle.Peer.materialise(vsn_dir)
      assert message =~ "Cannot read #{authoritative}."
      refute message =~ "as a release file"
    end

    test "refuses a version whose sys.config will not parse", %{tmp_dir: root} do
      # Refused before a VM is started, like everything else here: `sys.config` is
      # read twice on the way in - as bytes, for the header the launcher reads,
      # and as terms - and it is the second that decides whether there is
      # anything to resolve at all. `:file.consult/1` answers a
      # `{Line, Module, Reason}` tuple for this rather than a posix atom, which is
      # the reason `FileReason.format/1` has a clause for something that is not an
      # atom: the line is the part an operator needs, and it is inside the tuple.
      vsn_dir = SyntheticRelease.build(root, config: with_providers([{PeerProviderStub, []}], []))
      sys_config = Path.join(vsn_dir, "sys.config")
      File.write!(sys_config, "this is not a configuration")

      assert {:error, message} = Castle.Peer.materialise(vsn_dir)
      assert message =~ "Cannot read #{sys_config}. {1, :erl_parse,"
    end

    test "reports a target whose Castle does not answer this call", %{tmp_dir: root} do
      # The cross-version contract, seen from the far side. `resolve/1` runs in
      # the *target* release's own code, so `{Castle.Peer, :resolve, 1}` is an
      # agreement between one version of Castle and the next - and a target built
      # against a Castle that predates it answers something this cannot use. Not
      # an exception, which the catch below `call/2` already covers, and not an
      # `{:error, binary}` either: a third thing, which has to be refused with
      # the reason an operator can act on rather than passed on as configuration.
      #
      # The fixture is a castle application built for the target alone. It is why
      # `build/2` has `:override`: the release file still names castle once, at
      # the version preboot starts, and only the code behind the name differs.
      fake = SyntheticRelease.stub_castle(Path.join(root, "old-castle"), :not_implemented)

      vsn_dir =
        SyntheticRelease.build(root,
          override: [fake],
          config: with_providers([{PeerProviderStub, []}], [])
        )

      sys_config = Path.join(vsn_dir, "sys.config")
      before = File.read!(sys_config)

      assert {:error, message} = Castle.Peer.materialise(vsn_dir)
      assert message =~ "Castle.Peer.resolve/1 answered :not_implemented"
      assert message =~ "predates this mechanism"

      # Refused rather than resolved from, so nothing was written.
      assert File.read!(sys_config) == before
      assert Enum.filter(File.ls!(vsn_dir), &String.starts_with?(&1, "castle-")) == []
    end

    test "gives up on a peer that never boots, at the deadline", %{tmp_dir: root} do
      vsn_dir = SyntheticRelease.build(root, config: with_providers([{PeerProviderStub, []}], []))
      File.write!(Path.join(vsn_dir, "preboot.boot"), "not a boot script")

      # A peer reached over a socket is detached, so nothing it says on the way
      # down arrives and the origin holds no handle on it: a boot that fails is
      # noticed when the deadline expires. Which is what this is here to pin -
      # that there is a deadline, and that it is the one it was given.
      {elapsed, result} =
        :timer.tc(fn -> Castle.Peer.materialise(vsn_dir, boot_timeout: 1_000) end, :millisecond)

      assert {:error, message} = result

      assert message =~
               "no VM was started from #{Path.join(vsn_dir, "preboot")}.boot within 1000ms"

      assert elapsed < 10_000
    end
  end

  describe "the pristine base" do
    # The reason the base exists, in the shape it actually bites: a runtime.exs
    # that sets a key only when something in the environment says so. Resolved
    # over the previous result, the key would still be there on the run that
    # stopped setting it - and the version an operator committed would be
    # configured differently from the way it boots.
    @conditional """
    import Config
    config :sample, greeting: "resolved"
    if System.get_env("CASTLE_TEST_FEATURE") do
      config :sample, feature: true
    end
    """

    test "resolves the same way twice, whatever the first pass produced", %{tmp_dir: root} do
      runtime = Path.join(root, "runtime.exs")
      File.write!(runtime, @conditional)
      on_exit(fn -> System.delete_env("CASTLE_TEST_FEATURE") end)

      # Two versions of one release, differing in nothing a provider can see:
      # the same runtime.exs, so the state the providers carry is identical and
      # the two configurations are comparable term for term.
      config = with_providers([{Config.Reader, path: runtime, env: :prod}], [])
      installed = SyntheticRelease.build(root, vsn: "1.0.0", config: config)
      control = SyntheticRelease.build(root, vsn: "2.0.0", config: config)

      # Install with the feature, commit without it, which is the sequence an
      # operator runs.
      System.put_env("CASTLE_TEST_FEATURE", "1")
      assert Commands.materialise(installed) == {:ok, []}
      assert read_sys_config(installed)[:sample][:feature] == true

      System.delete_env("CASTLE_TEST_FEATURE")
      assert Commands.materialise(installed) == {:ok, []}

      # What one pass from the base produces, which is what booting the version
      # would produce.
      assert Commands.materialise(control) == {:ok, []}

      refute Keyword.has_key?(read_sys_config(installed)[:sample], :feature)
      assert read_sys_config(installed) == read_sys_config(control)
    end

    test "captures what Mix wrote, once, and never again", %{tmp_dir: root} do
      vsn_dir =
        SyntheticRelease.build(root,
          config: with_providers([{PeerProviderStub, merge: [sample: [n: 1]]}], [])
        )

      sys_config = Path.join(vsn_dir, "sys.config")
      pristine = Path.join(vsn_dir, "sys.config.pristine")
      mix_wrote = File.read!(sys_config)

      refute File.exists?(pristine)
      assert Commands.materialise(vsn_dir) == {:ok, []}
      assert File.read!(pristine) == mix_wrote

      # Resolved, so no longer what Mix wrote - and the base is not touched by
      # the second run either.
      refute File.read!(sys_config) == mix_wrote
      assert Commands.materialise(vsn_dir) == {:ok, []}
      assert File.read!(pristine) == mix_wrote
    end

    test "says so once, however often it is materialised", %{tmp_dir: root} do
      vsn_dir = SyntheticRelease.build(root, config: with_providers([{PeerProviderStub, []}], []))

      assert Commands.materialise(vsn_dir) == {:ok, []}
      assert Commands.materialise(vsn_dir) == {:ok, []}

      lines = Path.join(vsn_dir, "sys.config") |> File.read!() |> String.split("\n")

      # Mix's pragma stays where the emulator looks for it, and the line that
      # makes the invariant checkable is added rather than accumulated.
      assert Enum.at(lines, 0) == "%% coding: utf-8"
      assert Enum.count(lines, &(&1 == "%% CASTLE_MATERIALISED=true")) == 1
    end

    test "keeps no base for a release with nothing to resolve", %{tmp_dir: root} do
      vsn_dir = SyntheticRelease.build(root, config: [sample: [greeting: "compile-time"]])

      assert Commands.materialise(vsn_dir) == {:ok, []}
      refute File.exists?(Path.join(vsn_dir, "sys.config.pristine"))

      # Not a working directory either, though one was made: a release that needs
      # nothing written still gets it cleared away.
      assert Enum.filter(File.ls!(vsn_dir), &String.starts_with?(&1, "castle-")) == []
    end

    test "publishes a base nothing can read before it is complete", %{tmp_dir: root} do
      vsn_dir = SyntheticRelease.build(root, config: with_providers([{PeerProviderStub, []}], []))
      sys_config = Path.join(vsn_dir, "sys.config")
      pristine = Path.join(vsn_dir, "sys.config.pristine")
      bytes = File.read!(sys_config)

      # The three steps materialisation takes, taken here one at a time, which is
      # the only way to stand between them and look.
      assert {:ok, work} = Castle.Peer.work_dir(vsn_dir)
      staging = Path.join(work, "sys.config.pristine")

      assert Castle.Peer.write_like(staging, bytes, sys_config) == :ok
      assert File.read!(staging) == bytes

      # A reader looking for the base while it is being staged. Not a partial
      # base: no base. The name is brought into existence by the link below and
      # by nothing else, and the file it names is complete before it has a name.
      refute File.exists?(pristine)
      assert File.read(pristine) == {:error, :enoent}

      assert Castle.Peer.publish(staging, pristine) == :ok
      assert File.read!(pristine) == bytes

      # Publication is a second name for the one file, which is why removing the
      # staging name afterwards leaves the base behind.
      assert File.stat!(pristine).inode == File.stat!(staging).inode
      File.rm!(staging)
      assert File.read!(pristine) == bytes
      assert File.stat!(pristine).links == 1

      # Refuses rather than replaces, which is what makes the loser of a race
      # safe: it is told the name is taken, and goes on to read what is at that
      # name instead of publishing its own copy.
      assert {:ok, other} = Castle.Peer.work_dir(vsn_dir)
      loser = Path.join(other, "sys.config.pristine")
      assert Castle.Peer.write_like(loser, "not what was published", sys_config) == :ok
      assert Castle.Peer.publish(loser, pristine) == :taken
      assert File.read!(pristine) == bytes
    end

    test "does not adopt a base that was never published", %{tmp_dir: root} do
      vsn_dir =
        SyntheticRelease.build(root,
          config: with_providers([{PeerProviderStub, merge: [sample: [n: 1]]}], [])
        )

      sys_config = Path.join(vsn_dir, "sys.config")
      pristine = Path.join(vsn_dir, "sys.config.pristine")
      original = File.read!(sys_config)

      # What an install interrupted between staging and publication leaves: a
      # staged copy, under its own name, that never became the base. Truncated,
      # since being interrupted is how it got there.
      orphan = Path.join(vsn_dir, "castle-99999-1.pristine")
      File.write!(orphan, "")

      assert Commands.materialise(vsn_dir) == {:ok, []}

      # Resolved from sys.config, which is still the original, and published
      # from that - not from the orphan, which is neither read nor removed,
      # because an install cannot tell its own leftovers from another install's
      # work in progress.
      assert File.read!(pristine) == original
      assert File.read!(orphan) == ""
      assert read_sys_config(vsn_dir)[:sample][:n] == 1
    end

    test "gives the base the permissions sys.config has", %{tmp_dir: root} do
      vsn_dir =
        SyntheticRelease.build(root,
          config: with_providers([{PeerProviderStub, merge: [sample: [n: 1]]}], [])
        )

      # An operator restricting sys.config means it about the configuration, and
      # the base holds the same configuration and the same provider state.
      sys_config = Path.join(vsn_dir, "sys.config")
      File.chmod!(sys_config, 0o600)

      assert Commands.materialise(vsn_dir) == {:ok, []}

      assert mode(Path.join(vsn_dir, "sys.config.pristine")) == 0o600
      assert mode(sys_config) == 0o600
    end

    test "refuses a base it cannot read", %{tmp_dir: root} do
      vsn_dir =
        SyntheticRelease.build(root,
          config: with_providers([{PeerProviderStub, merge: [sample: [n: 1]]}], [])
        )

      # What a Castle that published its base by writing to the name could
      # leave: a base that is not a configuration. It is preferred to
      # sys.config, being the base, so it has to be refused loudly rather than
      # resolved from.
      File.write!(Path.join(vsn_dir, "sys.config.pristine"), "")

      assert {:error, message} = Commands.materialise(vsn_dir)
      assert message =~ "sys.config.pristine"
      assert message =~ "Remove it, and unpack 1.0.0 again as well if"
    end

    test "refuses a version whose original configuration is gone", %{tmp_dir: root} do
      vsn_dir =
        SyntheticRelease.build(root,
          config: with_providers([{PeerProviderStub, merge: [sample: [n: 1]]}], [])
        )

      assert Commands.materialise(vsn_dir) == {:ok, []}

      # What a release materialised by a Castle that kept no base looks like,
      # and what someone deleting the base leaves behind. Capturing the resolved
      # configuration as though it were the original is the one thing that must
      # not happen.
      pristine = Path.join(vsn_dir, "sys.config.pristine")
      File.rm!(pristine)
      resolved = File.read!(Path.join(vsn_dir, "sys.config"))

      assert {:error, message} = Commands.materialise(vsn_dir)
      assert message =~ "was written by Castle"
      assert message =~ "Unpack 1.0.0 again to restore it."
      refute File.exists?(pristine)
      assert File.read!(Path.join(vsn_dir, "sys.config")) == resolved
    end

    test "refuses a base name that is a link rather than writing through it",
         %{tmp_dir: root} do
      # The base's name taken by something that is not a base, which is the half a
      # private working directory does not cover: the name lives in the version
      # directory, beside `sys.config`, and nothing about that directory is
      # Castle's to guarantee.
      #
      # A dangling link is what makes the two implementations distinguishable.
      # `File.regular?/1` says no for it, so this takes the first
      # materialisation's path and stages a base of its own; the link then
      # refuses rather than replaces, and what is at the name is read instead -
      # which is nothing, so the install is refused and the operator is told to
      # remove it. `File.write/2` in that position follows the link and creates
      # the target outright, and the end state of the two differs only in a file
      # somewhere else.
      vsn_dir =
        SyntheticRelease.build(root,
          config: with_providers([{PeerProviderStub, merge: [sample: [n: 1]]}], [])
        )

      sys_config = Path.join(vsn_dir, "sys.config")
      pristine = Path.join(vsn_dir, "sys.config.pristine")
      elsewhere = Path.join(root, "elsewhere")
      original = File.read!(sys_config)
      File.ln_s!(elsewhere, pristine)

      assert {:error, message} = Commands.materialise(vsn_dir)
      assert message =~ "Cannot read #{pristine}. #{FileReason.format(:enoent)}"
      assert message =~ "Remove it, and unpack 1.0.0 again as well if"

      # Nothing was written through the link, and nothing was left behind either.
      refute File.exists?(elsewhere)
      assert File.read!(sys_config) == original
      assert Enum.filter(File.ls!(vsn_dir), &String.starts_with?(&1, "castle-")) == []
    end
  end

  # Every file this module brings into existence holds a release's
  # configuration, so every one of them is made inside a working directory
  # nothing else can reach and moved out of it. What that buys is not the mode
  # the file ends up with - `File.cp/2` gets that right too - but that there is
  # no moment at which the file holds a configuration and is reachable by anyone
  # the `sys.config` it came from would exclude. A test that looks only at the
  # end state cannot tell the two apart, which is how the exposure survived
  # being fixed twice.
  describe "writing a file that holds configuration" do
    test "makes the working directory private before there is anything in it",
         %{tmp_dir: root} do
      # `mkdir` takes no mode, so the directory is narrowed after it exists just
      # as a file would be. What makes that sound is not the window being
      # harmless - it is not, see below - but that the state is checked once the
      # narrowing is done: 0700, and still empty, or the directory is not used.
      assert {:ok, work} = Castle.Peer.work_dir(root)

      assert File.dir?(work)
      assert File.ls!(work) == []
      assert mode(work) == 0o700
      assert Bitwise.band(mode(work), 0o077) == 0

      # A name already there is not adopted, whatever it is: File.mkdir/1 is what
      # refuses it, so no interloper can arrange to own the directory the
      # configuration is assembled in by getting to its name first.
      assert File.mkdir(work) == {:error, :eexist}

      link = Path.join(root, "to-work")
      File.ln_s!(work, link)
      assert File.mkdir(link) == {:error, :eexist}

      dangling = Path.join(root, "to-nothing")
      File.ln_s!(Path.join(root, "nowhere"), dangling)
      assert File.mkdir(dangling) == {:error, :eexist}

      # A directory of its own each time, so two installs in one version
      # directory cannot write into each other's.
      assert {:ok, other} = Castle.Peer.work_dir(root)
      refute other == work
    end

    test "refuses a working directory that was written into before it was narrowed",
         %{tmp_dir: root} do
      # The window `mkdir` leaves, stood in. A directory created under a umask
      # that leaves it group- or world-writable - 0002 is ordinary, 0000 exists -
      # can be written into before the chmod arrives, and the names inside it are
      # predictable. So the two steps are taken here one at a time, and something
      # else gets there in between, which is the only way to observe it: nothing
      # about the end state distinguishes a directory that was empty when it was
      # narrowed from one that was not.
      secret = Path.join(root, "secret")
      File.write!(secret, "the operator's own file")

      poisoned = Path.join(root, "castle-99999-1.work")
      File.mkdir!(poisoned)
      File.chmod!(poisoned, 0o777)

      # What an interloper plants: the name the configuration will be written to,
      # pointing at a file it can read. It needs no descriptor on the directory
      # for this - only a name inside it.
      planted = Path.join(poisoned, "sys.config")
      File.ln_s!(secret, planted)

      assert {:error, message} = Castle.Peer.secure_dir(poisoned)
      assert message =~ "Cannot use #{poisoned}"
      assert message =~ "sys.config"
      assert message =~ "removed it without writing to it"
      assert message =~ "umask"
      refute message =~ "assemble configuration"
      refute message =~ "without writing configuration"

      # Refused, removed, and the file that was pointed at neither truncated nor
      # written through: rm_rf unlinks a symlink rather than following it.
      refute File.exists?(poisoned)
      assert File.read!(secret) == "the operator's own file"
    end

    test "refuses a name already at the path rather than writing through it",
         %{tmp_dir: root} do
      # The other half, and it is not the same half: a private directory says
      # nothing about a name that is already inside it. Created exclusively, so
      # this is refused; created with File.write/2, the symlink is followed - the
      # target is truncated, chmodded to 0600 and filled with the configuration,
      # for whoever still holds it open to read.
      assert {:ok, work} = Castle.Peer.work_dir(root)

      secret = Path.join(root, "secret")
      File.write!(secret, "the operator's own file")
      File.chmod!(secret, 0o644)

      planted = Path.join(work, "sys.config")
      File.ln_s!(secret, planted)

      assert {:error, message} = Castle.Peer.write_private(planted, "the configuration")
      assert message =~ "file already exists"

      assert File.read!(secret) == "the operator's own file"
      assert mode(secret) == 0o644

      # A plain file already at the name, and a symlink to nothing, are refused
      # the same way - the second without bringing what it points at into
      # existence.
      taken = Path.join(work, "taken")
      File.write!(taken, "already here")
      assert {:error, _} = Castle.Peer.write_private(taken, "the configuration")
      assert File.read!(taken) == "already here"

      dangling = Path.join(work, "dangling")
      File.ln_s!(Path.join(root, "nowhere"), dangling)
      assert {:error, _} = Castle.Peer.write_private(dangling, "the configuration")
      refute File.exists?(Path.join(root, "nowhere"))
    end

    test "writes through the handle it created, never through the name again",
         %{tmp_dir: root} do
      # What the exclusive open establishes is that the name was free. Closing the
      # handle and reopening the same name to place the content gives that back:
      # anything able to create the name in between is handed the configuration.
      # So the two steps are taken here one at a time, and the name is swapped in
      # between - the only way to tell content that went to the inode from content
      # that went to the name, since with the name left alone the two are
      # identical.
      assert {:ok, work} = Castle.Peer.work_dir(root)
      path = Path.join(work, "sys.config")

      assert {:ok, handle} = Castle.Peer.create_exclusive(path)

      decoy = Path.join(root, "decoy")
      File.write!(decoy, "the interloper's own file")
      File.chmod!(decoy, 0o644)
      File.rm!(path)
      File.ln_s!(decoy, path)

      assert Castle.Peer.fill(handle, path, "the configuration") == :ok

      # The configuration went to the inode the exclusive open created, and the
      # file the name now points at never saw it. That is the whole claim.
      assert File.read!(decoy) == "the interloper's own file"

      # The mode did go by path, because OTP has nothing that sets a mode on an
      # open file. So the decoy has been narrowed to 0600 - Castle setting the
      # permissions of a file that is not its own, which is the acknowledged cost
      # of that asymmetry and is a nuisance rather than a disclosure: the content
      # is what an onlooker wanted, and the content never came this way.
      assert mode(decoy) == 0o600
      assert File.read!(decoy) == "the interloper's own file"
    end

    test "refuses to create one where anyone else could reach it", %{tmp_dir: root} do
      # The mistake this class of finding kept taking: a file holding
      # configuration brought into existence next to `sys.config`, in a directory
      # the whole host can traverse, where the mode it is created with is the
      # umask's to choose and `chmod` cannot take back what a reader already has
      # open. Refused rather than narrowed afterwards.
      File.chmod!(root, 0o755)
      path = Path.join(root, "copy")

      assert {:error, message} = Castle.Peer.write_private(path, "secret")
      assert message =~ "Cannot write in #{root}"
      assert message =~ "0755"
      assert message =~ "owner-only"
      refute message =~ "Cannot write configuration in"
      refute File.exists?(path)
    end

    test "is owner-only once it exists", %{tmp_dir: root} do
      assert {:ok, work} = Castle.Peer.work_dir(root)

      # Belt to the directory's braces: the file's own mode is not left as the
      # umask's choice. It is the directory that makes the content unreachable
      # while it is being written - the mode cannot, since there is no way to ask
      # for one before the file exists and none to set one on the open handle it
      # is written through.
      filled = Path.join(work, "filled")
      assert Castle.Peer.write_private(filled, "secret") == :ok
      assert mode(filled) == 0o600
      assert File.read!(filled) == "secret"

      # And once is all it can be written: the name is taken, and a second call
      # will not reopen it.
      assert {:error, _} = Castle.Peer.write_private(filled, "again")
      assert File.read!(filled) == "secret"
    end

    test "reports a write that did not happen rather than raising", %{tmp_dir: root} do
      # `:file.write/2` and not `IO.binwrite/2`, which is the whole reason the
      # write is separable from the create. The handle is opened `:raw`, so it is
      # a `file_descriptor` record that the `IO` functions merely accept, and
      # `IO.binwrite/2` is specified to return `:ok` - it earns that by raising
      # whatever `:file.write/2` answered. Everything in this module runs ahead of
      # `install_release/1` and reports rather than raises, because an exception
      # there is a silent abort of an install that has not been reported as
      # failing.
      assert {:ok, work} = Castle.Peer.work_dir(root)
      path = Path.join(work, "sys.config")

      assert {:ok, handle} = Castle.Peer.create_exclusive(path)
      assert File.close(handle) == :ok

      assert {:error, message} = Castle.Peer.fill(handle, path, "the configuration")
      assert message =~ "Cannot write #{path}."

      # And the configuration is not in the file, which is the fact the caller was
      # told about: the exclusive open created it empty and nothing filled it.
      assert File.read!(path) == ""
    end

    test "reports a close that failed, and does not narrow the file", %{tmp_dir: root} do
      # `fill/3` takes three steps and the *close* is the one no closed handle can
      # single out. A handle that is already closed fails both the write and the
      # close, and `with :ok <- written, :ok <- closed` reports the write - so the
      # test above pins `written/3` and says nothing about `closed/2`, and both
      # produce the same "Cannot write" prefix besides. Only a handle whose write
      # succeeds and whose close does not can tell them apart.
      #
      # A process is that handle. `File.io_device/0` is `pid | file_descriptor`,
      # so this is within what `fill/3` accepts: `:file.write/2` sends a pid
      # `{:put_chars, …}` over the io protocol, while `File.close/1` sends it a
      # `:file_request`, which is what lets one answer and the other refuse.
      path = Path.join(root, "sys.config")
      File.write!(path, "what was there before")
      File.chmod!(path, 0o644)

      assert {:error, message} =
               Castle.Peer.fill(closing_with(:enospc), path, "the configuration")

      # The close's own reason, which the write cannot produce here because the
      # write succeeded.
      assert message =~ "Cannot write #{path}. #{FileReason.format(:enospc)}"

      # And the mode goes on only once both have succeeded, so a file that was
      # not written in full is never given the mode that says it was.
      assert mode(path) == 0o644
      assert File.read!(path) == "what was there before"
    end

    test "reports a mode it could not set on the file it wrote", %{tmp_dir: root} do
      # The `chmod` is the one step here that goes by path, because OTP has
      # nothing that sets a mode on an open file - so it can fail where the write
      # through the handle did not, and it has to be reported when it does. The
      # content is already committed to the inode by then, at whatever the umask
      # chose, so a caller told `:ok` would go on to publish a file that never
      # took `sys.config`'s mode. The name is removed rather than swapped, which
      # is the same window the test above stands in and the deterministic end of
      # it.
      assert {:ok, work} = Castle.Peer.work_dir(root)
      path = Path.join(work, "sys.config")

      assert {:ok, handle} = Castle.Peer.create_exclusive(path)
      File.rm!(path)

      assert {:error, message} = Castle.Peer.fill(handle, path, "the configuration")
      assert message =~ "Cannot set the mode of #{path}. #{FileReason.format(:enoent)}"
      refute File.exists?(path)
    end

    test "reports a model whose mode it cannot read", %{tmp_dir: root} do
      # The mode of the file being copied is what the copy has to end up with, so
      # a model that cannot be stat'd is not a mode to go ahead without: the copy
      # would keep the 0600 it was created with, which is narrower rather than
      # wider, and would then be published as though it carried the operator's
      # own mode.
      assert {:ok, work} = Castle.Peer.work_dir(root)
      path = Path.join(work, "copy")
      model = Path.join(root, "sys.config")

      assert {:error, message} = Castle.Peer.write_like(path, "the configuration", model)
      assert message =~ "Cannot read #{model}. #{FileReason.format(:enoent)}"

      # Written, and left at the mode a file holding configuration is created
      # with. Failing part way leaves it narrower than intended, never wider.
      assert mode(path) == 0o600
    end

    test "refuses to write where it cannot see the directory at all", %{tmp_dir: root} do
      # The privacy of the directory is checked on every creation rather than
      # assumed of the working directory once, because remembering it at the call
      # sites is the thing that failed four times over. A directory that cannot be
      # stat'd is not a directory that may be assumed private - and the refusal
      # names the *directory*, which is the thing there is something wrong with.
      missing = Path.join(root, "gone")
      path = Path.join(missing, "sys.config")

      assert {:error, message} = Castle.Peer.write_private(path, "the configuration")
      assert message =~ "Cannot read #{missing}. #{FileReason.format(:enoent)}"
      refute File.exists?(path)
    end

    test "reports a directory it cannot make a working directory in", %{tmp_dir: root} do
      # Made rather than ensured, and a failure to make it refuses instead of
      # going on: everything this module writes goes inside it, so there is
      # nowhere else for the configuration to be assembled.
      missing = Path.join(root, "gone")

      assert {:error, message} = Castle.Peer.work_dir(missing)
      assert message =~ "Cannot create #{Path.join(missing, "castle-")}"
      assert message =~ FileReason.format(:enoent)
      refute File.exists?(missing)
    end

    test "reports a staging file it cannot publish, and publishes nothing",
         %{tmp_dir: root} do
      # `publish/2`'s third answer. `:eexist` is the name being taken, which is a
      # race the loser is told about and reads around; anything else is a failure
      # to publish at all, and it has to be reported rather than folded into
      # "taken" - the caller's next move for a taken name is to read what is
      # there, and here there is nothing to read.
      #
      # A staging file that is not there is the deterministic way in, and no mode
      # is involved. `File.ln/2` refuses it and creates no destination, which is
      # the second half of what this asserts: a publish that did not happen has
      # left no name behind for a start of the deployment to act on.
      staging = Path.join(root, "never-staged")
      destination = Path.join(root, "sys.config.pristine")

      assert {:error, message} = Castle.Peer.publish(staging, destination)
      assert message =~ "Cannot write #{destination}. #{FileReason.format(:enoent)}"
      refute File.exists?(destination)
    end

    test "carries an unrestricted mode just as faithfully", %{tmp_dir: root} do
      model = Path.join(root, "sys.config")
      File.write!(model, "[].\n")
      File.chmod!(model, 0o644)

      assert {:ok, work} = Castle.Peer.work_dir(root)
      path = Path.join(work, "copy")
      assert Castle.Peer.write_like(path, "not secret", model) == :ok
      assert mode(path) == 0o644
    end

    test "fills a file whose mode will forbid writing it", %{tmp_dir: root} do
      # The mode goes on last for this reason. Chmodded to 0440 first, the file
      # could not be filled at all: File.write/2 reopens the path, so it would
      # fail with :eacces against a file its own owner had just made read-only.
      model = Path.join(root, "sys.config")
      File.write!(model, "[].\n")
      File.chmod!(model, 0o440)

      assert {:ok, work} = Castle.Peer.work_dir(root)
      path = Path.join(work, "copy")
      assert Castle.Peer.write_like(path, "read only", model) == :ok
      assert mode(path) == 0o440
      assert File.read!(path) == "read only"

      # And it can still be moved out from under that mode, and cleared away
      # afterwards: both need permission on the directory rather than on the
      # file.
      assert File.rename(path, Path.join(root, "moved")) == :ok
      assert File.rm_rf(work) == {:ok, [work]}
    end

    test "gives the file the configuration is resolved into sys.config's mode",
         %{tmp_dir: root} do
      # Observed from inside the peer, while the pipeline is running: the file
      # exists only until materialisation renames it onto sys.config, and its
      # mode has to be right before the providers put anything in it.
      vsn_dir = Path.join([root, "releases", "1.0.0"])
      recorded = Path.join(root, "mode")

      ^vsn_dir =
        SyntheticRelease.build(root,
          config:
            with_providers(
              [
                {PeerProviderStub,
                 mode_of: Path.join(vsn_dir, "castle-*.work/sys.config"),
                 mode_to: recorded,
                 merge: [sample: [n: 1]]}
              ],
              []
            )
        )

      File.chmod!(Path.join(vsn_dir, "sys.config"), 0o600)

      assert Commands.materialise(vsn_dir) == {:ok, []}

      assert String.to_integer(File.read!(recorded), 8) == 0o600
      assert mode(Path.join(vsn_dir, "sys.config")) == 0o600
      assert read_sys_config(vsn_dir)[:sample][:n] == 1
    end

    test "keeps both files out of reach for the whole of their working life",
         %{tmp_dir: root} do
      # The intermediate state, which is the only state that can be wrong here:
      # by the time materialisation returns both files have been moved to their
      # final names or removed, and the end state is the same whether they were
      # exposed on the way or not. So the version directory is walked from inside
      # the peer, at the moment when the staged base and the file the
      # configuration is being resolved into both exist and both hold one.
      vsn_dir = Path.join([root, "releases", "1.0.0"])
      snapshot = Path.join(root, "snapshot")

      ^vsn_dir =
        SyntheticRelease.build(root,
          config:
            with_providers(
              [
                {PeerProviderStub,
                 snapshot_of: Path.join(vsn_dir, "**"),
                 snapshot_to: snapshot,
                 merge: [sample: [n: 1]]}
              ],
              []
            )
        )

      assert Commands.materialise(vsn_dir) == {:ok, []}
      assert read_sys_config(vsn_dir)[:sample][:n] == 1

      seen = snapshot(snapshot, vsn_dir)

      # One working name in the version directory, and it is a directory that
      # grants nothing to group or other - so no path leads to what is inside it,
      # and a descriptor taken on it while it was still empty leads nowhere
      # either, traversal being checked on every lookup rather than at open.
      assert [{work, :directory, work_mode}] = Enum.filter(seen, &match?({_, :directory, _}, &1))

      assert work =~ ~r"^castle-\d+-\d+\.work$"
      assert work_mode == 0o700
      assert Bitwise.band(work_mode, 0o077) == 0

      # And both files that hold configuration are inside it. Nothing Castle made
      # is loose in the version directory beside the release's own files: the
      # names it publishes there - sys.config, and the base it has already
      # linked - are the release's, and every one of the others is under the
      # working directory.
      assert Enum.sort(for {"castle-" <> _ = path, :regular, _} <- seen, do: path) ==
               [Path.join(work, "sys.config"), Path.join(work, "sys.config.pristine")]

      assert Enum.sort(for {path, :regular, _} <- seen, do: path) ==
               Enum.sort([
                 "preboot.boot",
                 "preboot.script",
                 "synthetic.rel",
                 "synthetic-1.0.0.rel",
                 "sys.config",
                 "sys.config.pristine",
                 Path.join(work, "sys.config"),
                 Path.join(work, "sys.config.pristine")
               ])

      # And it is gone afterwards, along with what was in it.
      assert Enum.filter(File.ls!(vsn_dir), &String.starts_with?(&1, "castle-")) == []
    end

    test "leaves a working directory that is not its own alone", %{tmp_dir: root} do
      vsn_dir =
        SyntheticRelease.build(root,
          config: with_providers([{PeerProviderStub, merge: [sample: [n: 1]]}], [])
        )

      # What an install interrupted before it could move its files out leaves
      # behind. It is indistinguishable from another install's work in progress -
      # which may be about to publish from it - so it is neither read nor
      # removed, exactly as a staged base that was never published is not.
      orphan = Path.join(vsn_dir, "castle-99999-1.work")
      File.mkdir!(orphan)
      File.chmod!(orphan, 0o700)
      File.write!(Path.join(orphan, "sys.config"), "")

      assert Commands.materialise(vsn_dir) == {:ok, []}

      assert File.dir?(orphan)
      assert File.ls!(orphan) == ["sys.config"]
      assert read_sys_config(vsn_dir)[:sample][:n] == 1
    end

    test "materialises a version whose configuration is read-only", %{tmp_dir: root} do
      # An operator declaring their configuration read-only. Every file here is
      # written before it takes that mode, and the two operations that move one
      # into place - the link that publishes the base, and the rename that
      # replaces sys.config - need permission on the directory rather than on the
      # file, so none of this needs the mode relaxed again.
      vsn_dir =
        SyntheticRelease.build(root,
          config: with_providers([{PeerProviderStub, merge: [sample: [n: 1]]}], [])
        )

      sys_config = Path.join(vsn_dir, "sys.config")
      File.chmod!(sys_config, 0o440)

      assert Commands.materialise(vsn_dir) == {:ok, []}

      assert mode(Path.join(vsn_dir, "sys.config.pristine")) == 0o440
      assert mode(sys_config) == 0o440
      assert read_sys_config(vsn_dir)[:sample][:n] == 1

      # And again, over a base that is itself read-only now.
      assert Commands.materialise(vsn_dir) == {:ok, []}
      assert mode(sys_config) == 0o440
      assert read_sys_config(vsn_dir)[:sample][:n] == 1

      # Including the working directory, whose contents were read-only too:
      # removing a file needs permission on the directory holding it rather than
      # on the file, the same fact the rename onto sys.config rests on.
      assert Enum.filter(File.ls!(vsn_dir), &String.starts_with?(&1, "castle-")) == []
    end
  end

  describe "the deadlines" do
    test "give up on a peer that never answers, and stop it", %{tmp_dir: root} do
      marker = Path.join(root, "peer.pid")

      vsn_dir =
        SyntheticRelease.build(root,
          config:
            with_providers(
              [{PeerProviderStub, marker: marker, sleep: :infinity}],
              sample: [greeting: "compile-time"]
            )
        )

      sys_config = Path.join(vsn_dir, "sys.config")
      before = File.read!(sys_config)

      {elapsed, result} =
        :timer.tc(
          fn -> Castle.Peer.materialise(vsn_dir, resolve_timeout: 1_000) end,
          :millisecond
        )

      assert {:error, message} = result
      assert message =~ "its configuration could not be evaluated"
      assert elapsed < 30_000

      # A provider still running is not a reason to leave a VM behind, and not a
      # reason to have written anything either.
      assert gone?(File.read!(marker))
      assert File.read!(sys_config) == before
      assert Enum.filter(File.ls!(vsn_dir), &String.starts_with?(&1, "castle-")) == []
    end
  end

  describe "the compile environment" do
    test "refuses a configuration Elixir would not boot", %{tmp_dir: root} do
      app = SyntheticRelease.plain_app(Path.join(root, "checked"), :checked_app, "1.0.0")

      vsn_dir =
        SyntheticRelease.build(root,
          apps: [app],
          config:
            with_providers(
              [{PeerProviderStub, merge: [checked_app: [mode: "runtime"]]}],
              [checked_app: [mode: "compile-time"]],
              # The shape Mix computes from each application's :compile_env, and
              # passes to Config.Provider.init/3. If Elixir ever stops
              # representing it this way, init/3 stops producing it, this test
              # stops seeing a refusal, and it fails - which is the point of
              # asserting the refusal rather than asserting a call was made.
              [{:checked_app, [:mode], {:ok, "compile-time"}}]
            )
        )

      sys_config = Path.join(vsn_dir, "sys.config")
      before = File.read!(sys_config)

      assert {:error, message} = Castle.Peer.materialise(vsn_dir)
      assert message =~ ":checked_app has a different value set for key :mode"
      assert message =~ "Compile time value was set to: \"compile-time\""
      assert message =~ "Runtime value was set to: \"runtime\""

      # Refused before anything was written, so there is nothing for
      # install_release/1 to have been given.
      assert File.read!(sys_config) == before
    end

    test "refuses to proceed when it cannot tell what to check", %{tmp_dir: root} do
      # Not a shape Elixir produces. If it ever produces another one, the check
      # has to stop and say so rather than quietly pass every release through -
      # which is the failure mode that would look exactly like working.
      vsn_dir =
        SyntheticRelease.build(root,
          config: with_providers([{PeerProviderStub, []}], [], true)
        )

      assert {:error, message} = Castle.Peer.materialise(vsn_dir)
      assert message =~ "Cannot check the compile environment, which is true."
    end

    test "accepts a configuration that agrees with what was compiled", %{tmp_dir: root} do
      app = SyntheticRelease.plain_app(Path.join(root, "checked"), :checked_app, "1.0.0")

      # The same populated check, satisfied. Without this the refusal above
      # could as easily be a check that fails for everything.
      vsn_dir =
        SyntheticRelease.build(root,
          apps: [app],
          config:
            with_providers(
              [{PeerProviderStub, merge: [checked_app: [other: "runtime"]]}],
              [checked_app: [mode: "compile-time"]],
              [{:checked_app, [:mode], {:ok, "compile-time"}}]
            )
        )

      assert Castle.Peer.materialise(vsn_dir) == {:ok, []}
      assert read_sys_config(vsn_dir)[:checked_app][:other] == "runtime"
    end
  end

  # The configuration Mix writes for a release with providers: the initialised
  # provider state under the elixir application's key, merged over the
  # compile-time configuration.
  defp with_providers(providers, config, validate_compile_env \\ false) do
    Config.Reader.merge(
      config,
      Config.Provider.init(providers, {:system, "RELEASE_SYS_CONFIG", ".config"},
        validate_compile_env: validate_compile_env
      )
    )
  end

  defp provider_source(module, tag) do
    """
    defmodule #{inspect(module)} do
      @behaviour Config.Provider

      @impl Config.Provider
      def init(opts), do: opts

      @impl Config.Provider
      def load(config, _opts) do
        Config.Reader.merge(config, sample: [resolved_by: "#{tag}"])
      end
    end
    """
  end

  defp mode(path), do: Bitwise.band(File.stat!(path).mode, 0o777)

  # An io device that accepts everything written to it and refuses to close, so
  # that `fill/3`'s write can succeed where its close cannot. `:file.write/2`
  # sends a pid an io request and `File.close/1` sends it a file request, which is
  # the whole of why the two can be answered differently.
  defp closing_with(reason) do
    spawn_link(fn -> device(reason) end)
  end

  defp device(reason) do
    receive do
      {:io_request, from, reply_as, _request} ->
        send(from, {:io_reply, reply_as, :ok})
        device(reason)

      {:file_request, from, reply_as, :close} ->
        send(from, {:file_reply, reply_as, {:error, reason}})
        device(reason)
    end
  end

  defp rel_files(vsn_dir), do: Enum.filter(File.ls!(vsn_dir), &String.ends_with?(&1, ".rel"))

  # What the peer saw, as paths relative to the version directory.
  defp snapshot(path, relative_to) do
    assert {:ok, [entries]} = :file.consult(to_charlist(path))

    for {seen, type, mode} <- entries,
        do: {Path.relative_to(to_string(seen), relative_to), type, mode}
  end

  defp read_sys_config(vsn_dir) do
    assert {:ok, [config]} = :file.consult(to_charlist(Path.join(vsn_dir, "sys.config")))
    config
  end

  # `kill -0` says whether a process exists without signalling it. Polled,
  # because a peer is halted rather than waited for: closing its standard input
  # is what stops it, and the operating system takes a moment to agree.
  defp gone?(os_pid) do
    Enum.reduce_while(1..100, false, fn _attempt, _acc ->
      case System.cmd("kill", ["-0", os_pid], stderr_to_stdout: true) do
        {_output, 0} ->
          Process.sleep(50)
          {:cont, false}

        {_output, _status} ->
          {:halt, true}
      end
    end)
  end
end
