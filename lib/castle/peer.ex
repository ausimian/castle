defmodule Castle.Peer do
  @moduledoc false

  # Materialises the configuration of the release being upgraded *to*, by
  # running that release's own `Config.Provider` pipeline in a temporary VM
  # booted from that release's own boot script and code.
  #
  # The point is that Castle does not keep a second implementation of what
  # Elixir already does. `Config.Provider.boot/1` *is* the pipeline - it reads
  # the base configuration, folds the providers over it, reports a provider that
  # failed, and writes the result - and this module calls it. Nothing here
  # iterates over providers. Two things are arranged around that one call:
  #
  #   * it happens in a VM running the *target's* code, because a provider
  #     module can differ between the version that is running and the version
  #     being installed, and it is the target's that has to decide what the
  #     target's configuration is, and
  #
  #   * the provider state is asked to write rather than to reboot. Elixir's
  #     pipeline either applies the resolved configuration to the VM it is
  #     running in, or writes it to a file and reboots into it; only the second
  #     leaves anything behind, and the VM here is thrown away. So
  #     `reboot_system_after_config` is switched on for the call, the file it
  #     writes to is named explicitly, and the reboot is replaced by a function
  #     that does nothing, there being nothing to reboot into.
  #
  # ## The VM
  #
  # `:peer` with `connection: :standard_io`: the peer is an ordinary child
  # process talking over its own stdin and stdout, so no epmd, cookie, node name
  # or distribution is involved, and its output - a provider printing a
  # diagnostic, say - is forwarded to whoever asked for the install. It is
  # started linked, so that it cannot outlive the command: the peer stops when
  # its control port closes, and that port belongs to the control process.
  #
  # It boots `preboot`, the script Forecastle writes into every version
  # directory. That script starts kernel, stdlib, sasl, compiler, elixir and
  # castle and nothing else - notably not the release's own applications, which
  # must not be started a second time - while its final `path` instruction is
  # the release's whole code path, so a provider module belonging to one of
  # those applications is still loadable. Which is why the peer runs in
  # interactive mode: those modules are on the path but not loaded, and only
  # interactive mode will load them on demand. Of the other two scripts every
  # release has, `start` would boot the release and `start_clean` has no elixir
  # in it, so `preboot` is the only one that will do.
  #
  # The emulator is the one the target's own release file asks for, found under
  # the release root, so that a target shipping a new ERTS is evaluated by that
  # ERTS rather than by the one it is replacing.
  #
  # ## What the peer is not given
  #
  # The target's `sys.config` is *not* passed as `-config`. The pipeline takes
  # its base configuration from the file it is pointed at, which is what
  # `Config.Provider` reads, so loading the same file into the peer's own
  # application environment would add nothing except a second, automatic run of
  # the pipeline - `preboot` carries Mix's `Config.Provider.boot/0` apply, once
  # the target has providers at all - and every side effect of configuring a VM
  # that is about to be discarded. The visible consequence is that a provider
  # which reads the application environment, rather than the configuration it is
  # handed, sees an unconfigured VM. Reading the application environment is not
  # how a provider is given its input.
  #
  # ## The compatibility contract
  #
  # `resolve/1` is called *in the target release*, so it is the target's copy of
  # this module that answers. `{Castle.Peer, :resolve, 1}`, taking a path and
  # returning `{:ok, config}` or `{:error, message}`, is therefore a contract
  # between one version of Castle and the next. A target whose Castle is too old
  # to have it fails the call, and the install is refused before anything has
  # been changed.

  @boot_script "preboot"
  @sys_config "sys.config"

  # Elixir's own private keys, read and written here because this drives
  # Elixir's own pipeline.
  @init_key :config_provider_init
  @booted_key :config_provider_booted

  # Everything that waits, waits with a deadline. A peer that never boots, or
  # that boots and never answers, would otherwise hold an install open for as
  # long as it liked - and all of this runs before `install_release/1`, so an
  # install that never starts is the best outcome left once something has gone
  # wrong.
  @boot_timeout 30_000
  @resolve_timeout 120_000

  @typedoc "The outcome of materialisation: nothing to report, or why it failed."
  @type result :: {:ok, [String.t()]} | {:error, String.t()}

  @doc """
  Materialises the configuration of the release whose version directory is
  given, reporting nothing when it succeeds.

  The release root is the directory two levels above, which is where a release
  keeps `lib`, `erts-*` and the `releases` directory this one lives in.
  """
  @spec materialise(Path.t()) :: result()
  def materialise(rel_vsn_dir) do
    with {:ok, peer} <- plan(rel_vsn_dir),
         {:ok, header, config} <- read_sys_config(peer) do
      # A release with no providers has nothing to resolve: what Mix wrote is
      # already its final configuration, and `sys.config` is left exactly as it
      # is rather than rewritten with the same contents.
      if declares_providers?(config), do: expand(peer, header), else: {:ok, []}
    end
  end

  defp declares_providers?(config) do
    Enum.any?(config, fn
      {:elixir, kv} when is_list(kv) -> Enum.any?(kv, &match?({@init_key, _}, &1))
      _other -> false
    end)
  end

  # The resolved configuration is assembled beside `sys.config` and then moved
  # onto it, so that the release is never left holding half a configuration: the
  # copy is what the peer reads and writes, and the rename is the only moment
  # `sys.config` changes. Copied rather than created so that it inherits
  # `sys.config`'s mode, which the rename then keeps.
  defp expand(peer, header) do
    expand_into_scratch(peer, header)
  after
    File.rm(peer.scratch)
  end

  defp expand_into_scratch(peer, header) do
    with :ok <- copy(peer.sys_config, peer.scratch),
         {:ok, config} <- run(peer),
         :ok <- write(peer.scratch, [header, format(config)]) do
      rename(peer.scratch, peer.sys_config)
    end
  end

  ## The peer

  # Exits are trapped for as long as the peer exists. The control process is
  # linked, which is what stops the peer outliving this command, and a link cuts
  # both ways: a control process going down for a reason of its own would
  # otherwise take the command with it, and this runs ahead of
  # `install_release/1`, where an exit is a silent abort rather than a reported
  # failure.
  defp run(peer) do
    trap = Process.flag(:trap_exit, true)

    try do
      start_and_resolve(peer)
    after
      # Drained before the flag goes back, so that what arrives while draining is
      # still a message rather than a signal.
      flush_exits()
      Process.flag(:trap_exit, trap)
    end
  end

  defp start_and_resolve(peer) do
    with {:ok, pid} <- start(peer), do: resolve_and_stop(pid, peer)
  end

  defp resolve_and_stop(pid, peer) do
    call(pid, peer)
  after
    stop(pid)
  end

  defp start(peer) do
    {:ok, pid, _node} =
      :peer.start_link(%{
        connection: :standard_io,
        exec: to_charlist(peer.erl),
        args: args(peer),
        env: env(peer),
        wait_boot: @boot_timeout,
        shutdown: :close
      })

    {:ok, pid}
  catch
    kind, reason ->
      {:error,
       "Cannot configure #{peer.vsn}: no VM could be started from #{peer.boot}.boot. " <>
         Exception.format(kind, reason, __STACKTRACE__)}
  end

  defp call(pid, peer) do
    case :peer.call(pid, __MODULE__, :resolve, [peer.scratch], @resolve_timeout) do
      {:ok, config} when is_list(config) ->
        {:ok, config}

      {:error, message} when is_binary(message) ->
        {:error, message}

      other ->
        {:error,
         "Cannot configure #{peer.vsn}: Castle.Peer.resolve/1 answered #{inspect(other)} " <>
           "in the release being installed, which may carry a version of Castle that " <>
           "predates this mechanism."}
    end
  catch
    kind, reason ->
      {:error,
       "Cannot configure #{peer.vsn}: its configuration could not be evaluated. " <>
         Exception.format(kind, reason, __STACKTRACE__)}
  end

  # `:peer.stop/1` closes the control port, which the peer sees as the end of
  # its standard input and halts on. Failing to stop a control process that has
  # already gone is not failing to stop the peer, so nothing is made of it.
  defp stop(pid) do
    :peer.stop(pid)
  catch
    _kind, _reason -> :ok
  end

  defp flush_exits do
    receive do
      {:EXIT, _pid, _reason} -> flush_exits()
    after
      0 -> :ok
    end
  end

  defp args(peer) do
    Enum.map(
      ["-boot", peer.boot, "-boot_var", "RELEASE_LIB", Path.join(peer.root, "lib")],
      &to_charlist/1
    )
  end

  # The peer inherits this node's environment - the same environment the
  # providers of the version being replaced were expanded against - with the
  # variables that say *which* release is being configured pointed at the
  # target. `RELEASE_SYS_CONFIG` names the target's own configuration, not the
  # copy being written: where the pipeline writes is settled by the provider
  # state, and a provider reading this variable means to ask which release it is
  # configuring. Crash dumps are turned off, because a peer that dies has
  # nothing to say that its output has not already said, and the dump would be
  # left in whatever directory the operator ran the command from.
  defp env(peer) do
    for {name, value} <- [
          {"RELEASE_ROOT", peer.root},
          {"RELEASE_VSN", peer.vsn},
          {"RELEASE_SYS_CONFIG", Path.rootname(peer.sys_config)},
          {"ERL_CRASH_DUMP_SECONDS", "0"}
        ],
        do: {to_charlist(name), to_charlist(value)}
  end

  ## Preflight
  #
  # All of this runs before a VM is started, and every bit of it before
  # `install_release/1`: a target that cannot be evaluated has to be refused
  # while refusing is still free.

  defp plan(rel_vsn_dir) do
    root = Path.expand("../..", rel_vsn_dir)
    boot = Path.join(rel_vsn_dir, @boot_script)
    sys_config = Path.join(rel_vsn_dir, @sys_config)
    vsn = Path.basename(rel_vsn_dir)
    scratch = Path.join(rel_vsn_dir, "castle-#{System.pid()}-#{unique()}.config")

    with :ok <- regular(sys_config, "#{vsn} has neither a sys.config nor a build.config."),
         :ok <- regular(boot <> ".boot", "Its configuration is evaluated on that script."),
         {:ok, erl} <- emulator(root, rel_vsn_dir) do
      {:ok,
       %{
         vsn: vsn,
         root: root,
         boot: boot,
         erl: erl,
         sys_config: sys_config,
         scratch: scratch
       }}
    end
  end

  defp unique, do: System.unique_integer([:positive])

  defp regular(path, note) do
    if File.regular?(path) do
      :ok
    else
      {:error, "Cannot read #{path}. #{note}"}
    end
  end

  # The emulator named by the target's own release file, resolved against the
  # release root. `include_erts: false` puts no emulator there, and Castle
  # cannot serve such a release anyway: the release root is derived from
  # `:code.root_dir()`, which for a release without its own ERTS is the system's
  # OTP installation rather than the release.
  defp emulator(root, rel_vsn_dir) do
    with {:ok, erts_vsn} <- erts_vsn(rel_vsn_dir) do
      erl = Path.join([root, "erts-#{erts_vsn}", "bin", "erl"])

      if File.regular?(erl) do
        {:ok, erl}
      else
        {:error,
         "Cannot read #{erl}, the emulator the release being configured asks for. A " <>
           "release that does not bring its own ERTS cannot be upgraded by Castle."}
      end
    end
  end

  defp erts_vsn(rel_vsn_dir) do
    with {:ok, path} <- release_file(rel_vsn_dir), do: erts_vsn_from(path)
  end

  defp erts_vsn_from(path) do
    case :file.consult(to_charlist(path)) do
      {:ok, [{:release, _name_and_vsn, {:erts, erts_vsn}, _apps}]} ->
        {:ok, to_string(erts_vsn)}

      {:ok, terms} ->
        {:error, "Cannot read #{path} as a release file. It holds #{inspect(terms)}."}

      {:error, reason} ->
        {:error, "Cannot read #{path}. #{format_error(reason)}"}
    end
  end

  # Mix names the release file after the release, so it is found rather than
  # named. A version directory holds exactly one: Mix renames the one belonging
  # to the `start` script and removes the rest. Listed rather than globbed,
  # since a release root is a path and not a pattern.
  defp release_file(rel_vsn_dir) do
    case File.ls(rel_vsn_dir) do
      {:ok, entries} ->
        release_file(rel_vsn_dir, Enum.filter(entries, &String.ends_with?(&1, ".rel")))

      {:error, reason} ->
        {:error, "Cannot list #{rel_vsn_dir}. #{format_error(reason)}"}
    end
  end

  defp release_file(rel_vsn_dir, [name]), do: {:ok, Path.join(rel_vsn_dir, name)}

  defp release_file(rel_vsn_dir, []) do
    {:error,
     "Cannot find a release file in #{rel_vsn_dir}, so the emulator to evaluate its " <>
       "configuration with is unknown."}
  end

  defp release_file(rel_vsn_dir, names) do
    {:error,
     "Found more than one release file in #{rel_vsn_dir} - #{Enum.join(names, ", ")} - so " <>
       "the emulator to evaluate its configuration with is ambiguous."}
  end

  ## sys.config

  # The comment header Mix writes above the term is kept, because the launcher
  # reads it: `RUNTIME_CONFIG=true` is what tells the launcher to boot from a
  # copy of this file rather than from the file itself, which is what keeps a
  # release that reboots after configuring it from rewriting itself. Re-emitting
  # the term without the header would change how the version boots.
  defp read_sys_config(peer) do
    with {:ok, contents} <- read(peer.sys_config),
         {:ok, config} <- consult(peer.sys_config) do
      {:ok, header(contents), config}
    end
  end

  defp header(contents) do
    contents
    |> String.split("\n")
    |> Enum.take_while(&String.starts_with?(&1, "%%"))
    |> Enum.map(&[&1, ?\n])
  end

  defp format(config), do: :io_lib.format(~c"~tp.~n", [config])

  ## In the peer
  #
  # Everything below here runs in the temporary VM, on the target release's own
  # code.

  @doc false
  @spec resolve(Path.t()) :: {:ok, keyword()} | {:error, String.t()}
  def resolve(path) do
    forward_standard_error()

    with {:ok, config} <- consult(path),
         {:ok, provider} <- provider(config, path) do
      run_pipeline(path, provider)
    end
  end

  # Everything the pipeline writes has to leave this VM as a control frame
  # rather than as bytes of its own.
  #
  # A `standard_io` connection multiplexes the peer's console output with the
  # frames that carry the call and its answer over the one stream, and reserves
  # sixteen byte values for the framing. Those values are lead bytes of UTF-8, so
  # a byte in that range arriving as console output is read as framing, the
  # frame's checksum then fails, and the origin's control process dies with it -
  # which is to say a provider writing an accented character to standard error
  # would fail an install that was otherwise about to succeed.
  #
  # What the pipeline writes through this VM's `user` process is already a frame
  # and is unaffected, so standard error is pointed at the same place: a relay,
  # because a process can hold only one registered name and `user` has one.
  # Requests are passed on untouched, so it is `user` that answers whoever asked.
  # The only raw output left after this is the emulator's own, which it writes
  # while going down and which is ASCII.
  defp forward_standard_error do
    user = Process.whereis(:user)
    standard_error = Process.whereis(:standard_error)

    if is_pid(user) and is_pid(standard_error) do
      Process.unregister(:standard_error)
      Process.register(spawn(fn -> relay(user) end), :standard_error)
    end

    :ok
  end

  defp relay(device) do
    receive do
      request -> send(device, request)
    end

    relay(device)
  end

  defp provider(config, path) do
    case config[:elixir][@init_key] do
      %Config.Provider{} = provider -> {:ok, provider}
      nil -> {:error, "#{path} declares no config providers."}
      other -> {:error, "#{path} declares #{inspect(other)} as its config providers."}
    end
  end

  # Elixir's pipeline, run once, with two things settled for it beforehand: the
  # resolved configuration is to be written to `path` rather than applied to
  # this VM, and the reboot that ordinarily follows the write is not to happen.
  # Nothing here decides what the configuration is.
  #
  # The booted marker is cleared first because it is what makes `boot/1` skip
  # the providers altogether. Nothing in a peer should have set it - it is set
  # by a release on its way to a reboot - but if anything ever does, skipping
  # silently would leave the target unconfigured and say so nowhere.
  defp run_pipeline(path, provider) do
    Application.delete_env(:elixir, @booted_key)

    Application.put_env(
      :elixir,
      @init_key,
      %{provider | config_path: path, reboot_system_after_config: true}
    )

    case Config.Provider.boot(fn -> :written end) do
      :written -> resolved(path)
      other -> {:error, "Evaluating #{path} answered #{inspect(other)} instead of writing it."}
    end
  end

  # The marker Elixir adds on its way to a reboot says "the providers have run
  # already for this boot", and this was not a boot. Left in, it would tell the
  # target to skip its providers the next time it starts cold, freezing its
  # configuration as of the upgrade.
  defp resolved(path) do
    with {:ok, config} <- consult(path) do
      {:ok, Keyword.replace_lazy(config, :elixir, &Keyword.delete(&1, @booted_key))}
    end
  end

  ## Files

  defp read(path) do
    case File.read(path) do
      {:ok, contents} -> {:ok, contents}
      {:error, reason} -> {:error, "Cannot read #{path}. #{format_error(reason)}"}
    end
  end

  defp consult(path) do
    case :file.consult(to_charlist(path)) do
      {:ok, [config]} when is_list(config) ->
        {:ok, config}

      {:ok, terms} ->
        {:error, "Cannot read #{path}: expected one configuration term, found #{length(terms)}."}

      {:error, reason} ->
        {:error, "Cannot read #{path}. #{format_error(reason)}"}
    end
  end

  defp copy(source, destination) do
    case File.cp(source, destination) do
      :ok -> :ok
      {:error, reason} -> {:error, "Cannot write #{destination}. #{format_error(reason)}"}
    end
  end

  defp write(path, contents) do
    case File.write(path, contents) do
      :ok -> :ok
      {:error, reason} -> {:error, "Cannot write #{path}. #{format_error(reason)}"}
    end
  end

  defp rename(source, destination) do
    case File.rename(source, destination) do
      :ok -> {:ok, []}
      {:error, reason} -> {:error, "Cannot write #{destination}. #{format_error(reason)}"}
    end
  end

  defp format_error(reason) when is_atom(reason), do: :file.format_error(reason)
  defp format_error(reason), do: inspect(reason)
end
