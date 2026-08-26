defmodule Castle do
  @moduledoc """
  Runtime hot-code upgrade support for Elixir releases.

  [Forecastle](https://hexdocs.pm/forecastle) prepares releases at build time.
  Castle runs on the deployed node. It unpacks, installs, commits and removes
  versions, and resolves each target version's config providers before OTP
  installs it.

  `customize/1` is the build-time integration API. Call it from a release
  definition in `mix.exs`.

  The other public functions back the `bin/castle` commands. Successful commands
  print their result and return `:ok`. A refusal from Castle or an error returned
  by `:release_handler` raises `Castle.Error`, which gives `bin/castle` a non-zero
  exit status. Unhandled exceptions, throws and exits propagate unchanged.
  Automation that calls these functions over `rpc` should treat any raise as a
  failed command.

  Commands that modify a deployment require the VM's emulator root to match the
  release root. This rejects releases built with `include_erts: false` and any
  other setup where `:release_handler` would operate on the shared Erlang
  installation. `upgradable/0` and `releases/0` remain available for diagnosis.
  """

  alias Castle.Commands
  alias Castle.Deployment
  alias Castle.Peer

  # The steps a release is given when it asks for none. Mix's own default is
  # [:assemble] and not carrying that over is the one decision customize/1
  # makes on a project's behalf - see its @doc for why, and for what it does
  # instead with a list the project wrote itself.
  @default_steps [:assemble, :tar]

  @doc """
  Makes a Mix release Castle-capable.

  Adds Forecastle's build steps around `:assemble` and returns the updated
  release options.

      # mix.exs
      defp releases do
        [
          my_app: fn ->
            [
              include_executables_for: [:unix],
              steps: [:assemble, :tar]
            ]
            |> Castle.customize()
          end
        ]
      end

  Define the release with `fn -> ... end`. Mix can load `mix.exs` before Castle
  has been compiled; it evaluates the release function later.

  ## Steps

  Existing steps keep their order. A missing `:steps` option becomes
  `#{inspect(@default_steps)}` so the build produces the tarball used by
  `bin/castle unpack`. An explicit list without `:tar` is kept and produces a
  warning. Mix validates malformed step lists and lists without exactly one
  `:assemble`.

  Forecastle also places a relup-generating step immediately before `:tar` —
  so after every step of the project's own that sits between `:assemble` and
  `:tar`, which is where `mix release` documents a step that customises an
  assembled release. It does nothing unless the release names a baseline; see
  *Upgrades* below.

  The rule that placement follows is: **after every step that changes the
  release, and immediately before the one that packs what ships.**
  `[:assemble, :tar]` satisfies it. Two lists do not, and both build green:

    * With no `:tar` the step is **appended last**, after everything in the
      list, so a project that packs its own archive in a function step must
      place `&Forecastle.generate_relup/1` itself. Placed too early the relup
      describes the tree as it was while the archive holds the tree as it
      became; placed too late the archive has no relup at all. A step that
      shapes *and* packs has to be split.
    * Mix permits a function step **after** `:tar`, and generation happens
      before `:tar`, so such a step runs after it. Adding `:tar` puts the relup
      in the archive `:tar` builds and says nothing about one packed afterwards.

  The missing-`:tar` warning says the first of those. It cannot name the step,
  because nothing here can tell which of a project's steps packs or which
  mutates, and it does not fire at all for the second — a list containing `:tar`
  looks correct from here.

  ## Upgrades

  `upgrade_from:` names the releases this one can be upgraded from, and the
  relup step generates the plan during assembly:

      my_app: fn ->
        [
          include_executables_for: [:unix],
          upgrade_from: ["tar:artifacts/my_app-1.0.0.tar.gz"]
        ]
        |> Castle.customize()
      end

  A baseline is a `tar:` tarball, a `rel:` assembled release or a `ref:` git ref
  — a bare path meaning `rel:` — and both directions are generated for each of
  them. Prefer `tar:` where the shipped artefact still exists: a rebuilt
  baseline is built with today's toolchain and dependencies, and a relup
  generated against one describes a transition from a release that never
  existed.

  **`customize/1` does not check this option and never reads its value.** It is
  an ordinary release option; Mix keeps the options it does not recognise, so it
  reaches the step on its own. Forecastle owns the grammar and every refusal:
  an empty list, a value that is not a list of strings, a spec whose prefix
  names no source, and the option given more than once are each refused there,
  as is a hand-written project-root `relup` alongside it. Omitting the option is
  the only quiet case — assembly is then exactly what it was before this
  existed. The one thing `customize/1` asks is whether the option is *present*,
  and only so that the missing-`:tar` warning above can say what is true.

  The project must also provide:

    * An appup for each application the project owns that has to be upgraded in
      place, configured with the `:appup` project key and
      `compilers: Mix.compilers() ++ [:appup]`.

      Exactly which transitions need one depends on the strategy the relup is
      generated with, on which applications changed and on who owns them, and
      each direction is classified separately. `mix castle.relup` documents
      those rules and is the authority on them; this list deliberately does not
      restate them, because a summary short enough to belong here is wrong in
      some case and a correct one is that task's `@moduledoc` copied into a
      repository that cannot see it change.
    * A relup — either generated during assembly from `upgrade_from:` above, or
      generated by `mix castle.relup` and left in the project root. The task is
      what covers two artefacts that already exist, and the `--hot`/`--restart`
      strategies that `upgrade_from:` cannot ask for. Both at once is refused.
    * `include_executables_for: [:unix]`.

  A custom `rel/env.sh.eex` is optional. Forecastle appends Castle's setup to
  the generated file or the project's template.
  """
  @spec customize(keyword()) :: keyword()
  def customize(opts) when is_list(opts) do
    # `has_key?/2` and never the value. This is the *only* thing `customize/1`
    # asks about `:upgrade_from`, and it asks it for one reason: with no `:tar`
    # the relup step is appended last, which changes what the missing-`:tar`
    # warning can honestly say. Forecastle owns the option, its grammar and
    # every refusal about it - see the `@doc`, and do not grow this into a
    # second reading of what it contains.
    upgrading? = Keyword.has_key?(opts, :upgrade_from)

    Keyword.update(opts, :steps, Forecastle.steps(@default_steps), &spliced(&1, upgrading?))
  end

  # `Forecastle.steps/1` does the splice and there is deliberately no second
  # implementation of it here: it finds `:assemble`, puts the pre-assembly step
  # before it and the post-assembly step after it, puts the relup step before
  # `:tar`, and leaves everything around them where it was. That it is
  # Forecastle's function is the one thing customize/1 exists to keep out of a
  # consumer's `mix.exs`.
  defp spliced(steps, upgrading?) when is_list(steps) do
    warn_missing_tar(steps, upgrading?)
    Forecastle.steps(steps)
  end

  # Not a list, so there is nothing to splice into. `mix release` validates
  # `:steps` and its refusal names the option; a FunctionClauseError raised out
  # of Forecastle would name a module the project never mentioned, which is the
  # one thing this function is for.
  defp spliced(steps, _upgrading?), do: steps

  # Said at the build, where the remedy is one atom, because the alternative is
  # an operator meeting it on a deployment as a `bin/castle unpack` with nothing
  # to unpack - and that failure names a missing file rather than the release
  # option that did not ask for it.
  #
  # It states the omission and preserves the valid qualifications. Nothing here
  # knows the release was meant to be distributed: the system an upgrade is
  # installed *onto* needs no tarball of its own, and `:tar` is Mix's own way of
  # packing one - its
  # `make_tar/1` is private to `Mix.Tasks.Release` - rather than the only way,
  # so a function step in the list may be packing one itself.
  #
  # Nothing is said about a list with no `:assemble`. `Mix.Release`'s own
  # `validate_steps!/1` requires exactly one and names the option when it
  # refuses, and `Forecastle.steps/1` hands such a list back untouched for that
  # refusal to happen. A second implementation of Mix's rule could only drift
  # from it.
  # **The warning states the condition it observed and a conditional
  # consequence, and asserts no verdict.** What this can see is one atom's
  # absence from the list as given. What it cannot see is whether an archive
  # appears anyway: a function step later in the list can pack one itself, or
  # add `:tar` to the steps still to run, and `%Mix.Release{}` carries those
  # remaining steps precisely so a step can. An earlier version of this said the
  # release "is never packed" and that "nothing can install this version" - then
  # acknowledged the counterexample in a trailing sentence without retracting
  # either claim, which is the worst of both: a definite diagnosis on the error
  # channel sending an operator to investigate a packaging failure that may not
  # exist. Say what was seen, say what follows unless something else packs it,
  # and keep the valid tarball-free base-deployment case explicit.
  defp warn_missing_tar(steps, upgrading?) do
    if :assemble in steps and :tar not in steps do
      Mix.shell().error(
        "warning: release :steps has no :tar step. Add :tar after :assemble to create " <>
          "the <name>-<vsn>.tar.gz used by bin/castle unpack. " <> qualifications(upgrading?)
      )
    end
  end

  # **Both qualifications below are false once the release sets
  # `:upgrade_from`, which is why this branches at all.** `Forecastle.steps/1`
  # puts the relup step immediately before `:tar` and, with no `:tar` to
  # precede, appends it *last of all* - after every step the project wrote. So a
  # step of the project's own that packs the archive packs it before the relup
  # exists, and the release ships an archive with no upgrade plan in it while
  # the plan sits in the version directory on disk. Measured, not reasoned
  # about: a fixture project with `steps: [:assemble, &pack/1]` and an
  # `upgrade_from:` builds green, prints this warning, and produces exactly that
  # archive.
  #
  # "No change is needed if another step creates the archive" is then the worst
  # sentence available - it tells the author, on the error channel, that the one
  # thing they have to do is unnecessary. And "a deployment used only as an
  # upgrade base needs no tarball of its own" does not describe a release that
  # names baselines to be upgraded *from*: that release is a target.
  #
  # **This does not become a verdict, and the line is exactly where it was.**
  # What is said is the ordering, which is a fact about the list as given, and a
  # consequence conditional on a step that packs - which this still cannot see
  # and still does not claim. It does not say the archive will lack the relup,
  # because a project may pack nothing here at all, or add `:tar` to the steps
  # still to run.
  #
  # It is the *presence* of the option that is read and never its contents, so
  # this is right for an `upgrade_from:` Forecastle is about to refuse too: the
  # `:tar` observation holds whatever the value is, and the refusal follows a
  # moment later at `pre_assemble/1`.
  #
  # The remedy is stated as placement rather than replacement because that is
  # what works: `Forecastle.steps/1` appends its own copy regardless, so a
  # project that places one of its own has the relup generated twice - once
  # where it asked, into the archive, and once afterwards over the same path.
  # Cheap (the baselines were resolved in `pre_assemble/1` and are read back
  # from a stash), and the README says the summary line appears twice so that
  # nobody reads it as a fault.
  #
  # **The placement is stated on both sides, and the second side is not
  # decoration.** "Before the step that packs" alone is wrong for a step that
  # shapes the tree *and* packs it, which is an ordinary thing for one function
  # step to do: generation then reads the tree as it was, the archive holds the
  # tree as it became, and the release ships an upgrade plan for code it is not
  # carrying. Measured on the same fixture - a packing step that rewrites the
  # app's appup first produces an archived relup saying `brutal_purge` while the
  # regenerated one on disk says `soft_purge`, with the build green - which is
  # precisely the failure the late placement of this step exists to prevent,
  # reintroduced by the workaround for its own edge case. So the message says
  # after every step that changes the release, before the one that packs, and to
  # split a step that does both.
  #
  # **`:tar` is the simple answer and is not an unconditional one, which the
  # message said for one round and should not say again.** `Mix.Release`'s
  # `validate_steps!/1` requires exactly one `:assemble`, at most one `:tar`,
  # and `:tar` after `:assemble` - and permits a function step *after* `:tar`.
  # So `[:assemble, :tar, &pack/1]` is a list Mix accepts, and this warning does
  # not even fire for it: the relup goes into the archive `:tar` builds, and a
  # step that runs afterwards can change the release and pack an artefact of its
  # own from the changed tree. Measured on the fixture - a step after `:tar`
  # that rewrites the app's appup packs an archive carrying the rewritten appup
  # beside a relup generated from the original. So the sentence names what
  # adding `:tar` achieves and what is outside it, rather than promising that
  # nothing else is needed.
  #
  # None of that is enforceable from here and none of it should be attempted:
  # `customize/1` cannot see which step packs, let alone which mutates. What it
  # can do is state the one rule that covers every placement - after everything
  # that changes the release, immediately before what packs the shipped
  # artefact - and it does.
  defp qualifications(false = _upgrading?) do
    "No change is needed if another step creates the archive. A deployment used only as " <>
      "an upgrade base needs no tarball of its own."
  end

  defp qualifications(true = _upgrading?) do
    "This release also sets upgrade_from:, and with no :tar the relup step is appended " <>
      "last, after every step in the list - so a step of your own that packs the archive " <>
      "packs it before the relup is generated. Add :tar and the relup goes into the " <>
      "archive :tar builds, which is the whole answer unless a later step changes the " <>
      "release or packs an artefact of its own; Mix allows a function step after :tar. " <>
      "To place &Forecastle.generate_relup/1 yourself instead, put it after every step " <>
      "that changes the release and immediately before the one that packs what you ship, " <>
      "splitting a step that does both: a relup generated before a change describes the " <>
      "tree as it was."
  end

  # Every function in this module but customize/1 is a command entry point:
  # `bin/castle` sends each one to the running node over `bin/<release> rpc`,
  # and the launcher's env.sh fragment evaluates make_releases/0 in the preboot
  # VM, on the first start of a deployment. There is no separate CLI layer to
  # carry the process status, so these functions are the command boundary, and
  # it is here that a refusal raises. Not every failure: an exception, throw or
  # exit out of `install_release/1` is re-raised unchanged by
  # `Commands.installed/5` once the marker is settled, so it passes through this
  # boundary rather than being converted at it.
  #
  # customize/1 is the exception and is not one of them: it runs at build time,
  # in a consumer's `mix.exs`, and returns a value rather than reporting an
  # outcome. It is here rather than in a module of its own because it is the
  # public integration point - a project should have to name `Castle` and
  # nothing else.
  #
  # Raising, rather than halting or returning: the rpc expression runs on the
  # running release node, so halting there would halt the system under
  # management rather than the caller. `Kernel.CLI.rpc_eval/1` catches on the
  # node and the local VM re-raises, printing the reason and exiting non-zero
  # while the running node is left untouched. A returned error value would be
  # discarded - `Kernel.CLI` only inspects the result of a command for `:ok`.
  #
  # `Castle.Commands` holds the operations themselves, returning their outcome
  # rather than acting on the process, so that they can be tested.
  #
  # **The user-facing half of all of that is now in the `@moduledoc` and in the
  # `@doc`s below** (castle#11), and the two halves have to be kept in step: a
  # reader who takes these for ordinary functions is surprised twice over, by a
  # return value that carries nothing and by an exception where a `{:error, _}`
  # would be. So every one of them says which `bin/castle` command reaches it,
  # and the module says what a command boundary does.
  #
  # What is published and what is hidden follows from the same distinction.
  # Every command an operator invokes is documented, framed by the `bin/castle`
  # command that reaches it, because hiding a command an operator has to run
  # would document nothing useful anywhere. `make_releases/0` is the one
  # exception - see below - and `install/2..5` is documented as what it is, a
  # seam a test drives, since one `@doc` covers every arity of a clause with
  # defaults and silence about the extra four would read as an API.

  # `@doc false`, and the only one here: this is not a command an operator has
  # any reason to invoke. Its single caller is the launcher's `env.sh` fragment,
  # which evaluates it in the preboot VM on a `start` or `daemon` whose
  # deployment has no `releases/RELEASES` yet - and by hand it is close to
  # useless: on a deployment that has the file it does nothing at all, and on
  # one that does not, the next start does it anyway. Publishing it would put a
  # function in the documented surface whose whole contract is with a shell
  # fragment in another project.
  #
  # It keeps its `@spec` regardless. The specs are the contract whether or not
  # the function is published, and nothing in this project checks them.
  @doc false
  @spec make_releases() :: :ok
  def make_releases do
    report!(Commands.make_releases(rel_dir()))
  end

  # A question, and not a gate anything has to ask: `unpack/1` and `install/1`
  # make the same check themselves, inside the operation, where nothing can
  # happen between the answer and the act. This is how an operator asks without
  # acting - the state it reports is invisible otherwise, because the file can be
  # there while the record the node works from was synthesised. Do not put it
  # back in front of them: a check in a call of its own is a check about a moment
  # that has passed, and `bin/castle` sends each of these as a separate rpc.
  @doc """
  Checks whether the running node has a valid release record for upgrades.

  Called by `bin/castle upgradable`. Success prints nothing. A node that booted
  from a record synthesised by `:release_handler` raises `Castle.Error` with
  recovery instructions.

  `unpack/1` and `install/1` repeat this check inside their own operations. A
  prior call to `upgradable/0` is diagnostic only; the node may restart before a
  later command acts.

  The release-record file is normally `<root>/releases/RELEASES`. `RELDIR` or
  the SASL `releases_dir` option can move the file read by `:release_handler`.
  """
  @spec upgradable() :: :ok
  def upgradable do
    report!(Commands.upgradable())
  end

  @doc """
  Unpacks a release tarball into the deployment, and reports the version.

  Called by `bin/castle unpack <vsn>`, which passes
  `<release-name>-<vsn>` to `:release_handler`. Place the corresponding
  `<release-name>-<vsn>.tar.gz` in the deployment's `releases` directory first.

  Unpacking stages a version: it extracts the applications, writes a release
  record with status `unpacked`, and leaves the running version unchanged.

  Raises `Castle.Error` if the node cannot be upgraded from. See
  `upgradable/0`. `RELDIR` and the SASL `releases_dir` option are not supported;
  see [issue #23](https://github.com/ausimian/castle/issues/23).
  """
  @spec unpack(String.t()) :: :ok
  def unpack(name) when is_binary(name) do
    report!(Commands.unpack(name))
  end

  # Materialising is *inside* `Commands.install/5`, and this composing it here is
  # the bug that put it there. Materialisation ends in a rename onto the target's
  # `sys.config` - a replace by design, and it has to be, because that is the file
  # `:release_handler` reads - so it is not the harmless idempotent work the note
  # below used to call it. Two callers here both materialised before either
  # entered the serialised region, and the loser's providers - evaluated in a
  # second VM, with whatever environment that call had - overwrote the
  # configuration the winner's provisional release was about to boot, after which
  # the loser was refused for the winner's marker. The refused install decided the
  # configuration of the one that succeeded.
  #
  # So there is nothing to compose: `Castle.install/1` is one call, and "an
  # install is serialised" is now true of *this* function rather than of a part of
  # it. See `Castle.Commands.install/5` and `serialised/2`.
  #
  # **And that claim is tested here rather than one layer down, which is what the
  # four defaulted arguments are for.** `Castle.Commands.install/5` already took
  # the handler, the peer and the deployment so that its own suite could drive two
  # concurrent callers through it; but a test that drives *it* cannot see anything
  # composed in *this* function, so the composition that was the whole defect would
  # have been reintroducible with every test still green. `rel_dir` joins them for
  # the same reason it is an argument there - a suite needs a releases directory of
  # its own to contend over, or the cases cannot run async - and the three module
  # arguments follow it because a caller held at `which_releases/0` is the only
  # seam the interleaving has.
  #
  # They are defaults rather than a separate entry point so that `bin/castle`
  # keeps calling `Castle.install/1` over `rpc` and nothing about the deployment
  # is chosen by a caller: see `rel_dir/0`.
  @doc """
  Installs `vsn` and makes it the version the system is running.

  Called by `bin/castle install <vsn>` after `unpack/1` has staged the version.

  Castle verifies the deployment, checks the running release record, resolves
  the target's config providers in a temporary VM, and arms any marker needed
  for an emulator restart. These checks finish before
  `:release_handler.install_release/1` starts the upgrade.

  A hot upgrade reports the new and previous running versions. An upgrade that
  restarts the emulator reports that the version was installed and remains
  provisional. `bin/castle install` then polls `running/1` until the target has
  finished booting. Automation that calls `install/1` over `rpc` must perform
  the same check.

  The installed version remains provisional until `commit/1` writes it as the
  permanent version. An ordinary restart before commit boots the previous
  permanent version. For a `restart_emulator` transition, the restart requested
  by the install boots the target; later restarts still boot the previous
  version until commit.

  Castle serialises installs on the local Erlang node. A pending restart install
  owns its launcher marker and blocks another restart install from replacing it.

  ## The four extra arguments

  `install/1` is the supported form. The defaulted arguments on `install/2`
  through `install/5` are test seams, not deployment options.
  """
  # Five, because a definition with defaults defines five functions and a
  # `@spec` covers one arity. Two of them - `install/1` and `install/5` - were
  # all this carried at first, which left `install/2..4` unspecced and the
  # claim that the whole of this module is specced false. `mix docs` does not
  # notice, `credo --strict` does not notice, and there is no Dialyzer here:
  # `Code.Typespec.fetch_specs(Castle)` is what shows all five, and reading the
  # source is what missed three.
  @spec install(String.t()) :: :ok
  @spec install(String.t(), Path.t()) :: :ok
  @spec install(String.t(), Path.t(), module()) :: :ok
  @spec install(String.t(), Path.t(), module(), module()) :: :ok
  @spec install(String.t(), Path.t(), module(), module(), module()) :: :ok
  def install(
        vsn,
        rel_dir \\ rel_dir(),
        handler \\ :release_handler,
        peer \\ Peer,
        deployment \\ Deployment
      )
      when is_binary(vsn) do
    report!(Commands.install(vsn, rel_dir, handler, peer, deployment))
  end

  @doc """
  Confirms that `vsn` is the release the system is running, and has finished
  booting.

  Success prints nothing. A different running version or an incomplete boot
  raises `Castle.Error` with the current state.

  `bin/castle install` polls this function. It confirms either the `current`
  release or the `permanent` release when no release is current, and requires
  the boot script to have reached its `started` progress marker.
  """
  @spec running(String.t()) :: :ok
  def running(vsn) when is_binary(vsn) do
    report!(Commands.running(vsn))
  end

  @doc """
  Makes `vsn` permanent, so that it is the version a restart boots into.

  Called by `bin/castle commit [<vsn>]`. Without a version, `bin/castle` selects
  the `current` release. It exits non-zero when no release is awaiting commit.

  Castle resolves the target's config providers again before promotion. This
  records the configuration a boot at commit time would produce. An explicit
  commit of an already-permanent version still performs this configuration
  step.

  Raises `Castle.Error` if the configuration could not be expanded, or if the
  version cannot be promoted. This includes staged, rolled-back, superseded and
  unknown versions.
  """
  @spec commit(String.t()) :: :ok
  def commit(vsn) when is_binary(vsn) do
    report!(Commands.commit(vsn, rel_dir()))
  end

  @doc """
  Removes `vsn` from the system, and deletes what nothing else is using.

  Called by `bin/castle remove <vsn>`. Removes the version directory, unreferenced
  application directories, and the `erts-<erts_vsn>` directory when no remaining
  release uses that emulator.

  Raises `Castle.Error` for the permanent version or an unknown version.
  """
  @spec remove(String.t()) :: :ok
  def remove(vsn) when is_binary(vsn) do
    report!(Commands.remove(vsn))
  end

  @doc """
  Lists the releases the system knows of, and the status of each.

  Called by `bin/castle releases`. Prints one line per release with its
  `:release_handler` status: `permanent`, `current`, `unpacked` or `old`.

  `unpacked` includes staged releases and releases returned to that state after
  a failed or rolled-back install. A node with no known releases prints nothing.
  This read-only command remains available when mutating commands are refused.
  """
  @spec releases() :: :ok
  def releases do
    report!(Commands.releases())
  end

  # **Nothing here composes materialisation any more, and neither entry point may
  # start again.** It is a *replace*: the last thing it does is rename the
  # resolved configuration onto `sys.config`. In front of an operation it is two
  # steps another caller can get between, which is why `Commands.install/5` took
  # it back inside its own lock — and `commit/1` has now followed, into
  # `Commands.commit/5`.
  #
  # `commit` was left out on the argument that it is different in kind: it makes
  # permanent a version this node already installed and is running, so there is no
  # marker, no reboot and no window between a configuration and a boot of it. The
  # part that was wrong is what the argument then concluded — that putting commit
  # behind the install lock would be "a deadlock dressed as caution, since an
  # install waiting on a reboot is exactly when a commit is wanted". **An install
  # never holds the lock while waiting on a reboot.** `install_release/1` replies
  # before `init:reboot()` and the reboot runs in `release_handler`'s process, so
  # `Commands.install/5` returns and its `trans` releases before the node goes
  # down; `bin/castle install` then polls `Castle.running/1` over separate rpcs
  # that take no lock, and after a restart transition the VM that held it is gone
  # entirely. The only thing a commit can now wait for is a hot install still
  # inside `install_release/1` — and waiting there is right, because committing
  # part-way through an upgrade is what should not happen.
  #
  # What the composition actually left open was the reachable case: a duplicate
  # install of the version being committed, materialising between the two calls.
  # The commit succeeds, that install then fails as already installed, and its
  # configuration is what the newly permanent release boots on the next restart —
  # a failed caller deciding what a successful one boots, which is the failure
  # this protocol exists to prevent, reachable through the one operation left
  # outside it.

  # The release directory. Derived, never chosen by the caller: which file the
  # configuration lands in, and which file the release records go in, are
  # properties of the installation rather than arguments, and a caller's working
  # directory cannot make them name different ones.
  #
  # `Castle.Deployment.root_dir/0` says what that root does and does not decide,
  # and is the one place that says it. The part that bears on these two: it is
  # the right derivation for a release Mix built, and only because Mix sets
  # neither of the two things that would move the release records elsewhere -
  # see castle#23.
  #
  # It is read through `Castle.Deployment` so that there is one place naming it,
  # the same place `Castle.Commands.ensure_own_erts/2` compares it against
  # `RELEASE_ROOT` - which is the one deployment where this derivation names the
  # wrong tree, and where every operation that would act on it refuses.
  defp rel_dir, do: Path.join(Deployment.root_dir(), "releases")

  defp report!({:ok, lines}), do: Enum.each(lines, &IO.puts/1)
  defp report!({:error, message}), do: raise(Castle.Error, message)
end
