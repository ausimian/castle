defmodule Castle.PeerTest do
  # These start real VMs, and two of them set environment variables that the
  # peer inherits, which belong to the whole node.
  use ExUnit.Case, async: false

  alias Castle.Commands
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
      assert message =~ "neither a sys.config nor a build.config"
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
      File.rm!(Path.join(vsn_dir, "synthetic.rel"))

      assert {:error, message} = Castle.Peer.materialise(vsn_dir)
      assert message =~ "Cannot find a release file"
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
    end

    test "publishes a base nothing can read before it is complete", %{tmp_dir: root} do
      vsn_dir = SyntheticRelease.build(root, config: with_providers([{PeerProviderStub, []}], []))
      sys_config = Path.join(vsn_dir, "sys.config")
      pristine = Path.join(vsn_dir, "sys.config.pristine")
      staging = Path.join(vsn_dir, "castle-staged.pristine")
      bytes = File.read!(sys_config)

      # The two steps materialisation takes, taken here one at a time, which is
      # the only way to stand between them and look.
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
      loser = Path.join(vsn_dir, "castle-staged-later.pristine")
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
  end

  # Every file this module brings into existence holds a release's
  # configuration, so every one of them goes through `write_like/3`. What that
  # buys is not the mode the file ends up with - `File.cp/2` gets that right too
  # - but that there is no moment at which the file holds a configuration and is
  # wider than the `sys.config` it came from. A test that looks only at the end
  # state cannot tell the two apart, which is how the exposure survived being
  # fixed once.
  describe "writing a file that holds configuration" do
    test "sets the mode before there is anything to read", %{tmp_dir: root} do
      model = Path.join(root, "sys.config")
      File.write!(model, "[].\n")
      File.chmod!(model, 0o600)

      path = Path.join(root, "copy")
      assert Castle.Peer.create_like(path, model) == :ok

      # The state the primitive exists to make unobservable-with-contents: the
      # mode is already the model's, and the file is empty. Anything that got
      # here first would find nothing worth having.
      assert mode(path) == 0o600
      assert File.read!(path) == ""

      assert Castle.Peer.write_like(path, "secret", model) == :ok
      assert mode(path) == 0o600
      assert File.read!(path) == "secret"
    end

    test "carries an unrestricted mode just as faithfully", %{tmp_dir: root} do
      model = Path.join(root, "sys.config")
      File.write!(model, "[].\n")
      File.chmod!(model, 0o644)

      path = Path.join(root, "copy")
      assert Castle.Peer.write_like(path, "not secret", model) == :ok
      assert mode(path) == 0o644
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
                 mode_of: Path.join(vsn_dir, "castle-*.config"),
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
