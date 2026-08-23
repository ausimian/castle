defmodule Castle do
  @moduledoc """
  Runtime hot-code upgrade support for Elixir releases.

  Castle is the runtime half of a pair: [Forecastle](https://hexdocs.pm/forecastle)
  is the build-time half, and a project that depends on Castle gets it as a
  build-time dependency of its own. Forecastle assembles a release that can be
  upgraded, and writes the launcher furniture an upgrade is driven through - the
  `preboot` script, the `env.sh` fragment and the `bin/castle` wrapper. Castle
  is what that furniture calls on the running node: it unpacks, installs,
  commits and removes versions, and expands the configuration of the version
  being installed by running *that version's own* config providers before
  `:release_handler` is handed anything.

  Two kinds of function live here, and only one of them is an ordinary function.

  ## The integration point

  `customize/1` is the whole of what a project names. It runs at build time, in
  a consumer's `mix.exs`; it takes the options `mix release` accepts and returns
  options `mix release` accepts. It is the only function here that other Elixir
  code is meant to call.

  ## The commands

  Everything else is a command entry point rather than an API. `bin/castle`
  sends each one to the running node as an expression over
  `bin/<release> rpc`, and the launcher's `env.sh` fragment makes one call of
  its own in a preboot VM, on the first start of a deployment, to create the
  release records `:release_handler` needs. There is no CLI layer in between to
  carry the outcome, so this module *is* the command boundary - and both halves
  of that are visible in what these functions do:

    * A command that succeeds prints what it has to report, and returns `:ok`.
      The report is the output rather than the return value: there is nothing in
      `:ok` to inspect, and the commands that are questions succeed with
      nothing to say at all.

    * A command that fails raises, and what it raises is not always
      `Castle.Error`. A refusal the command made itself, and an error
      `:release_handler` returned, become `Castle.Error`. An exception, a throw
      or an exit that the operation did not handle is let out unchanged: the
      stacktrace is worth more than anything Castle could wrap it in.
      `install/1` is where the difference is deliberate rather than
      incidental - it settles the restart marker it armed and then re-raises
      whatever `:release_handler.install_release/1` did, folding it into a
      `Castle.Error` only in the one case where Castle knows something the
      exception does not say, which is that the marker could not be settled.

      Either way it is the raise that leaves a non-zero exit status behind for
      the shell that asked for the operation: the expression is evaluated over
      `elixir --rpc-eval`, which catches on the running node and re-raises in
      the short-lived VM that made the call, so that VM is the one which exits.
      Raising rather than halting is deliberate - halting would take down the
      system under management instead of the caller.

  So the interface is `bin/castle` - `releases`, `upgradable`, `unpack`,
  `install`, `commit` and `remove` - and these functions are what it reaches.
  Calling them from Elixir is for automation driving an upgrade over `rpc`
  itself, and it means taking both halves above as they are: read the outcome on
  standard output, and treat *any* raise as the failure. A rescue narrowed to
  `Castle.Error` catches the refusals and the reported errors and misses the
  command that blew up.

  One condition runs through all of them: the root the VM is running from has to
  be the deployment's own. Assembling with `include_erts: false` is the usual way
  for that not to hold - a release that brings no ERTS runs on whichever Erlang
  installation is on the path, and it is that installation, rather than the
  deployment, which `:release_handler` would then unpack into, configure and
  delete out of - though it is not the only way, so what Castle reports is the
  divergence it can see rather than a cause it cannot. Every command that would
  change something refuses such a deployment; `upgradable/0` and `releases/0`
  still answer, so that the state can be asked about.
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

  Takes the options `mix release` accepts and returns options `mix release`
  accepts, with the build-time steps Castle needs installed around `:assemble`.
  It is the whole of the integration: a project that calls it names nothing
  else, and what the build does can change between Castle versions without a
  project's release definition changing with it.

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

  ## Define the release lazily

  The `fn -> ... end` is not a matter of style, and a release written as a plain
  list will not build. Mix evaluates the project's configuration - all of
  `mix.exs` - every time it loads the project, and that includes the
  `mix deps.get` and `mix deps.compile` runs that have yet to build `castle`
  itself, so a call written outside a function is a call to a module that is not
  there yet. Mix calls the function only once it has been asked for a release,
  by which point every dependency has been compiled.

  ## Steps

  Whatever `:steps` already holds is kept, in the order it was given: the Castle
  steps are spliced around `:assemble`, and nothing else moves. A list with no
  `:assemble` in it - or a `:steps` that is not a list at all - comes back
  untouched, for `mix release` to refuse as it would any other: it validates the
  option itself, and requires exactly one `:assemble`.

  A release that asks for no `:steps` at all gets
  `#{inspect(@default_steps)}`, which is Mix's default plus `:tar`. The
  difference is deliberate. `:tar` is
  what packs `<name>-<vsn>.tar.gz`, and that tarball is what gets copied into a
  deployment's `releases` directory for `bin/castle unpack <vsn>` to read, so a
  version built without one can be assembled and run but can never be installed
  onto a running system - which is the only reason to be using Castle.

  A `:steps` list that *is* given and has no `:tar` in it is honoured as it
  stands, with a warning. Honoured, because it is the project's own list and
  rewriting it would be Castle deciding what a build produces; warned about,
  because the cost is otherwise invisible until an operator is on a deployment
  with nothing to unpack. Add `:tar` after `:assemble` to silence it.

  The warning says what is missing rather than concluding that the release is
  broken, and for two reasons: the deployment an upgrade is installed *onto*
  needs no tarball of its own, so a version that is only ever upgraded from is
  fine without one; and `:tar` is Mix's own way of packing one rather than the
  only way, so a function step in the list may be packing a tarball itself.

  ## What it does not cover

  Castle needs four more things from a project, and none of them is a release
  option this can set:

    * An appup for every application whose code an upgrade replaces: the
      `:appup` project key naming the file, and the compiler that installs it -
      `compilers: Mix.compilers() ++ [:appup]`. See `Mix.Tasks.Compile.Appup`.

    * A relup, generated by `mix forecastle.relup` between two assembled
      releases and left in the project root, which is where post-assembly looks
      for one to pack. See `Mix.Tasks.Forecastle.Relup`.

    * `include_executables_for: [:unix]`. `bin/castle` is a POSIX shell script,
      so nothing on a Windows deployment can drive an upgrade; assembly warns
      about the `.bat` launcher rather than refusing to write it.

    * `rel/env.sh.eex`, if the project wants one of its own. It is optional:
      Mix writes an `env.sh` either way, and the launcher fragment Castle needs
      is appended to whichever one Mix wrote.
  """
  @spec customize(keyword()) :: keyword()
  def customize(opts) when is_list(opts) do
    Keyword.update(opts, :steps, Forecastle.steps(@default_steps), &spliced/1)
  end

  # `Forecastle.steps/1` does the splice and there is deliberately no second
  # implementation of it here: it finds `:assemble`, puts the pre-assembly step
  # before it and the post-assembly step after it, and leaves everything around
  # them where it was. That it is Forecastle's function is the one thing
  # customize/1 exists to keep out of a consumer's `mix.exs`.
  defp spliced(steps) when is_list(steps) do
    warn_missing_tar(steps)
    Forecastle.steps(steps)
  end

  # Not a list, so there is nothing to splice into. `mix release` validates
  # `:steps` and its refusal names the option; a FunctionClauseError raised out
  # of Forecastle would name a module the project never mentioned, which is the
  # one thing this function is for.
  defp spliced(steps), do: steps

  # Said at the build, where the remedy is one atom, because the alternative is
  # an operator meeting it on a deployment as a `bin/castle unpack` with nothing
  # to unpack - and that failure names a missing file rather than the release
  # option that did not ask for it.
  #
  # It states the omission and stops. Nothing here knows the release was meant
  # to be distributed: the system an upgrade is installed *onto* needs no
  # tarball of its own, and `:tar` is Mix's own way of packing one - its
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
  # exist. Say what was seen, say what follows *unless* something else packs it,
  # and stop.
  defp warn_missing_tar(steps) do
    if :assemble in steps and :tar not in steps do
      Mix.shell().error(
        "warning: Castle.customize/1 was given a :steps list with no :tar step. " <>
          "Unless a step of your own packs one, this release will not produce the " <>
          "<name>-<vsn>.tar.gz that is copied into a deployment's releases " <>
          "directory for bin/castle unpack to read - and bin/castle unpack is how " <>
          "a version is installed onto a running system. Add :tar after :assemble " <>
          "if this version is meant to be installed anywhere. A deployment that is " <>
          "only ever upgraded *from* needs no tarball of its own."
      )
    end
  end

  # Every function in this module but customize/1 is a command entry point:
  # `bin/castle` sends each one to the running node over `bin/<release> rpc`,
  # and the launcher's env.sh fragment evaluates make_releases/0 in the preboot
  # VM, on the first start of a deployment. There is no separate CLI layer to
  # carry the process status, so these functions are the command boundary, and
  # it is here that a failure raises.
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
  Asks whether the system can be upgraded from, and says nothing when it can.

  `bin/castle upgradable`. A question rather than a gate: it reports nothing on
  success, and raises `Castle.Error` when the node is working from the release
  record `:release_handler` synthesised for itself out of the boot script. An
  upgrade from that record would report success and leave applications running
  from the directories of the release it replaced, so `unpack/1` and `install/1`
  refuse it; what this raises is the same refusal, with the same remedy in it.

  That record is what a node is left with when the release-record file
  `:release_handler` reads was not one the handler accepted when it booted, and
  no single property of the file is the test - being present, being readable and
  parsing as Erlang terms are each necessary and none of them sufficient. So the
  remedy the refusal names is a restart with that file either absent or
  accepted, and creating it now changes nothing about the record this node is
  working from. Which file it is depends on the deployment: `releases/RELEASES`
  under the release root unless `RELDIR` or the `sasl` `releases_dir` parameter
  points elsewhere, in which case the release creates one at the root that the
  handler will not read, and the one it does read has to be put there by hand.

  Nothing has to call this first. `unpack/1` and `install/1` make the check
  themselves, inside the call that acts, because an answer given to one caller
  and acted on by another is an answer about a moment that has passed - the node
  can restart onto a freshly synthesised record in between. What this is for is
  asking without acting, which is otherwise impossible: the file the handler
  reads can be there, and be perfectly good now, while the record the node has
  been working from since boot was made up.

  It only reads, so it still answers on a deployment where every command that
  changes something is refused - which is the state an operator most needs to be
  able to ask about.
  """
  @spec upgradable() :: :ok
  def upgradable do
    report!(Commands.upgradable())
  end

  @doc """
  Unpacks a release tarball into the deployment, and reports the version.

  `bin/castle unpack <vsn>`, which builds the argument as
  `<release name>-<vsn>` - `name` is the tarball's name without its `.tar.gz`
  suffix, the way `:release_handler.unpack_release/1` takes it, and not a bare
  version. The tarball itself has to have been copied into the deployment's
  `releases` directory first; it is the `<name>-<vsn>.tar.gz` that `mix
  release`'s `:tar` step packs, which is why `customize/1` defaults `:steps` to
  include it.

  Unpacking stages a version: it extracts the applications, writes a release
  record for it as `unpacked`, and changes nothing about what the system is
  running. `install/1` is what makes it the running version.

  Raises `Castle.Error` rather than unpacking on a system that cannot be
  upgraded from - see `upgradable/0`, and note that an unpack allowed through
  there would take the remedy away rather than merely being pointless: unpacking
  writes the release records, so the synthesised record lands in the file the
  remedy depends on and the next boot reads it back as though it had always been
  there.
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

  `bin/castle install <vsn>`, on a version that has been unpacked already - see
  `unpack/1`.

  Five steps run before `:release_handler.install_release/1` is asked for
  anything, and each of them can refuse the install:

    1. The deployment is checked against the root the emulator is running in -
       the condition the module documentation describes - and refused if they
       are not the same directory. It is the one step outside the serialising
       below, because it reads two directories and touches nothing.

    2. The release the system is running is looked up, and an install from the
       record `:release_handler` synthesised for itself is refused - see
       `upgradable/0`, and note that the check is made here, in the call that
       acts, rather than by anything in front of it. That one lookup answers
       both this and whether the relup's transition reboots the emulator;
       asking twice would be asking about two moments.

    3. An install that is going to reboot the emulator is refused while another
       such install is still waiting for its reboot. Where this sits is as
       load-bearing as what it does: the version a caller refused here would
       otherwise have configured in step 4 is the version the pending install's
       reboot is about to boot, so it is refused before it has written
       anything.

    4. The target's configuration is expanded, by booting a temporary VM on the
       target's own boot script and emulator and running the target's own
       config providers in it: the version being upgraded *to* is the one whose
       providers have to answer, and they cannot be run on the node that is
       still running the version being replaced. It is the first step that
       writes anything, which is why the three that can refuse for a reason
       about this node come first - an install refused above this has
       configured nothing.

    5. For a transition that reboots the emulator, the marker the launcher will
       read on the next start is armed. It can refuse too, and by then the
       configuration has been expanded, so those refusals say so: nothing was
       installed and nothing was made permanent, but the target's `sys.config`
       is the one this call wrote.

  So the boundary is `install_release/1` rather than the first call into
  `:release_handler` - step 2 is such a call, and steps 2, 3 and 5 are Castle's
  own refusals rather than OTP's.

  What it prints depends on the transition the relup asks for. A hot upgrade
  reports the version that is now running and the one it replaced. A transition
  that restarts the emulator cannot report that, because
  `:release_handler.install_release/1` replies and *then* reboots, so it reports
  that the version was installed, that the emulator is restarting, and that the
  version stays provisional until it is committed.

  Provisional is the ordinary state of a freshly installed version, restart or
  not: `commit/1` writes `releases/start_erl.data` and nothing else does, so
  until it runs that file still names the version that was permanent before.
  What that buys differs between the two transitions, and "any restart rolls
  back" is not true of both. After a hot upgrade, anything that takes the system
  down brings the previous version back. After a transition that restarts the
  emulator, the restart the install *asked for* is already accounted for: Castle
  leaves a marker naming the target beside the file `:release_handler` writes
  before rebooting, and the launcher consumes that pair on the next start and
  boots the target - which is the reboot the install reported, and the reason
  `install/1` returns before it has finished. It is the restarts *after* that
  one which read `start_erl.data` and come back on the previous permanent
  version. Either way nothing is made permanent by a crash, and until `commit/1`
  runs the rollback costs nothing.

  Confirming the install is a separate step for the same reason: what
  `install_release/1` replies says only that the upgrade was accepted, and it is
  the same reply either way. `bin/castle install` polls `running/1` across the
  reboot instead of trusting it, and automation driving an upgrade over `rpc`
  has to do the same.

  Two installs cannot run on this node at once: the second waits for the first,
  everything from step 2 onwards being serialised. It then meets step 3, and is
  refused if what it would do is reboot the emulator while the first install is
  still waiting for its own reboot - the file that tells the launcher which
  version to boot belongs to one install attempt, and is neither adopted nor
  replaced by the next.

  ## The four extra arguments

  `install/1` is the operator's form, and it is what `bin/castle` calls. The
  defaulted arguments - the releases directory, and the three modules the
  install talks to - are not an API and nothing in a deployment passes them:
  which releases directory the records and the configuration land in is a
  property of the installation rather than a caller's choice, which is why it is
  derived here.

  They exist so that a test can drive concurrent installs *through this
  function*. Serialising an install has to be true of this call and not merely
  of something below it: the defect that made the lock necessary was a step
  composed here, and a suite that could only reach one layer down would have
  stayed green while it was reintroduced.
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

  Says nothing when it is, and raises `Castle.Error` otherwise - naming the
  version that is running instead, or the progress a node that is still booting
  has reached. There is no `bin/castle` command of its own for it:
  `bin/castle install` polls this until it answers, or until it runs out of
  time, and that is what an installed version being confirmed means. Automation
  that installs over `rpc` rather than through `bin/castle` needs it for the
  same reason.

  Two conditions, and the second is the one that is easy to leave out. The
  version has to be the running release - the `current` one, or the `permanent`
  one when none is current, so a version that has been installed and one that
  has been committed both count, while a version left `unpacked` by a rollback
  does not. And its boot has to have finished: `:release_handler` records the
  new version while `sasl` starts, so the node answers before the applications
  after `sasl` are up, and one of those can still fail and take the system back
  to the previous release. Committing on the strength of that would make a
  version that cannot boot the permanent one.
  """
  @spec running(String.t()) :: :ok
  def running(vsn) when is_binary(vsn) do
    report!(Commands.running(vsn))
  end

  @doc """
  Makes `vsn` permanent, so that it is the version a restart boots into.

  `bin/castle commit [<vsn>]`. Given no version, `bin/castle` selects the
  release whose status is `current` - the one an install left provisional, and
  there is at most one of those - and fails, asking for a version explicitly,
  when there is none. So it is not "the version running now": a system running
  nothing but its permanent release has nothing awaiting commit, and saying so
  is a non-zero exit status rather than a no-op.

  This is what ends the provisional state an install leaves behind: it writes
  `releases/start_erl.data`, and nothing else does, so until it runs an ordinary
  restart boots the version that was permanent before and the rollback is free.
  (An install that restarts the emulator has one restart of its own already
  accounted for - see `install/1`.)

  The target's configuration is expanded again here, the way `install/1` expands
  it, and *before* the version is promoted, so what a commit leaves in place is
  what a boot at commit time would produce. That is the point of doing it here
  rather than trusting whatever the install wrote: config providers are not
  obliged to be idempotent, and the environment can have changed since.

  It follows that committing a version that is already permanent is not a
  no-op, even though OTP's promotion step is one. The expansion has happened by
  then: the version's `sys.config` has been rewritten from the provider inputs
  of the moment, and a provider that fails now fails the command. An explicit
  commit is a request to configure and promote, not a request to promote if
  promotion is outstanding.

  Raises `Castle.Error` if the configuration could not be expanded, or if the
  version is not one `:release_handler` will promote: a version that is staged
  and not installed is refused - which includes one a rollback returned to that
  state - as are a superseded version and one it has never heard of.
  """
  @spec commit(String.t()) :: :ok
  def commit(vsn) when is_binary(vsn) do
    report!(Commands.commit(vsn, rel_dir()))
  end

  @doc """
  Removes `vsn` from the system, and deletes what nothing else is using.

  `bin/castle remove <vsn>`. It takes away the version's own release directory,
  every library directory no remaining release refers to, and the `erts-<vsn>`
  if that version of the emulator is now unreferenced.

  It deletes rather than merely forgets, which is the point of having it: a
  deployment that never removes a superseded version only grows. Raises
  `Castle.Error` for the permanent version, which `:release_handler` refuses
  outright, and for a version it has no record of.
  """
  @spec remove(String.t()) :: :ok
  def remove(vsn) when is_binary(vsn) do
    report!(Commands.remove(vsn))
  end

  @doc """
  Lists the releases the system knows of, and the status of each.

  `bin/castle releases`. One line per release: the version, and the status
  `:release_handler` holds for it. In an ordinary deployment that is `permanent`
  for the version a restart boots, `current` for one that is running but has not
  been committed, `unpacked` for one that is staged and not currently installed,
  and `old` for one that has been superseded and not removed.

  `unpacked` is not "never installed". It is where `unpack/1` leaves a version,
  and it is also where a version ends up when an install of it failed or was
  rolled back - notably an emulator upgrade that came back up and could not
  finish, which `running/1` describes. The status says what the system will do
  with the version, not what has been tried with it.

  It only reads, so like `upgradable/0` it still answers on a deployment where
  every command that changes something is refused - it is what an operator asks
  in order to make sense of such a refusal. A system that knows of no releases
  reports nothing rather than an empty table.
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
