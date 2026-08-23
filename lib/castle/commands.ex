defmodule Castle.Commands do
  @moduledoc false

  # `Castle.Peer` appears here twice over, and the two must not be conflated.
  # `materialise/3` reaches it through a module *argument*, because what it does
  # there is start a VM and a test has to be able to stand in for that. The
  # restart marker uses the filesystem primitives on it directly - `work_dir/1`,
  # `write_private/2`, `publish/2` - because those start nothing, and because
  # what they guarantee is exactly what arming a marker needs. Do not inject
  # them: a stub would prove nothing, and the guarantee is the point.
  alias Castle.Peer

  # A filesystem that reports no inode numbers has not said the two directories
  # differ; it has said nothing, which is a different answer.
  @no_inode "the filesystem reports no inode numbers, so the two cannot be compared"

  # The file `install/4` arms before a transition that reboots the emulator, and
  # the launcher's `env.sh` fragment consumes on the next start. It sits beside
  # the release records, and it is named to be unmistakable: nothing else writes
  # it, and a human who finds one knows what it is for.
  #
  # It exists because `releases/new_start_erl.data` on its own is not evidence.
  # `prepare_restart_new_emulator/7` writes that file *before* the reboot and
  # nothing ever removes it, so a preparation that failed after writing it - and
  # `transform_release/3` reconciles the release record without touching the
  # file - leaves one naming a version that was never installed. The two
  # together are the evidence: OTP's file says which version, and this one says
  # that Castle asked for the reboot that would boot it.
  #
  # **Agreeing on a version is not enough, and believing it was is what
  # `arm_restart/4` had to be rewritten for.** Two files that merely name the
  # same version say nothing about being the work of one install: a failed
  # attempt to X leaves OTP's file naming X, a retry to X arms a fresh marker
  # beside it, and a hard restart before the retry reaches `install_release/1`
  # then presents a matching pair for an install that never happened - the node
  # boots X with OTP's records calling it `unpacked`. So the pair has to belong
  # to one *attempt*, which is `@provisional_marker` being cleared before the
  # marker is armed, the marker being published exclusively, and the marker
  # naming the attempt that wrote it. See `arm_restart/4`.
  #
  # Those three are about one caller's sequence, and they are not on their own
  # enough either: two callers can run the sequence at once, and then the loser
  # clears the winner's `@provisional_marker` after the winner has written it.
  # So the whole of the install - including the read and the classification in
  # front of it - is serialised on this node. See `serialised/2`.
  @restart_marker "castle-restart-pending"

  # OTP's half of the pair, written by `prepare_restart_new_emulator/7` and
  # removed by nothing. Cleared before arming, which is what makes the pair
  # evidence about one attempt rather than about a version.
  @provisional_marker "new_start_erl.data"

  # The two instructions `release_handler` treats as "reboot the emulator", and
  # what `do_install_release/3` does with each. Only the one-stage instruction is
  # a transition the launcher can select the target of; see `restart_planned?/3`.
  @one_stage :restart_emulator
  @two_stage :restart_new_emulator

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
    refuse_synthesised(refusal, running_release(handler))
  end

  # The same rule over a running release that has already been asked for.
  # `install/4` needs it twice - the record check, and which relup entry the
  # transition will be evaluated from - and `which_releases/0` must be asked once:
  # two calls are two moments, which is the whole point of the check being inside
  # the operation.
  defp refuse_synthesised(refusal, running) do
    case running do
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
           "either absent or one that :release_handler itself accepts - being present, " <>
           "being readable and parsing as Erlang terms are each necessary and none of " <>
           "them sufficient, so the test that matters is whether the handler takes it, " <>
           "not any one property of the file. The release creates that file only when it " <>
           "is absent, so anything left in place that the handler will not accept is " <>
           "stepped over on every start and the system comes back on the same " <>
           "synthesised record. Absent, or accepted, is what a restart needs. That file " <>
           "is " <>
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
  def materialise(rel_vsn_dir, peer \\ Peer, deployment \\ Castle.Deployment) do
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

  `rel_dir` is where the restart marker is armed. It is an argument for the
  reason `make_releases/3`'s is: nothing chooses it, `Castle.install/1` derives
  it from `code:root_dir()`, and a test needs somewhere to look.

  A transition that reboots the emulator is refused, with nothing touched, while
  another such install is still pending - see `arm_restart/4`. One at a time is
  the price of the marker being evidence about a particular install rather than
  about a version.

  Two installs cannot be under way on this node at once at all - see
  `serialised/2`. The refusal above is what the second one is then told, once the
  first has finished and its marker is complete.
  """
  @spec install(String.t(), Path.t(), module(), module()) :: result()
  def install(vsn, rel_dir, handler \\ :release_handler, deployment \\ Castle.Deployment) do
    with :ok <- ensure_own_erts("Cannot install #{vsn}", deployment) do
      serialised(rel_dir, fn -> install_upgradable(vsn, rel_dir, handler) end)
    end
  end

  ## One install at a time

  # The resource two callers contend for: this module's install of this
  # deployment. `rel_dir` is in it because that is the deployment - there is one
  # per node, so it changes nothing in a release, and it is what lets the unit
  # suite stay async, each test contending only for its own `tmp_dir`.
  @install_lock {__MODULE__, :install}

  # Everything after the ERTS guard, run with no other caller in it.
  #
  # **The three steps of `arm_restart/4` are correct for one caller and say
  # nothing across processes, and `release_handler` serialising `install_release/1`
  # does not close that.** Its serialisation is *downstream* of the whole
  # protocol: two callers can both read the running release, both classify it,
  # and both pass `unclaimed/2`, because all of that happens before either of
  # them publishes anything. Refusing before clearing then buys nothing. The
  # loser's `clear_provisional/3` runs after the winner's `install_release/1`
  # has written `new_start_erl.data`, so it deletes the winner's live evidence;
  # the winner's reboot comes back on the permanent release, `install` waits for
  # a version that never becomes the running one, and the operator is told
  # "Nothing has been changed" by the process that changed it.
  #
  # **Do not reorder the protocol to avoid that.** Publishing before clearing
  # leaves a window in which the marker pairs with a *stale* `new_start_erl.data`,
  # and the hook then boots a version nothing installed - which is worse than
  # losing a reboot, and is the thing `arm_restart/4`'s order exists to prevent.
  # The order is right; what was missing is that only one caller may be in it.
  #
  # The region has to reach further than the arming, for a second reason.
  # `restart_planned?/3` is a prediction about the release the system is running,
  # and an install that completes between it and `install_release/1` changes what
  # `do_get_rh_script/4` will select: a concurrent hot upgrade moves the
  # from-version, so a marker gets armed for a reboot OTP does not make, or a
  # reboot happens with none armed. So the read, the classification, the arming,
  # `install_release/1` and the disarming are all in here, and the ERTS guard -
  # which reads two directories and can refuse without touching anything - is the
  # only part deliberately left outside.
  #
  # `:global.trans/3` and no process of Castle's own, which is the point of
  # choosing it:
  #
  #   * `global_name_server` is a kernel process and is running whether or not
  #     distribution is, and `set_lock/2` over `[node()]` talks to the local one
  #     only. So this works on a node with `is_alive() == false`, which is the
  #     ordinary case for a release that configures no distribution and the case
  #     it was measured on. Nothing here needs a node name, epmd or a cookie.
  #   * `trans/3` releases the lock in an `after`, and `global` monitors the
  #     holder besides, so a caller that dies - an rpc whose far end went away -
  #     releases it instead of wedging every later install.
  #   * the alternative was a supervised process of Castle's own, and it is a
  #     worse trade. The modules here are deliberately stateless and every
  #     function runs inline in whatever process asked; a lock server would be a
  #     new thing in the *managed* system's supervision tree, with a lifetime and
  #     a restart strategy of its own, to serialise a command that runs a handful
  #     of times in a deployment's life.
  #
  # `[node()]` rather than the default `[node() | nodes()]` is deliberate. Every
  # caller arrives here in the running node - `bin/castle` reaches it by `rpc`,
  # and the launcher's preboot step only calls `make_releases/0` - so this node is
  # the whole set of callers. A cluster-wide lock would make an install wait on
  # nodes that share nothing with this deployment and make a partition its
  # business, and it still would not cover a caller in some other VM. That is the
  # boundary, said plainly: a second VM writing into this releases directory is
  # outside the lock, and what is left there is the filesystem half - `publish/2`
  # refusing rather than replacing - which is no worse than it was.
  #
  # It waits rather than refusing. An install that waited is a slow install; one
  # refused because another was in flight is a failed one. The waiter goes on to
  # find the winner's marker and be told that a restart install is pending, which
  # is the message it would have got anyway - only now it is said about evidence
  # that is complete, rather than said while destroying it.
  #
  # Retries are `infinity`, which `trans/3` is, so `set_lock/3` cannot answer
  # `false` and there is no `aborted` for this to have to mean something by.
  defp serialised(rel_dir, install) do
    :global.trans({{@install_lock, rel_dir}, self()}, install, [node()])
  end

  # The install itself, with the running release asked for once, and the whole of
  # what `serialised/2` holds the region open for.
  #
  # The record check and the restart prediction are both about the release the
  # system is running - `get_latest_release/1` is `current` if there is one and
  # `permanent` otherwise, which is what `running_release/1` computes - and asking
  # `which_releases/0` twice would be asking about two moments. Asking it once is
  # not enough on its own: another caller's install can move the answer between
  # the one question and the install that acts on it, which is the other half of
  # why this whole function is inside the region rather than just the arming.
  defp install_upgradable(vsn, rel_dir, handler) do
    refusal = "Cannot install #{vsn}"
    running = running_release(handler)
    restart? = restart_planned?(vsn, rel_dir, running)

    with :ok <- refuse_synthesised(refusal, running),
         {:ok, attempt} <- arm_restart(restart?, vsn, rel_dir, refusal) do
      installed(vsn, attempt, rel_dir, handler)
    end
  end

  # `install_release/1` replies the same `{ok, Vsn, Descr}` for a hot upgrade and
  # for one that is about to reboot, so what it says cannot tell them apart -
  # which is why the transition is classified from the relup beforehand and the
  # answer carried in here. Reporting a reboot as "now running" is a claim that is
  # false for as long as the reboot takes, and automation reads it.
  defp installed(vsn, attempt, rel_dir, handler) do
    case handler.install_release(to_charlist(vsn)) do
      {:ok, other_vsn, _descr} when is_binary(attempt) ->
        {:ok,
         [
           "Installed #{vsn} (previously #{other_vsn}). The emulator is restarting.",
           "#{vsn} is provisional until it is committed: #{other_vsn} is still the " <>
             "version an ordinary restart boots."
         ]}

      {:ok, other_vsn, _descr} ->
        {:ok, ["Now running #{vsn} (previously #{other_vsn})."]}

      # The emulator, or one of kernel, stdlib and sasl, is being replaced, so
      # the node reboots and the upgrade instructions run after it comes back.
      # Nothing has failed here - but nothing selects the hybrid temporary
      # release the reboot needs either, which is why no marker was armed for it.
      # See `restart_planned?/3`.
      {:continue_after_restart, other_vsn, _descr} ->
        {:ok,
         [
           "Restarting to install #{vsn} (previously #{other_vsn}).",
           "The upgrade continues once the emulator has restarted."
         ]}

      {:error, reason} ->
        disarm(attempt, rel_dir)
        {:error, "Install of #{vsn} failed. #{inspect(reason)}"}

      other ->
        disarm(attempt, rel_dir)
        {:error, "Install of #{vsn} returned an unexpected result. #{inspect(other)}"}
    end
  end

  ## The restart marker

  # Whether the transition about to be installed reboots the emulator into a
  # version the launcher can be told to boot.
  #
  # This is a prediction, and it is made from the same file `release_handler`
  # will read: `do_get_rh_script/4` looks for the from-version in the target's
  # own relup and then for the to-version in the from-release's, which is what
  # `transition_script/3` does. It is not a second implementation of the state
  # machine - nothing here writes a release record - it decides one thing, which
  # is whether to arm the marker, and OTP remains authoritative for everything
  # else.
  #
  # It has to be a prediction because the reply cannot answer it. A one-stage
  # restart is replied to with `{ok, Vsn, Descr}`, exactly as a completed hot
  # upgrade is, and `init:reboot()` has already been called by the time the reply
  # arrives - so a marker armed unconditionally and cleared on `{ok, ...}` would
  # be racing the shutdown, and losing that race silently loses the upgrade.
  #
  # The two instructions are told apart the way `do_install_release/3` tells them
  # apart. `restart_new_emulator` at the head of the script is the two-stage
  # transition, and it is deliberately *not* armed for: the marker OTP writes then
  # names the temporary hybrid release, `__new_emulator__<current>`, whose version
  # directory holds a `start.boot` and a `sys.config` and none of the launcher's
  # own furniture - no `env.sh`, no `elixir`, no `vm.args` - so there is nothing
  # for the launcher to boot. That transition is unsupported rather than
  # half-supported; Forecastle refuses to generate one.
  #
  # Anywhere else in the script, `restart_new_emulator` is an error rather than a
  # transition: `syntax_check_script/1` accepts only `restart_emulator` after the
  # point of no return, and `eval/2` throwing the other atom lands in
  # `eval_script/5`'s error branch. So it never reaches a reboot, and the install
  # fails with the marker unarmed.
  defp restart_planned?(_to_vsn, _rel_dir, nil), do: false

  defp restart_planned?(to_vsn, rel_dir, {from_vsn, _apps}) do
    case transition_script(rel_dir, to_vsn, from_vsn) do
      [@two_stage | _] -> false
      script when is_list(script) -> @one_stage in script
      nil -> false
    end
  end

  # The relup entry `release_handler` will evaluate, or `nil` if there is not one
  # it can find either. A missing or unreadable relup is not this function's to
  # report: `do_get_rh_script/4` throws `no_matching_relup` for it, the install
  # fails, and the failure names the release rather than a marker nobody asked
  # about.
  defp transition_script(rel_dir, to_vsn, from_vsn) do
    upgrade_script(rel_dir, to_vsn, from_vsn) || downgrade_script(rel_dir, to_vsn, from_vsn)
  end

  defp upgrade_script(rel_dir, to_vsn, from_vsn) do
    case relup(rel_dir, to_vsn) do
      {^to_vsn, ups, _downs} -> script_for(ups, from_vsn)
      _other -> nil
    end
  end

  defp downgrade_script(rel_dir, to_vsn, from_vsn) do
    case relup(rel_dir, from_vsn) do
      {^from_vsn, _ups, downs} -> script_for(downs, to_vsn)
      _other -> nil
    end
  end

  # Versions come back from a relup as charlists, so they are compared as
  # strings - the same normalisation `running_release/1` and every message here
  # already apply.
  defp relup(rel_dir, vsn) do
    case :file.consult(to_charlist(Path.join([rel_dir, vsn, "relup"]))) do
      {:ok, [{relup_vsn, ups, downs}]} when is_list(ups) and is_list(downs) ->
        {to_string(relup_vsn), ups, downs}

      _unreadable ->
        nil
    end
  end

  defp script_for(entries, vsn) do
    Enum.find_value(entries, fn
      {from, _descr, script} when is_list(script) -> if to_string(from) == vsn, do: script
      _malformed -> nil
    end)
  end

  # Armed before `install_release/1` is asked for anything, so that the marker is
  # in place before OTP writes its own and reboots, and armed as **this
  # attempt's** rather than as the version's. Three steps, in this order, and the
  # order is the protocol:
  #
  #   1. **Refuse if a marker is already there.** One pending restart install at
  #      a time. Two attempts sharing one name overwrite and disarm each other,
  #      and the survivor's marker says nothing about which of them - if either -
  #      reached `install_release/1`. So a marker at the path is a *finished*
  #      attempt's, waiting for the reboot it asked for, and this refusal is what
  #      keeps step 2 from clearing the `new_start_erl.data` that attempt's
  #      preparation wrote. `publish/2` decides it a second time over, by
  #      refusing rather than replacing.
  #
  #      **What makes it true that the marker belongs to a finished attempt is
  #      `serialised/2` and not this look.** An earlier version of this argued
  #      that a marker appearing between the `lstat` and the publish belonged to
  #      an attempt that had not reached `install_release/1` yet, so there was
  #      nothing of its to destroy. That was the hole: two callers reach this
  #      check before either publishes, so both pass it, and the one that gets
  #      here second clears the first's file out from under a reboot that is
  #      already on its way. Do not reason about this step in isolation again -
  #      it is one caller's half of a rule whose other half is that there is only
  #      ever one.
  #   2. **Clear OTP's file.** `prepare_restart_new_emulator/7` writes
  #      `releases/new_start_erl.data` and nothing removes it, so one left by an
  #      earlier failure would pair with the marker armed next and boot a version
  #      this attempt never installed. Removing it is safe: `write_new_start_erl/3`
  #      goes through `file:write_file/2`, which creates the file when it is
  #      absent. After this, that file existing means *this* attempt's
  #      preparation wrote it.
  #   3. **Publish the marker.** Staged in an owner-only working directory and
  #      hard-linked into place, which is how `Castle.Peer` publishes
  #      `sys.config.pristine` and for the same two reasons: a link publishes a
  #      file that is already complete, so no start can read a marker that is
  #      empty or half written, and it refuses rather than replaces, so the loser
  #      of a race is told instead of silently taking the marker over. An
  #      exclusive create in place would have neither property - it makes
  #      *creation* atomic and leaves the file empty between the open and the
  #      write, and a death in that window leaves an empty marker that blocks
  #      every later attempt.
  #
  # Steps 1 and 2 are in that order and must stay in it. Reversed, an attempt
  # would refuse *after* clearing OTP's file, which is how an install that has
  # already been asked for loses its reboot silently.
  #
  # This runs with no other caller in the install at all - `serialised/2` - and
  # that is what the step 1 note above rests on. Neither replaces the other: the
  # serialisation is why the marker means a finished attempt, and the order of
  # these steps is why a refusal for any *other* reason still changes nothing.
  #
  # A failure at any step refuses the install rather than going ahead: the reboot
  # would come back on whichever version `releases/start_erl.data` names, which
  # is the one being upgraded away from, and the upgrade would be lost with
  # nothing saying so.
  defp arm_restart(false, _vsn, _rel_dir, _refusal), do: {:ok, nil}

  defp arm_restart(true, vsn, rel_dir, refusal) do
    attempt = attempt()

    with :ok <- unclaimed(rel_dir, refusal),
         :ok <- clear_provisional(rel_dir, vsn, refusal),
         :ok <- publish_marker(rel_dir, vsn, attempt, refusal) do
      {:ok, attempt}
    end
  end

  # What names this attempt, and the whole of what `disarm/2`'s ownership rests
  # on. The operating system pid, the wall clock in nanoseconds and a number no
  # other call in this VM will use again: unique within a node, and unique across
  # a node's restarts, which is as far as ownership has to reach - the marker
  # never outlives the deployment's next start, because the hook consumes it.
  #
  # It is not a secret and does not need to be. Anything able to forge it can
  # write in the releases directory, where it could write the marker itself.
  # What it defends against is *confusion*: the marker's name is shared, so
  # removing "the marker" is not the same as removing the one this attempt
  # published.
  #
  # The shell side never reads it. The version is the first line, which is what
  # `head -n 1` gives the hook, and everything after it is Castle's own
  # bookkeeping - so the file can carry this without the hook having to parse
  # anything it did not before.
  defp attempt do
    serial = System.unique_integer([:monotonic, :positive])

    "#{System.pid()}-#{System.system_time(:nanosecond)}-#{serial}"
  end

  # Step 1. `lstat` rather than `File.exists?/1`, because the three answers want
  # three different things said: a regular file is a pending attempt and names
  # its version, anything else is a name in use by something that is not a
  # marker, and a lookup that failed is neither and says so.
  defp unclaimed(rel_dir, refusal) do
    marker = Path.join(rel_dir, @restart_marker)

    case File.lstat(marker) do
      {:error, :enoent} -> :ok
      {:ok, %File.Stat{type: :regular}} -> {:error, pending(marker, refusal)}
      {:ok, %File.Stat{type: type}} -> {:error, occupied(marker, type, refusal)}
      {:error, reason} -> {:error, unarmed(marker, reason, refusal)}
    end
  end

  # Step 2. A file that is not there is the ordinary case and not an error; one
  # that will not go is refused, because going on would leave this attempt's
  # marker pairable with an earlier attempt's file.
  defp clear_provisional(rel_dir, vsn, refusal) do
    provisional = Path.join(rel_dir, @provisional_marker)

    case File.rm(provisional) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, stale(provisional, vsn, reason, refusal)}
    end
  end

  # Step 3. The working directory is removed on every way out, and only ever the
  # one this call made - the rule `Castle.Peer` follows, and for the reason it
  # gives: staging that never got published cannot be told from another install's
  # work in progress, so nothing goes looking for it.
  defp publish_marker(rel_dir, vsn, attempt, refusal) do
    marker = Path.join(rel_dir, @restart_marker)

    case Peer.work_dir(rel_dir) do
      {:ok, work} ->
        outcome = staged(Path.join(work, @restart_marker), marker, "#{vsn}\n#{attempt}\n")
        File.rm_rf(work)
        armed(outcome, marker, refusal)

      {:error, reason} ->
        {:error, unarmed(marker, reason, refusal)}
    end
  end

  defp staged(staging, marker, bytes) do
    with :ok <- Peer.write_private(staging, bytes), do: Peer.publish(staging, marker)
  end

  defp armed(:ok, _marker, _refusal), do: :ok
  defp armed(:taken, marker, refusal), do: {:error, pending(marker, refusal)}
  defp armed({:error, reason}, marker, refusal), do: {:error, unarmed(marker, reason, refusal)}

  # Cleared on every path out of a failed install, because a marker left armed
  # beside a `new_start_erl.data` the same failure may already have written is
  # exactly the pair the hook acts on.
  #
  # **Only if this attempt is the one that armed it.** The marker's name is
  # shared and the marker itself is short-lived: any `start` or `daemon` of the
  # deployment consumes it, whether or not that start went on to boot, so a
  # marker at this path by the time an install fails is not necessarily the one
  # the install published. Removing it by name would take a later attempt's
  # marker away and lose that attempt's reboot. So the attempt is read back out
  # of the file and compared, and a marker that says something else is left where
  # it is.
  #
  # The check and the removal are two calls, so a marker consumed and re-armed
  # between them is still removed. That window is two adjacent statements wide
  # and there is no POSIX operation that closes it - unlinking is by name, and no
  # name carries its identity. What it costs if it is ever hit is a lost reboot,
  # which is the direction the whole protocol fails in. It also takes something
  # outside this node to hit at all now: this runs inside `serialised/2`, so the
  # re-arming cannot be another install here, and what is left is a start of the
  # deployment consuming the marker and some other VM arming one.
  #
  # The result of the removal is deliberately not looked at: a releases directory
  # this cannot remove the marker from is one `publish_marker/4` could not have
  # linked it into, and that refuses the install before `install_release/1` is
  # asked for anything.
  defp disarm(nil, _rel_dir), do: :ok

  defp disarm(attempt, rel_dir) do
    marker = Path.join(rel_dir, @restart_marker)

    if armed_by?(marker, attempt) do
      File.rm(marker)
    end

    :ok
  end

  defp armed_by?(marker, attempt) do
    case File.read(marker) do
      {:ok, contents} -> match?([_vsn, ^attempt | _], String.split(contents, "\n"))
      {:error, _unreadable} -> false
    end
  end

  ## What each way of failing to arm says

  defp pending(marker, refusal) do
    "#{refusal}: #{marker} is already there, so a restart install is pending - " <>
      "#{armed_version(marker)}. Two of them cannot share that file: the second " <>
      "would overwrite the first, and whichever marker survived would say nothing " <>
      "about which install reached :release_handler. Nothing has been changed. The " <>
      "marker is consumed by the next start of this deployment, so a restart clears " <>
      "it; if no install is in flight and the system is not going to be restarted, " <>
      "remove that file."
  end

  defp armed_version(marker) do
    case File.read(marker) do
      {:ok, contents} -> named(contents |> String.split("\n") |> hd())
      {:error, reason} -> "it cannot be read (#{:file.format_error(reason)})"
    end
  end

  # A marker Castle published always has a version on its first line, because it
  # is linked into place complete. One without is somebody else's file under
  # Castle's name, and saying so is more use than a message with a gap in it.
  defp named(""), do: "it names no version"
  defp named(vsn), do: "it names #{vsn}"

  defp occupied(marker, type, refusal) do
    "#{refusal}: #{marker} is where Castle records that an upgrade asked for a " <>
      "reboot, and there is already #{describe_type(type)} at that path. Castle " <>
      "will not write through it or replace it, and there is nowhere else it can " <>
      "arm the install - that path is what the launcher reads on the next start. " <>
      "Nothing has been changed. Move whatever is there out of the way."
  end

  defp describe_type(:directory), do: "a directory"
  defp describe_type(:symlink), do: "a symbolic link"
  defp describe_type(other), do: "a #{other}"

  defp stale(provisional, vsn, reason, refusal) do
    "#{refusal}: the upgrade to #{vsn} restarts the emulator, and #{provisional} - " <>
      "which :release_handler writes before the reboot and never removes - could not " <>
      "be cleared first (#{:file.format_error(reason)}). It has to be, because one " <>
      "left by an earlier attempt would pair with the marker this install is about " <>
      "to arm and tell the launcher to boot a version that was never installed. " <>
      "Nothing has been changed."
  end

  defp unarmed(marker, reason, refusal) do
    "#{refusal}: the upgrade restarts the emulator, and #{marker} - which is what " <>
      "tells the launcher which version to boot when the system comes back - could " <>
      "not be armed: #{detail(reason)}. Without it the restart would come back on " <>
      "the version releases/start_erl.data names, losing the upgrade."
  end

  # A `:file` reason from the `lstat`, or a message from one of the primitives in
  # `Castle.Peer`, which have already said which path and why.
  defp detail(reason) when is_atom(reason), do: to_string(:file.format_error(reason))
  defp detail(message) when is_binary(message), do: String.trim_trailing(message, ".")

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

  A version the launcher booted provisionally, after a restart transition,
  arrives here as `:current` too and needs nothing of its own: `transform_release/3`
  writes the `tmp_current` record back as `unpacked` on disk, and `set_current/2`
  makes it `current` in the record the handler holds, because `init:script_id()`
  names it. So the same two conditions answer the same question across a reboot,
  which is what lets `bin/castle install` poll through one.

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

  **A version reached by a restart transition needs nothing extra here, and that
  is measured rather than assumed.** `prepare_restart_new_emulator/7` persists
  the target as `tmp_current` before the reboot, and on the boot that follows
  `transform_release/3` writes it back as `unpacked` *on disk* while
  `set_current/2` hands the handler a record in which it is `current` in memory -
  because `init:script_id()` names it. `do_make_permanent/2` reads the in-memory
  record and accepts any status but `unpacked`, `old` and `permanent`, so
  `current` is exactly what it wants; `set_permanent_files/5` then writes
  `releases/start_erl.data`, and `write_releases/3` corrects the on-disk record.
  So the file that decides what an ordinary restart boots is written here and
  nowhere else, which is the whole of the rollback property: until this runs, a
  restart returns to the version that was permanent before.
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
