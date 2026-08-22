defmodule Castle.Commands do
  @moduledoc false

  # A filesystem that reports no inode numbers has not said the two directories
  # differ; it has said nothing, which is a different answer.
  @no_inode "the filesystem reports no inode numbers, so the two cannot be compared"

  # The implementation of each of Castle's commands, held apart from the
  # command boundary in `Castle` so that it can be exercised without a booted
  # release:
  #
  #   * every function returns its outcome - the lines to print, or the message
  #     describing the failure - instead of printing or raising, and
  #   * every function that talks to `:release_handler`, to `Castle.Peer` or to
  #     the deployment itself takes the module to talk to, so a test can hand it
  #     a stub.
  #
  # The module argument is the smallest seam that keeps `Castle`'s own
  # signatures - the ones `bin/castle` and `env.sh` call - unchanged. Nothing
  # outside `Castle` is meant to call this module.

  @typedoc """
  The outcome of a command: the lines to report, or the message to fail with.
  """
  @type result :: {:ok, [String.t()]} | {:error, String.t()}

  @doc """
  Creates the `RELEASES` file in `rel_dir` from the running permanent release.

  Does nothing if the file already exists.

  The directory is an argument because that is what makes this testable, not
  because a caller gets to choose it: `Castle.make_releases/0` derives it from
  the root of the release - `code:root_dir()`, never the working directory. So
  the working directory was only ever visible to the check below, which is what
  made it possible for the file this looked for and the file `create_RELEASES/3`
  wrote to be different ones. Nothing has to change directory to call this, and
  nothing should.

  That derivation is right for a release Mix built and not in general;
  `Castle.Deployment.root_dir/0` is the one place that explains why, and
  castle#23 is the gap.

  Refuses a release that did not bring its own ERTS - see `ensure_own_erts/2`
  below - and refuses it *before* looking for the file, not after. The whole
  point of the refusal is that `rel_dir` names the Erlang installation rather
  than the deployment on such a release, and an Erlang installation assembled by
  OTP's own build has a `releases/RELEASES` of its own: the file is found, this
  reports success, and nothing ever says that the deployment cannot be upgraded.
  """
  @spec make_releases(Path.t(), module(), module()) :: result()
  def make_releases(rel_dir, handler \\ :release_handler, deployment \\ Castle.Deployment) do
    releases_file = Path.join(rel_dir, "RELEASES")

    with :ok <- ensure_own_erts("Cannot create #{releases_file}", deployment) do
      if File.exists?(releases_file) do
        {:ok, []}
      else
        {:ok, _} = Application.ensure_all_started(:sasl)
        create_releases(rel_dir, releases_file, handler)
      end
    end
  end

  # `create_RELEASES/3`, and not `/4` with the root supplied. The three-argument
  # form is `create_RELEASES("", RelDir, RelFile, LibDirs)`, and `check_rel_data/4`
  # keys off that empty `Root`: with it, each library directory is stored as
  # `lib/<app>-<vsn>` - "to make it easy to create a relocatable RELEASES file",
  # in OTP's own comment - and with a root supplied, as an absolute path under
  # it. Passing the root would therefore write this machine's paths into a file
  # whose whole point is that it can be moved, and nothing would notice until it
  # was.
  defp create_releases(rel_dir, releases_file, handler) do
    case handler.which_releases(:permanent) do
      [{name, vsn, _, _}] ->
        # `vsn` arrives as a charlist, which `Path.join/1` takes as chardata.
        relfile = Path.join([rel_dir, vsn, "#{name}.rel"])

        # credo:disable-for-next-line Credo.Check.Readability.FunctionNames
        case handler.create_RELEASES(to_charlist(rel_dir), relfile, []) do
          :ok ->
            {:ok, []}

          {:error, reason} ->
            {:error, "Cannot create #{releases_file} from #{relfile}. #{inspect(reason)}"}
        end

      [] ->
        {:error, "Cannot create #{releases_file}: no release is running as permanent."}

      releases ->
        vsns = Enum.map_join(releases, ", ", fn {_, vsn, _, _} -> vsn end)

        {:error, "Cannot create #{releases_file}: expected one permanent release, found #{vsns}."}
    end
  end

  ## The ERTS guard
  #
  # This is the reference account of why `include_erts: false` and Castle are
  # incompatible. `Castle.Peer.emulator/2` refuses the same deployment from a
  # narrower angle - it needs an emulator under the root and finds none - and
  # points here rather than restating any of it.
  #
  # `Mix.Release.copy_erts/1` has a clause for `%{erts_source: nil}` that copies
  # nothing, and the `erl` shim that rewrites `ROOTDIR` to the release root is
  # written only by the other one. `include_erts: false` is what sets
  # `erts_source` to nil (`erts_data(false)`), and `releases/<vsn>/elixir` keeps
  # its `ERTS_BIN="$ERTS_BIN"` line unrewritten, so the launcher runs whichever
  # `erl` is on the path. That emulator's `-root` is the Erlang installation, so
  # `code:root_dir()` names the installation and not the deployment.
  #
  # Which matters because `code:root_dir()` is `:release_handler`'s own anchor,
  # not Castle's choice of one - `Castle.Deployment.root_dir/0` sets out what it
  # anchors and what it does not, and is the only place that should. The half
  # this rests on is the applications: extraction, every `lib/<app>-<vsn>` the
  # handler resolves, and the `erts-<vsn>` a removal deletes. Those cannot be
  # relocated, which is why relocating the *records* - the half that can be, with
  # `RELDIR` or `{sasl, releases_dir}` - is not a way out of this refusal.
  #
  # **Do not "fix" this by deriving the root from `RELEASE_ROOT`.** It reads like
  # the obvious remedy and it is the worse one: Castle would put the
  # configuration somewhere `:release_handler` never looks, and an upgrade would
  # go on using applications under the installation. A loud refusal is better
  # than a silent divergence, and there is no root Castle may choose
  # that makes such a release upgradable.
  #
  # The question is asked of the node, and there is one implementation of it.
  # A shell-side gate in Forecastle's `env.sh` would spare the deployment a
  # preboot VM and a refusal on every start - `RELEASES` never appears, so the
  # hook runs every time - and it was refused anyway: a shell test can only
  # approximate what the node knows, which is the class of bug the third step of
  # castle#13 removed, and a second implementation of the rule can drift from
  # this one. The cost of one VM start per boot of a deployment that cannot be
  # upgraded is accepted deliberately. Do not add the shell gate.
  #
  # The evidence is that every launcher `mix release` generates exports
  # `RELEASE_ROOT` from its own location before it sources `env.sh`, so a set
  # `RELEASE_ROOT` that does not name `code:root_dir()` is exact: the deployment
  # is one directory and the emulator's root is another. Nothing else sets the
  # variable, so outside a release - under `mix test`, or in a VM started by
  # hand - there is nothing to compare and the guard is inert, which is what
  # makes it safe to put in front of every mutating operation.
  #
  # `refusal` names the operation, for the reason `ensure_upgradable/2`'s does:
  # what an operator needs told is that the thing they asked for did not happen.
  defp ensure_own_erts(refusal, deployment) do
    case deployment.release_root() do
      release_root when release_root in [nil, ""] ->
        :ok

      release_root ->
        root_dir = deployment.root_dir()

        case compare_dirs(release_root, root_dir, deployment) do
          :same -> :ok
          :different -> {:error, refused_root(refusal, release_root, root_dir)}
          {:indeterminate, why} -> {:error, refused_unknown(refusal, why)}
        end
    end
  end

  # Two directories are the whole of the evidence, so the message reports the
  # divergence and offers causes as examples rather than as a closed set. The
  # usual one is `include_erts: false`, which ships no emulator; another is an
  # `ERL_ROOTDIR` in the environment, which the `erl` shim Mix writes honours
  # ahead of the release's own location (`ROOTDIR="${ERL_ROOTDIR:-...}"`). There
  # is no way to tell them apart from here, and no reason to think they exhaust
  # the possibilities. An earlier version of this message asserted the first,
  # and its replacement asserted the second as the only alternative; both were
  # wrong in the same way, which is why this one asserts no cause at all.
  #
  # It also no longer claims that *everything* `:release_handler` touches
  # resolves under the emulator's root, because the release records alone do
  # not: `init/1` takes its releases directory from `{sasl, releases_dir}`, then
  # `RELDIR`, and only then `init:get_argument(root)`, so those two can relocate
  # it. What cannot be relocated is what makes the refusal correct anyway. The
  # handler holds the root and the releases directory as separate state, and
  # only the second follows `RELDIR`: `do_unpack_release/4` extracts through
  # `extract_tar(Root, Tar)`, `check_rel_data/4` records library directories as
  # `lib/<app>-<vsn>` to be resolved against `code:root_dir()`, and
  # `do_remove_release/4` deletes `filename:join(Root, "erts-" ++ EVsn)`. So
  # relocating the records moves the bookkeeping and leaves the applications
  # themselves being extracted into, read from and deleted out of the emulator's
  # root. Saying so is the difference between a refusal an operator can act on
  # and one that sends them to rebuild something that was not the problem.
  defp refused_root(refusal, release_root, root_dir) do
    "#{refusal}: the deployment and the emulator's root are different " <>
      "directories - the deployment is #{release_root} and the emulator runs " <>
      "in #{root_dir}. That is where :release_handler extracts applications, " <>
      "resolves every lib/<app>-<vsn> it reads, and deletes erts-<vsn> from, " <>
      "because those paths are anchored to the emulator's root rather than to " <>
      "the deployment. Pointing Castle at the deployment instead would only " <>
      "move the release records away from the applications they describe. " <>
      "Relocating the records with RELDIR or the sasl releases_dir parameter " <>
      "does not help either, for the same reason: it moves the bookkeeping and " <>
      "leaves the applications where they were. Common causes are building the " <>
      "release with include_erts: false, which ships no emulator of its own, " <>
      "and an ERL_ROOTDIR in the environment, which the release's erl honours " <>
      "ahead of its own location; there may be others. This deployment cannot " <>
      "be upgraded by Castle until the two directories are the same one."
  end

  # The refusal for a comparison that could not be made. It says what was not
  # established rather than what was found, because nothing was found, and it
  # names the operation and the reason so the remedy is the reason's rather than
  # this guard's - a mode on a parent directory, a broken link, a path that is
  # not there. It still refuses: the deployment may well be sound, but writing
  # release records into a tree that has not been shown to be the right one is
  # the failure this guard exists to prevent, and it is the one of the two that
  # cannot be undone by looking again.
  defp refused_unknown(refusal, why) do
    "#{refusal}: cannot tell whether the deployment and the emulator's root are " <>
      "the same directory - #{why}. They are not the same path, so the question " <>
      "was put to the filesystem, and it did not answer. Castle refuses rather " <>
      "than assume: if they are two directories then :release_handler resolves " <>
      "the applications under the emulator's root and not under the deployment, " <>
      "and release records written on the assumption that they are one would " <>
      "describe applications somewhere else. Resolve what stopped the lookup " <>
      "and ask again."
  end

  # Whether two paths name the same directory: `:same`, `:different`, or
  # `{:indeterminate, why}`. Both of the ones compared here are produced by
  # `pwd -P` in scripts Mix generates - `RELEASE_ROOT` in the launcher, and
  # `ROOTDIR` in the `erl` shim, from a `BINDIR` two levels below it - so on an
  # ordinary release they are the same string and `Path.expand/1`, which settles
  # a trailing separator and a relative spelling, is enough.
  #
  # The `stat` is for the deployment where they are not: a launcher that spells
  # one of them through a symlink, which is ordinary enough in a deployment with
  # a `current` link, would otherwise have a release that brings its own ERTS
  # refused. Refusing a working deployment is the one failure of this guard that
  # cannot be worked around, so it is worth two `stat` calls to avoid.
  #
  # **The third answer is not decoration.** A `stat` that fails - `:eacces` on a
  # parent, `:eloop`, `:enoent`, a path that is not there yet - and a filesystem
  # reporting no inode numbers are both *absence of evidence*, and collapsing
  # them into `:different` is how an inconclusive comparison comes to be reported
  # as a fact. The paths have already failed to match as strings by the time this
  # runs, so that catch-all was the whole of what stood between a transient
  # `:eacces` and a message telling an operator their two directories differ.
  # Distinguishing them changes no outcome - both still refuse, because a
  # comparison that cannot be made is no licence to write into a tree that might
  # be the wrong one - but it changes what is *said*, and that is the part an
  # operator acts on. Do not fold these back together.
  defp compare_dirs(one, other, deployment) do
    if Path.expand(one) == Path.expand(other),
      do: :same,
      else: identify(one, other, deployment)
  end

  defp identify(one, other, deployment) do
    case {deployment.stat(one), deployment.stat(other)} do
      {{:ok, one_stat}, {:ok, other_stat}} -> by_inode(one_stat, other_stat)
      {{:error, reason}, _} -> {:indeterminate, "#{one} could not be read (#{reason})"}
      {_, {:error, reason}} -> {:indeterminate, "#{other} could not be read (#{reason})"}
    end
  end

  defp by_inode(%File.Stat{major_device: device, inode: inode}, %File.Stat{
         major_device: device,
         inode: inode
       })
       when inode != 0,
       do: :same

  defp by_inode(%File.Stat{inode: 0}, _), do: {:indeterminate, @no_inode}
  defp by_inode(_, %File.Stat{inode: 0}), do: {:indeterminate, @no_inode}
  defp by_inode(_, _), do: :different

  @doc """
  Confirms that the running release can be upgraded from.

  `:release_handler` reads `RELEASES` once, in its `init/1`, and when it cannot
  it synthesises a record out of the boot script's name and version instead -
  `[#release{name = Name, vsn = Vsn, status = permanent}]`, leaving the `libs`
  field at its default of `[]`. That record is what such a node then works from
  for the rest of its life: creating the file afterwards changes nothing, and
  the first operation that changes anything writes the in-memory record straight
  back over it.

  Upgrading from it is worse than being refused. The library directories a
  release is loaded from are switched at the relup's `point_of_no_return`, which
  calls `code:replace_path/2` over `get_new_libs(Current, New)` - the
  applications whose version differs between the two records - together with
  whichever ones the relup loads object code for. `get_new_libs/2` folds over
  the *current* release's applications, and `get_new_libs([], _) -> []`, so a
  record that names none switches nothing: an application whose version did
  change, and whose code the relup does not explicitly load, goes on running
  from the library directory of the release being replaced. The install reports
  success, and that directory survives until the next `remove` deletes it.

  The discriminator is that empty application list, and it is exact: the list
  `which_releases/0` reports is `mk_lib_name(Libs)`, `mk_lib_name([]) -> []`,
  and a record read from `RELEASES` names at least `kernel` and `stdlib`. So
  emptiness distinguishes the synthesised record from every real one, which
  testing for the file cannot do - a file that appeared after the boot that
  looked for it passes that test and leaves the node on the synthesised record
  regardless.

  The running release is selected the way `running/3` selects it: the `current`
  one if there is one, and the `permanent` one otherwise.

  This is the question on its own, for an operator who wants it answered without
  acting on the answer. It is not what protects an upgrade: `unpack/3` and
  `install/3` ask it themselves, from inside the operation, because an answer
  given to one caller and acted on by another is an answer about a moment that
  has passed - the node can restart in between, and the node that comes back
  synthesises the record afresh. Nothing has to call this first, and putting it
  back in front of them would not make them safer.

  It is not gated on the release bringing its own ERTS, and neither is
  `releases/1`. Both only read, and both are what an operator needs working in
  order to make sense of the state `ensure_own_erts/2` refuses: a deployment told
  that it cannot be upgraded has to be able to ask what the node thinks it is
  running. Gating a diagnostic on the condition it diagnoses leaves nothing to
  ask.
  """
  @spec upgradable(module()) :: result()
  def upgradable(handler \\ :release_handler) do
    case ensure_upgradable("This system cannot be upgraded", handler) do
      :ok -> {:ok, []}
      refusal -> refusal
    end
  end

  # The check `unpack/3` and `install/3` make before they touch
  # `:release_handler`, and what `upgradable/1` answers on its own.
  #
  # `refusal` is what the message leads with, and it names the operation rather
  # than the state: this is not a precondition an operator forgot to ask about,
  # it is the unpack or the install refusing, and what they need told is that it
  # did not happen.
  defp ensure_upgradable(refusal, handler) do
    case running_release(handler) do
      {_vsn, [_ | _]} ->
        :ok

      {vsn, []} ->
        {:error,
         "#{refusal}: #{vsn} is running from a release record OTP built from the boot " <>
           "script, which names no applications - releases/RELEASES was missing, or could " <>
           "not be read, when the system booted. An upgrade from that record reports " <>
           "success and leaves any application whose version changed, but whose code the " <>
           "upgrade does not load, running its old code. Creating the file now would not " <>
           "change the record this node works from, so the system has to be restarted. " <>
           "Before restarting, make sure the RELEASES file :release_handler reads is " <>
           "either absent or one it can consult - it reads that file with file:consult/1, " <>
           "so a malformed one fails exactly as an unreadable one does, and permissions " <>
           "are not the whole of the condition. The release creates that file only when " <>
           "it is absent, so anything left in place that cannot be consulted is stepped " <>
           "over on every start and the system comes back on the same synthesised " <>
           "record. Absent, or consultable, is what a restart needs. That file is " <>
           "releases/RELEASES under the release root unless RELDIR or the sasl " <>
           "releases_dir parameter points elsewhere; where one of those does, the release " <>
           "creates a file at the root that the handler will not read, so the one it does " <>
           "read has to be put there by hand."}

      nil ->
        {:error, "#{refusal}: no release is running."}
    end
  end

  @doc """
  Materialises the configuration of the release in `rel_vsn_dir`.

  There is one way to do that: in a VM of its own, running the target's own
  provider modules over the target's own configuration, which is what
  `Castle.Peer` does. A provider module can differ between the version that is
  running and the version being installed - that is precisely what an upgrade
  may change - so the running node is not a place where the answer can be
  worked out.

  What is left here is the one thing the peer cannot say well: that there is no
  release at that path to configure at all. The peer's own refusals name a file
  the version is missing, or something its providers did - the right answers for
  a release that was unpacked and then damaged, and the wrong ones for a version
  that was never unpacked. So a version directory that is absent, empty, or not
  a directory is answered here, where the remedy can be named.

  The module is an argument for the same reason `:release_handler` is: so that a
  test can see what was asked of it without starting a VM.

  Gated on the release bringing its own ERTS - see `ensure_own_erts/2` - because
  `Castle.install/1` and `Castle.commit/1` do this first, and `rel_vsn_dir` is
  derived from `code:root_dir()`: without the guard the operator's first news of
  an ERTS-less deployment is that some version directory inside the Erlang
  installation holds no release to configure, which is true and says nothing
  about why.
  """
  @spec materialise(Path.t(), module(), module()) :: result()
  def materialise(rel_vsn_dir, peer \\ Castle.Peer, deployment \\ Castle.Deployment) do
    vsn = Path.basename(rel_vsn_dir)

    with :ok <- ensure_own_erts("Cannot configure #{vsn}", deployment) do
      case File.ls(rel_vsn_dir) do
        {:ok, [_ | _]} ->
          peer.materialise(rel_vsn_dir)

        nothing ->
          {:error,
           "Cannot configure #{vsn}: " <>
             "#{rel_vsn_dir} #{describe(nothing)}. Unpack the release first."}
      end
    end
  end

  defp describe({:ok, []}), do: "is empty"
  defp describe({:error, :enoent}), do: "does not exist"
  defp describe({:error, reason}), do: "cannot be read (#{:file.format_error(reason)})"

  @doc """
  Unpacks the named release tarball.

  Refuses a system running from the record `:release_handler` synthesised for
  itself - see `upgradable/1` for what that record is and why an upgrade from it
  is worse than being stopped - and refuses it here, in the same call that would
  have done the unpacking, rather than leaving a caller to ask first. Two calls
  are two moments and possibly two node instances: a node can pass the question
  on the strength of a record it read at boot and restart, onto a synthesised
  one, before the second call arrives. The answer is only good for the call that
  acts on it.

  Unpacking is checked as well as installing, and not because `unpack_release/1`
  compares release records - it does not, and an unpack cannot switch a code
  path. It is because it is the one other operation that *writes* them:
  `do_unpack_release/4` ends in `write_releases/3` over the records the handler
  holds, so unpacking on such a node puts the synthesised record - the one that
  names no applications - into `RELEASES`, where the next boot reads it back as
  though it had always been there. The remedy the refusal names is a restart,
  and a restart only works while the file is absent, because
  `Castle.make_releases/0` does nothing when it is there. An unpack allowed
  through would take that remedy away and leave the system with no way back.

  Refuses a release that did not bring its own ERTS first of all - see
  `ensure_own_erts/2` - because on such a deployment `unpack_release/1` would
  unpack the tarball into the Erlang installation, and because the record the
  node holds is the installation's, so the record check would have nothing to
  say about it.
  """
  @spec unpack(String.t(), module(), module()) :: result()
  def unpack(name, handler \\ :release_handler, deployment \\ Castle.Deployment) do
    with :ok <- ensure_own_erts("Cannot unpack #{name}", deployment),
         :ok <- ensure_upgradable("Cannot unpack #{name}", handler) do
      case handler.unpack_release(to_charlist(name)) do
        {:ok, vsn} -> {:ok, ["Unpacked #{vsn} ok"]}
        {:error, reason} -> {:error, "Failed to unpack #{name}. #{inspect(reason)}"}
      end
    end
  end

  @doc """
  Installs `vsn` and makes it the version that is running now.

  Refuses, before `install_release/1` is asked for anything, a system running
  from the record `:release_handler` synthesised for itself - see `upgradable/1`
  for what such an install would silently leave behind. This is the operation the
  check exists for, and it is made here, in the same call, for the reason
  `unpack/3` makes it: a check a caller makes in a call of its own is a statement
  about the node that answered it, and the node that acts may be a later one that
  has restarted onto a synthesised record.

  `commit/3`, `remove/3` and `releases/1` are not checked *for the record*, and
  that is not an omission. None of them can write the synthesised record back:
  `do_make_permanent/2` returns early for a release that is already permanent
  and errors for every other status, `do_remove_release/4` refuses the permanent
  release outright, and `releases/1` only reads. What checking them could do is
  refuse an upgrade that is already under way - a version installed and waiting
  to be committed, which a refusal would strand until the next restart put the
  previous release back.

  The ERTS guard, `ensure_own_erts/2`, is on a different footing and `commit/3`
  and `remove/3` do carry it: it says the deployment could never have been
  upgraded at all, so there is no upgrade under way for it to strand, and what
  those operations would otherwise act on is the Erlang installation. Only the
  read-only `upgradable/1` and `releases/1` are without it.
  """
  @spec install(String.t(), module(), module()) :: result()
  def install(vsn, handler \\ :release_handler, deployment \\ Castle.Deployment) do
    with :ok <- ensure_own_erts("Cannot install #{vsn}", deployment),
         :ok <- ensure_upgradable("Cannot install #{vsn}", handler) do
      case handler.install_release(to_charlist(vsn)) do
        {:ok, other_vsn, _descr} ->
          {:ok, ["Now running #{vsn} (previously #{other_vsn})."]}

        # The emulator, or one of kernel, stdlib and sasl, is being replaced, so
        # the node reboots and the upgrade instructions run after it comes back.
        # Nothing has failed.
        {:continue_after_restart, other_vsn, _descr} ->
          {:ok,
           [
             "Restarting to install #{vsn} (previously #{other_vsn}).",
             "The upgrade continues once the emulator has restarted."
           ]}

        {:error, reason} ->
          {:error, "Install of #{vsn} failed. #{inspect(reason)}"}

        other ->
          {:error, "Install of #{vsn} returned an unexpected result. #{inspect(other)}"}
      end
    end
  end

  @doc """
  Confirms that `vsn` is the release the system is running.

  What `install_release/1` replies says only that the upgrade was accepted. A
  transition that restarts the emulator is replied to and *then* rebooted, and
  for an emulator upgrade the instructions run on the way back up, where they
  can still fail and roll back - so completion has to be observed rather than
  inferred, and the reply does not say which kind of transition it was. This is
  what a caller polls to observe it.

  The running release is the one whose status is `:current` if there is one,
  and the `:permanent` one otherwise: `install` leaves its target `:current`,
  `commit` promotes it to `:permanent`, and both are running. No other status
  is - notably `:unpacked`, which is what a rolled-back continuation leaves the
  target as, and `:tmp_current`, which is written before the reboot a restart
  transition has yet to make.

  Being the running release is necessary but not sufficient, because a node
  that restarted into it can be seen part-way up. `release_handler` records the
  new version as `:current` while `sasl` starts, and distribution is already
  answering by then - so a reply is available before the applications after
  `sasl` have started, and one of them can still fail the boot and take the
  system back to the previous permanent release. Committing on the strength of
  that would make a version that cannot boot the permanent one. So the boot has
  to have finished too, which is what the second condition below is for.
  """
  @spec running(String.t(), module(), module()) :: result()
  def running(vsn, handler \\ :release_handler, init \\ :init) do
    case running_release(handler) do
      {^vsn, _apps} -> booted(vsn, init)
      nil -> {:error, "#{vsn} is not the running release. No release is running."}
      {other, _apps} -> {:error, "#{vsn} is not the running release. #{other} is."}
    end
  end

  # `init:get_status/0` answers `{InternalStatus, ProvidedStatus}`, and only the
  # second element is any use here. The internal one stays `:starting` for as
  # long as the boot process is alive, which is the whole life of a release
  # started by its boot script - a booted node reports `{:starting, :started}`,
  # so waiting for `{:started, _}` would wait forever.
  #
  # The provided status is what the boot script's `{progress, _}` instructions
  # set (init.erl:692), and `:started` is the last of them. Every boot script
  # Mix generates ends with `{progress, started}`, after the instruction that
  # starts the release's own applications; the hybrid script that continues an
  # emulator upgrade has `release_handler:new_emulator_upgrade/2` applied just
  # before that same marker (systools_make.erl:336). So a provided status of
  # `:started` means the script ran to the end: applications up, and any
  # continuation of the upgrade finished.
  #
  # The marker is the whole of the evidence, so this trusts whichever boot
  # script was selected to emit it where it means what it says. One that never
  # reaches it is never confirmed - `install` waits, then fails, and the message
  # below names the progress the node did reach - and one that emits it early
  # defeats the check. Mix generates these scripts; both states take an operator
  # writing their own and pointing RELEASE_BOOT_SCRIPT at it.
  defp booted(vsn, init) do
    case init.get_status() do
      {_internal, :started} ->
        {:ok, []}

      {_internal, progress} ->
        {:error,
         "#{vsn} is the running release but has not finished booting: #{inspect(progress)}."}
    end
  end

  # The release the system is running, as `{vsn, apps}`, or `nil` if there is
  # none. The application list comes along because `upgradable/1` reads it, and
  # both questions have to be asked of the same release.
  defp running_release(handler) do
    releases =
      for {_, vsn, apps, status} <- handler.which_releases(),
          do: {to_string(vsn), apps, status}

    case with_status(releases, :current) do
      nil -> with_status(releases, :permanent)
      running -> running
    end
  end

  defp with_status(releases, wanted) do
    Enum.find_value(releases, fn {vsn, apps, status} -> if status == wanted, do: {vsn, apps} end)
  end

  @doc """
  Makes `vsn` permanent, so that it is the version a restart boots into.

  Refuses a release that did not bring its own ERTS - see `ensure_own_erts/2` -
  which is the one check this operation makes. `make_permanent/1` rewrites
  `releases/RELEASES` and `releases/start_erl.data`, which on a release Mix
  built sit under `code:root_dir()`, so on such a deployment it would be
  promoting a version of the Erlang installation. Those two are the *records*,
  so they are the relocatable half - see `Castle.Deployment.root_dir/0` - but
  the version it would be promoting is the installation's either way.
  """
  @spec commit(String.t(), module(), module()) :: result()
  def commit(vsn, handler \\ :release_handler, deployment \\ Castle.Deployment) do
    with :ok <- ensure_own_erts("Cannot commit #{vsn}", deployment) do
      case handler.make_permanent(to_charlist(vsn)) do
        :ok -> {:ok, ["Committed #{vsn}. System restarts will now boot into this version."]}
        {:error, reason} -> {:error, "Commit of #{vsn} failed. #{inspect(reason)}"}
      end
    end
  end

  @doc """
  Removes `vsn` from the system.

  Refuses a release that did not bring its own ERTS - see `ensure_own_erts/2` -
  and of everything gated this is the operation with the most to lose by not
  being: `remove_release/1` *deletes*, and the library directories and
  `erts-<vsn>` it takes away are resolved against `code:root_dir()` - the anchor
  nothing can relocate - so on such a deployment it is the Erlang installation
  it would be asked to delete out of.
  """
  @spec remove(String.t(), module(), module()) :: result()
  def remove(vsn, handler \\ :release_handler, deployment \\ Castle.Deployment) do
    with :ok <- ensure_own_erts("Cannot remove #{vsn}", deployment) do
      case handler.remove_release(to_charlist(vsn)) do
        :ok -> {:ok, ["Removed #{vsn}."]}
        {:error, reason} -> {:error, "Removal of #{vsn} failed. #{inspect(reason)}"}
      end
    end
  end

  @doc """
  Lists the releases known to the system, and the status of each.

  Reports no lines at all when the system knows of no releases, rather than
  failing over the column width of an empty table.

  Ungated, like `upgradable/1`: it only reads, and an operator whose deployment
  has just been refused for its ERTS needs to be able to ask what the node
  believes it is running. See `upgradable/1`.
  """
  @spec releases(module()) :: result()
  def releases(handler \\ :release_handler) do
    vsns =
      for {_, vsn, _, status} <- handler.which_releases() do
        {to_string(vsn), to_string(status)}
      end

    width = Enum.reduce(vsns, 0, fn {vsn, _}, widest -> max(widest, String.length(vsn)) end)

    {:ok, for({vsn, status} <- vsns, do: "#{String.pad_trailing(vsn, width + 2)}#{status}")}
  end
end
