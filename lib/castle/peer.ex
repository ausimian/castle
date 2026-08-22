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
  # `:peer` with a control connection over a loopback socket. No epmd, no
  # cookie, no node name, no distribution: `:peer` requires none of those once a
  # connection is given, and the peer node reports `nonode@nohost` and
  # `is_alive() == false`. Erlang-level output from the peer - a provider
  # printing a diagnostic, say - travels over that same connection and is
  # forwarded to whoever asked for the install.
  #
  # `connection: :standard_io` is the other way to have all of that, and is what
  # the issue suggested, but it multiplexes the peer's console output with the
  # frames carrying the call over one byte stream, reserving sixteen byte values
  # for the framing. Every one of them is a UTF-8 lead byte. So a provider - or
  # a NIF under it - writing an accented character straight to a file
  # descriptor, by `:erlang.display_string/1` or anything else that bypasses the
  # io system, is read as framing, fails the frame's checksum and takes the
  # origin's control process down: a refusal, but a refusal of an install that
  # was about to succeed. Nothing outside `:peer` can harden that, because the
  # stream being shared is the mechanism. A socket carries only frames, length
  # prefixed, and a raw write goes to the null device the peer was detached onto
  # instead. The cost is measured below.
  #
  # The socket is bound to 127.0.0.1 explicitly. `connection: 0` would listen on
  # every interface, and the first connection accepted is taken to be the peer's
  # - which is a channel that can send messages to named processes on this node.
  # Loopback leaves the window that another process on this host could connect
  # first, in the fraction of a second between the listen and the peer's
  # connect; `:peer` offers nothing to authenticate the other end with. That is
  # worth knowing and small in context, since a host with an untrusted local
  # process on it can already read `releases/COOKIE`.
  #
  # What the socket costs is the diagnosis of a peer that cannot boot. A
  # detached peer's console output goes to the null device before anything can be
  # said, and the origin holds no handle on the process, so a boot that fails is
  # noticed when `wait_boot` expires rather than at once and with the emulator's
  # own reason. That is a poor way to learn that a release is broken, and it was
  # weighed against failing installs that ought to have worked: a boot script
  # that will not boot is a broken release either way, `unpack` has already
  # verified the tarball it came out of, and the preflight below has already
  # established that the script and the emulator are there.
  #
  # It is started linked, so that it cannot outlive the command. Being detached
  # does not change that: the connection is the whole of the peer's attachment to
  # anything, the control process owns this end of it, and the link means that
  # process goes when this one does - so a node that dies mid-install takes the
  # peer with it rather than leaving a VM behind.
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
  # ## The base
  #
  # Every evaluation starts from the configuration Mix wrote, and never from the
  # result of the last one. Providers are not required to be idempotent, and the
  # ones people write are not: `if System.get_env("FEATURE"), do: config ...` in
  # a `runtime.exs` sets a key on a run where the variable is set and says
  # nothing about it on a run where it is not. Resolving over the previous
  # result would leave that key behind, so the version an operator commits would
  # be configured differently from the way it will actually boot - and a boot
  # resolves over the release's own configuration, every time.
  #
  # Which means the release has to keep that configuration. `sys.config` cannot
  # be it, because `sys.config` is what `release_handler` reads and therefore
  # what has to hold the resolved result. So the first materialisation of a
  # version copies it to `sys.config.pristine` and every one after that seeds
  # from there.
  #
  # The copy is staged under a name of its own, given the mode `sys.config` has,
  # and published by hard link - `write_like/3` then `publish/2`. A link is atomic and
  # refuses rather than replaces, so what appears at that name is a file that was
  # already complete, and of two installs racing the loser is told the name is
  # taken and reads what the winner published rather than its own copy. Writing
  # the name directly would not do, even exclusively: an exclusive create makes
  # *creation* atomic, not publication, so the file exists and is empty between
  # the open and the write - long enough for a reader to see something that is
  # not a configuration, and, if the install died there, long enough to leave a
  # truncated base that every later evaluation would prefer to the original
  # still sitting in `sys.config`. Staging that never gets published is left
  # behind under its own name, where nothing reads it: an install cannot tell its
  # own leftovers from another install's work in progress, so it does not try.
  #
  # This is permanent, not a step in the migration. The `build.config` path this
  # sits beside has always had a pristine base - `build.config` *is* one, and
  # `generate/1` only ever reads it - and that is the one thing the old
  # mechanism got right. When step 3 of castle#13 deletes that path, this is
  # what carries the property forward. It is deliberately not *called*
  # `build.config`: that name is the discriminator between the two paths, and a
  # file by that name would send the release back down the one being removed.
  #
  # `sys.config` gains a `CASTLE_MATERIALISED` line when it is written, which is
  # what makes the invariant checkable: written by Castle, so a base must exist.
  # A version whose `sys.config` says that and has no base beside it has lost its
  # original - it was materialised by a Castle that did not keep one, or someone
  # removed it - and is refused rather than having a once-resolved configuration
  # captured as though it were pristine. Unpacking the version again restores
  # what Mix wrote.
  #
  # ## The compile environment
  #
  # Elixir checks a resolved configuration against the values the release was
  # compiled against - `Application.compile_env/3` - and refuses to boot when
  # they disagree. It does that check in the branch that *applies* the
  # configuration, and again on the boot that follows the branch that writes it.
  # This drives the writing branch and there is no boot after it, so neither
  # would happen, and a release Elixir considers unbootable would reach
  # `install_release/1`. So the check is made here, with Elixir's own validator -
  # see `validate_compile_env/2`.
  #
  # Elixir's other boot-time check, that the configuration does not try to
  # configure kernel or stdlib after they have been loaded, is deliberately not
  # reproduced. That one is about whether a configuration can be *applied* to a
  # VM which is already running, which is a property of a boot rather than of the
  # configuration, and the target makes that judgement itself when it boots.
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

  # The configuration as the release was built with it, and the line that says
  # the live one is no longer that.
  @pristine "sys.config.pristine"
  @materialised "%% CASTLE_MATERIALISED=true"

  # Elixir's own private keys, read and written here because this drives
  # Elixir's own pipeline.
  @init_key :config_provider_init
  @booted_key :config_provider_booted

  # Everything that waits, waits with a deadline. A peer that never boots, or
  # that boots and never answers, would otherwise hold an install open for as
  # long as it liked - and all of this runs before `install_release/1`, so an
  # install that never starts is the best outcome left once something has gone
  # wrong. Generous, because a preboot script boots in a fraction of a second
  # and a runtime.exs is compiled: neither is expected to come near them.
  @boot_timeout 30_000
  @resolve_timeout 120_000

  # The control connection: a socket on the loopback interface, on whatever port
  # the system hands out.
  @connection {{127, 0, 0, 1}, 0}

  @typedoc "The outcome of materialisation: nothing to report, or why it failed."
  @type result :: {:ok, [String.t()]} | {:error, String.t()}

  @doc """
  Materialises the configuration of the release whose version directory is
  given, reporting nothing when it succeeds.

  The release root is the directory two levels above, which is where a release
  keeps `lib`, `erts-*` and the `releases` directory this one lives in.

  `:boot_timeout` and `:resolve_timeout` override the deadlines. They are
  options for the same reason `Castle.Commands` takes the module to talk to: a
  deadline nothing can shorten is a deadline no test can prove is enforced.
  """
  @spec materialise(Path.t(), keyword()) :: result()
  def materialise(rel_vsn_dir, opts \\ []) do
    with {:ok, peer} <- plan(rel_vsn_dir, opts),
         {:ok, base} <- base(peer) do
      # A release with no providers has nothing to resolve: what Mix wrote is
      # already its final configuration, and `sys.config` is left exactly as it
      # is rather than rewritten with the same contents. No base is kept for it
      # either - there is nothing that could change it.
      if declares_providers?(base.config), do: expand(peer, base), else: {:ok, []}
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
  # scratch file is what the peer reads and writes, and the rename is the only
  # moment `sys.config` changes.
  defp expand(peer, base) do
    expand_into_scratch(peer, base)
  after
    File.rm(peer.scratch)
  end

  # The scratch file is created through `write_like/3`, so it has
  # `sys.config`'s permissions from before it has any contents - and it holds
  # the most sensitive thing here, the configuration with every provider's
  # answer resolved into it. The writes after that leave the mode alone, and the
  # rename carries it onto `sys.config`.
  defp expand_into_scratch(peer, base) do
    with :ok <- write_like(peer.scratch, base.bytes, peer.sys_config),
         {:ok, config} <- run(peer),
         :ok <- write(peer.scratch, [head(base.header), format(config)]) do
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
        connection: @connection,
        exec: to_charlist(peer.erl),
        args: args(peer),
        env: env(peer),
        wait_boot: peer.boot_timeout,
        shutdown: :close
      })

    {:ok, pid}
  catch
    kind, reason ->
      {:error,
       "Cannot configure #{peer.vsn}: no VM was started from #{peer.boot}.boot within " <>
         "#{peer.boot_timeout}ms. " <> Exception.format(kind, reason, __STACKTRACE__)}
  end

  defp call(pid, peer) do
    case :peer.call(pid, __MODULE__, :resolve, [peer.scratch], peer.resolve_timeout) do
      {:ok, config} when is_list(config) ->
        {:ok, config}

      {:error, message} when is_binary(message) ->
        {:error, "Cannot configure #{peer.vsn}: " <> message}

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

  # `:peer.stop/1` closes the control connection, which the peer halts on: the
  # connection is the whole of its attachment to anything, so losing it is how
  # it is told to go, and how it goes if this node dies instead. Failing to stop
  # a control process that has already gone is not failing to stop the peer, so
  # nothing is made of it.
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

  defp plan(rel_vsn_dir, opts) do
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
         pristine: Path.join(rel_vsn_dir, @pristine),
         staging: Path.join(rel_vsn_dir, "castle-#{System.pid()}-#{unique()}.pristine"),
         scratch: scratch,
         boot_timeout: Keyword.get(opts, :boot_timeout, @boot_timeout),
         resolve_timeout: Keyword.get(opts, :resolve_timeout, @resolve_timeout)
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

  ## sys.config, and the base it is resolved from

  # The base is `sys.config.pristine` once there is one, and `sys.config` itself
  # the first time - which is the only time `sys.config` is known to hold what
  # Mix wrote.
  defp base(peer) do
    if File.regular?(peer.pristine), do: published_base(peer), else: first_base(peer)
  end

  # A base that cannot be read is refused, and the way out of it is named. It is
  # not repairable from here: `sys.config` is the only other copy, and whether
  # that is still the original is exactly what is not known once this file is
  # unreadable.
  defp published_base(peer) do
    case read_base(peer.pristine) do
      {:ok, base} ->
        {:ok, base}

      {:error, message} ->
        {:error,
         message <>
           " It is the configuration #{peer.vsn} was built with, kept so that every " <>
           "evaluation starts from the same place. Remove it, and unpack #{peer.vsn} again " <>
           "as well if #{peer.sys_config} has been resolved since."}
    end
  end

  defp first_base(peer) do
    with {:ok, bytes} <- read(peer.sys_config),
         {:ok, config} <- consult(peer.sys_config) do
      keep_base(peer, %{header: header(bytes), config: config, bytes: bytes})
    end
  end

  # Kept only when there is something that could change it: a release with no
  # providers is never rewritten, so it has nothing to be protected from and
  # gets no second file in its version directory.
  defp keep_base(peer, base) do
    if declares_providers?(base.config) do
      with :ok <- unmaterialised(peer, base.header), do: keep(peer, base)
    else
      {:ok, base}
    end
  end

  # `sys.config` says Castle wrote it and there is no base beside it, so the
  # configuration the release was built with is gone. Capturing what is there
  # would make one run of the providers permanent - which is the thing the base
  # exists to prevent - so it is refused instead.
  defp unmaterialised(peer, header) do
    if @materialised in header do
      {:error,
       "#{peer.sys_config} was written by Castle and #{peer.pristine}, the configuration " <>
         "it was resolved from, is not there. Every evaluation has to start from the " <>
         "configuration the release was built with, and what is there now has already " <>
         "been through one. Unpack #{peer.vsn} again to restore it."}
    else
      :ok
    end
  end

  # Staged under a name of its own and then published, rather than written to
  # the name it will have. An exclusive create makes *creation* atomic, not
  # publication: the file exists and is empty between the open and the write, so
  # a reader could see a base that is not a configuration, and an install that
  # died in that window would leave a truncated one that every later evaluation
  # would prefer to the original still sitting in `sys.config`. A link cannot do
  # that. It publishes a file that is already complete, in one step that either
  # happens or does not, and refuses rather than replaces if the name is taken.
  #
  # Whichever install loses reads the published file, never its own staging
  # copy: the winner's is the one every later evaluation will see, so it is the
  # one this evaluation has to use too.
  defp keep(peer, base) do
    stage_and_publish(peer, base)
  after
    File.rm(peer.staging)
  end

  defp stage_and_publish(peer, base) do
    with :ok <- write_like(peer.staging, base.bytes, peer.sys_config) do
      case publish(peer.staging, peer.pristine) do
        :ok -> {:ok, base}
        :taken -> published_base(peer)
        {:error, _reason} = error -> error
      end
    end
  end

  ## Writing a file that holds configuration
  #
  # There is one way to do it here, and it is `write_like/3`. Every file this
  # module brings into existence holds a release's configuration - the base, and
  # the scratch copy the providers are resolved into - so every one of them has
  # to be no more readable than the `sys.config` it came from or is about to
  # become. An operator who restricts that file has said something, and it has to
  # hold for the copies too.
  #
  # The ordering is the whole of it, and it is inside the primitive rather than
  # remembered at the call sites, because remembering is what failed: the mode
  # is set while the file is still empty, so there is no moment at which it holds
  # a configuration and is wider than it should be. Neither of the obvious ways
  # round has that property. `File.write/2` creates with the process umask and
  # never looks at a mode. `File.cp/2` does carry the mode, but it writes the
  # whole file first and narrows it afterwards
  # (`:file.copy` then `copy_file_mode/2`), which is the same exposure with a
  # shorter window and was twice mistaken here for a fix.
  #
  # These are public, along with `publish/2`, because the intermediate states are
  # the point: a mode that is only ever correct after the content is written
  # looks exactly like a mode that was correct all along, and a window nothing
  # can stand in is a window nothing can test.

  @doc false
  @spec write_like(Path.t(), iodata(), Path.t()) :: :ok | {:error, String.t()}
  def write_like(path, bytes, model) do
    with :ok <- create_like(path, model), do: write(path, bytes)
  end

  @doc false
  @spec create_like(Path.t(), Path.t()) :: :ok | {:error, String.t()}
  def create_like(path, model) do
    with :ok <- write(path, ""), do: carry_mode(model, path)
  end

  @doc false
  @spec publish(Path.t(), Path.t()) :: :ok | :taken | {:error, String.t()}
  def publish(staging, path) do
    case File.ln(staging, path) do
      :ok -> :ok
      {:error, :eexist} -> :taken
      {:error, reason} -> {:error, "Cannot write #{path}. #{format_error(reason)}"}
    end
  end

  defp carry_mode(from, to) do
    case File.stat(from) do
      {:ok, %File.Stat{mode: mode}} -> chmod(to, Bitwise.band(mode, 0o7777))
      {:error, reason} -> {:error, "Cannot read #{from}. #{format_error(reason)}"}
    end
  end

  defp read_base(path) do
    with {:ok, bytes} <- read(path), {:ok, config} <- consult(path) do
      {:ok, %{header: header(bytes), config: config, bytes: bytes}}
    end
  end

  defp header(contents) do
    contents |> String.split("\n") |> Enum.take_while(&String.starts_with?(&1, "%%"))
  end

  # The comment header Mix wrote above the term is kept, because the launcher
  # reads it: `RUNTIME_CONFIG=true` is what tells the launcher to boot from a
  # copy of this file rather than from the file itself, which is what keeps a
  # release that reboots after configuring it from rewriting itself. Re-emitting
  # the term without the header would change how the version boots. Mix's
  # `coding` pragma stays first, where the emulator looks for it, and the line
  # saying Castle wrote this goes after - taken from the base, which never has
  # one, so it cannot accumulate.
  defp head(header), do: Enum.map(header ++ [@materialised], &[&1, ?\n])

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

  # Everything the pipeline writes has to leave this VM through the control
  # connection, because nothing else it writes leaves at all.
  #
  # A peer reached over a socket is detached, so its file descriptors are the
  # null device: what a provider writes to standard error - and Elixir's own
  # account of a provider that raised is written there - would be discarded, and
  # the operator would be told that an install failed without being told what
  # the provider said. What goes through this VM's `user` process does travel the
  # connection, so standard error is pointed at the same place. A relay, because
  # a process can hold one registered name and `user` has one; requests are
  # passed on untouched, so it is `user` that answers whoever asked.
  #
  # Discarding is the safe direction to fail, which is the point of the socket:
  # a raw write that cannot reach the channel cannot corrupt it either.
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
      :written -> resolved(path, provider)
      other -> {:error, "Evaluating #{path} answered #{inspect(other)} instead of writing it."}
    end
  end

  defp resolved(path, provider) do
    with {:ok, config} <- consult(path), do: validated(strip_booted(config), provider)
  end

  # The marker Elixir adds on its way to a reboot says "the providers have run
  # already for this boot", and this was not a boot. Left in, it would tell the
  # target to skip its providers the next time it starts cold, freezing its
  # configuration as of the upgrade.
  defp strip_booted(config) do
    Keyword.replace_lazy(config, :elixir, &Keyword.delete(&1, @booted_key))
  end

  # The check Elixir would have made had it applied this configuration, or had
  # it rebooted into it: that what `Application.compile_env/3` read when the
  # release was compiled is what the resolved configuration says now. Neither
  # happens here - the pipeline was asked to write, and nothing boots afterwards
  # - so a release Elixir considers unbootable would otherwise be installed and
  # discovered on the way up, where the only way out is a rollback.
  #
  # Made with Elixir's own validator, and in the way Elixir makes it: the
  # resolved values are put into this VM's application environment first,
  # because that is where the validator reads them from. Persistently, so that
  # loading an application to read its environment cannot overwrite them with
  # the defaults from its `.app` file. Only the applications the check names,
  # since those are the only ones it reads and this VM has no other use for
  # them.
  #
  # `false` and `[]` are what a release with the check turned off and a release
  # with nothing to check look like. Anything else is refused rather than
  # skipped: if what Elixir puts here ever stops being a list of triples, this
  # has to stop and say so, not quietly pass everything.
  defp validated(config, provider) do
    case provider.validate_compile_env do
      [_ | _] = compile_env -> validate(config, compile_env)
      false -> {:ok, config}
      [] -> {:ok, config}
      other -> {:error, "Cannot check the compile environment, which is #{inspect(other)}."}
    end
  end

  defp validate(config, compile_env) do
    apps = compile_env |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
    Application.put_all_env(Keyword.take(config, apps), persistent: true)

    case Config.Provider.validate_compile_env(compile_env) do
      :ok -> {:ok, config}
      {:error, message} -> {:error, message}
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

  defp write(path, contents) do
    case File.write(path, contents) do
      :ok -> :ok
      {:error, reason} -> {:error, "Cannot write #{path}. #{format_error(reason)}"}
    end
  end

  defp chmod(path, mode) do
    case File.chmod(path, mode) do
      :ok -> :ok
      {:error, reason} -> {:error, "Cannot set the mode of #{path}. #{format_error(reason)}"}
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
