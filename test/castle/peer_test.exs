defmodule Castle.PeerTest do
  # These start real VMs, and two of them set environment variables that the
  # peer inherits, which belong to the whole node.
  use ExUnit.Case, async: false

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
