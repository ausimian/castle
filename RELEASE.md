### Added

- The configuration of the version being installed is now expanded by running
  *that version's* config providers, in a temporary VM booted from that
  version's own boot script on its own emulator, rather than by running provider
  state stashed at build time in the version that happens to be running. A
  provider module can differ between the two — which is precisely what an
  upgrade may change — and only the target's own answer is the right one. It
  also leaves Elixir's `Config.Provider` as the single implementation of the
  provider pipeline: Castle drives it and no longer keeps a copy of it.

  The temporary VM needs no epmd, no cookie, no node name and no distributed
  Erlang: it talks to the running node over a socket on the loopback interface,
  and whatever it prints — a provider explaining what it could not find, say —
  arrives on the terminal that asked for the install. It is stopped on every way
  out, including every failing one, and it cannot hold an install open: both its
  boot and the work it is asked to do have deadlines. Everything that can refuse
  to go on refuses before the upgrade is applied, so configuration that cannot
  be expanded leaves an install that did not happen rather than one that
  half did.

  Each expansion starts from the configuration the release was built with, which
  the first one copies aside as `sys.config.pristine` and none of them
  overwrites. Config providers are not obliged to be idempotent, and the
  familiar ones are not: a `runtime.exs` that sets a key only when an
  environment variable is present says nothing about that key when it is absent,
  so expanding over the previous result would leave a value behind after the
  provider had stopped supplying it — and the version made permanent would be
  configured differently from the way it goes on to boot. Expanding from the
  original instead means installing and then committing produce the same answer
  a boot would, which is the point of expanding at either. That copy is made
  atomically and with the permissions `sys.config` has, so a partly written one
  can never be found and read, and restricting `sys.config` — as an operator
  might, since it holds credentials — restricts this too.

  Among the things that refuse is the check Elixir makes on a configuration
  before booting into it: that what `Application.compile_env/3` read when the
  release was compiled is what the resolved configuration says now. A version
  whose runtime configuration contradicts what it was compiled against is
  refused here, where refusing costs nothing, rather than accepted and then
  found to be unbootable — which, for an upgrade that restarts, is found on the
  way back up with a rollback as the only way out.

  This is how every release is configured now, and the only way: the path that
  read a `build.config` is gone, along with the build-time interception that
  produced one — see *Removed* below.
- `Castle.unpack/1` and `Castle.install/1` now refuse a system that cannot be
  upgraded from, and refuse it in the same call that would otherwise have done
  the work. `:release_handler` reads `releases/RELEASES` once, as it starts, and
  when it cannot — the file absent, or there but not something it accepts — it
  makes a release record up out of the boot script's name and version — a record
  that names no applications at all.
  Upgrading a system in that state is worse than being stopped: the install
  reports success, and every application whose version changed but whose code the
  upgrade does not explicitly load goes on running its old code out of the
  directory of the release that was just replaced, until a later `remove` deletes
  it. Nothing can repair the running system afterwards, because creating the file
  changes no record the node holds — so what the refusal says is to restart, with
  the file either absent or accepted first. See *Fixed* below for what that
  condition is and why a bare restart is not always enough.

  The question is asked of the node's own records rather than of the filesystem,
  which is the only way to see the case where the file exists but the boot that
  went looking for it was earlier — and it is asked by the operation, rather than
  of the operator beforehand. A check made in one call and acted on in another is
  a check about a moment that has passed: the node can restart in between, and
  the node that comes back makes a fresh record up, so the operation would go
  ahead on an answer that no longer held.

  Unpacking is refused as well as installing because it is the one other
  operation that *writes* release records: an unpack on such a node would put the
  made-up record into `releases/RELEASES`, where the next boot would read it back
  as though it belonged there — which takes away the restart that is the way out,
  since the file is only created when it is absent. Committing and removing are
  unaffected: neither can write that record back, and refusing them could strand
  a version that was already installed.
- `Castle.upgradable/0`, which answers the same question on its own, for an
  operator who wants to know whether a system can be upgraded from without
  unpacking or installing anything. Nothing has to call it first — the operations
  that need the answer get it for themselves.
- `Castle.Error`, the exception raised by a release-management command that did
  not succeed.
- `Castle.running/1`, which succeeds when the version it is given is the
  release the system is running, and fails otherwise. `install/1` reports what
  `:release_handler` replied, and that reply says only that the upgrade was
  accepted: a transition that restarts the emulator is replied to and *then*
  rebooted, and for an emulator upgrade the instructions run on the way back
  up, where they can still fail and roll back. Completion therefore has to be
  observed rather than inferred, and this is what makes it observable: a caller
  that repeats the question until it is answered - which is what Forecastle's
  `bin/castle install` does, from its own 1.0.0 - can tell an upgrade that took
  effect from one that did not. Castle supplies the answer; it does not do the
  asking.

  Confirmation needs two things: the version is the release the system is
  running - the one
  whose status is `current`, or the `permanent` one if none is current, so a
  version is confirmed both before and after `commit` - *and* its boot has
  finished. The second is not redundant. A node that restarted into the new
  version is reachable long before it has finished booting: `release_handler`
  makes the version `current` while `sasl` starts, and distribution answers
  from `kernel` onwards, so an application started after `sasl` can still fail
  and take the system back to the version that was permanent. Confirming
  earlier than that would let automation `commit` a release that cannot boot.

  "Finished booting" means the boot script reached its `{progress, started}`
  instruction, which is the last thing every boot script Mix generates does.
  A release booted with a `RELEASE_BOOT_SCRIPT` that names a hand-written
  script without that marker will therefore never be confirmed: `install` waits
  and then fails, and the refusal names the progress the node did reach, so it
  says what is wrong rather than failing silently - but it will not succeed. A
  script that emits the marker before its applications are started defeats the
  check instead, since the marker is all there is to go on.

  Both the hot-upgrade path and the emulator-restart path are covered end to end
  by Forecastle's `:e2e` suite, which polls through a real reboot.
- Upgrades that restart the emulator now work on a release supervised by
  systemd, Docker, Kubernetes or anything else that owns starting the service.
  `Castle.install/1` recognises such a transition from the relup before it asks
  `:release_handler` for anything, and leaves a marker beside the release records
  naming the version being installed. The launcher's `env.sh` fragment, which
  Forecastle 1.0.0 contributes, consumes that marker on the next start and boots
  the version it names.

  Two files have to agree for that to happen, and the reason is worth stating:
  `:release_handler` writes `releases/new_start_erl.data` *before* the reboot and
  nothing ever removes it, so a preparation that failed part-way leaves a file
  naming a version that was never installed. Castle's own marker is what says a
  reboot was really asked for; it is written immediately before the install and
  removed on every path where the install failed, and the launcher requires both
  files and requires them to name one version. An install whose marker cannot be
  written - a release root nothing may write to - is refused rather than
  performed, because the alternative is a reboot that silently comes back on the
  version it was upgrading away from.

  Agreeing on a version is not on its own enough, so the pair belongs to one
  install *attempt* rather than to a version. Any `new_start_erl.data` left by an
  earlier attempt is cleared before a new marker is armed - otherwise a retry of
  the same version would arm a marker beside a file it did not write, and a
  restart before the retry reached `:release_handler` would boot a version that
  nothing had installed.

  Only one install runs on the node at a time, and that is what makes the
  clearing mean anything: two of them could otherwise both decide to arm before
  either had, and the second would clear the `new_start_erl.data` the first one's
  reboot depends on - leaving the first system to come back on the version it was
  upgrading away from, while the second reported that nothing had been changed.
  An install that has to wait waits, and then finds the first one's marker.

  What is serialised is `Castle.install/1` itself, and that includes
  materialising the target's configuration. It is worth saying which parts, since
  "the whole operation" was claimed here while the configuration step was still
  outside: materialising ends by renaming a resolved configuration onto the
  target's `sys.config`, so two callers doing it before either reached the lock
  meant the loser's config providers - evaluated in a VM of their own, with
  whatever environment that caller had - could replace the configuration the
  winner's provisional release was about to boot, after which the loser was
  refused for the winner's marker. The install that was refused decided what the
  install that succeeded booted. Configuration providers are not obliged to
  produce the same answer twice, which is the reason `sys.config.pristine` exists
  in the first place.

  So the region now runs from the release-record lookup through the
  configuration step to `install_release/1` and the marker being settled, and a
  caller that is going to be told a restart install is pending is told *before*
  it configures anything. Only the ERTS guard is outside, because it reads two
  directories and refuses without touching anything.

  `commit` is serialised the same way, and for a reason that is not obvious: it
  configures the version too, so a duplicate install of the version being
  committed could configure it between commit's two steps - the commit would
  succeed, that install would then fail as already installed, and its
  configuration would be what the newly permanent release booted on the next
  restart. A failed caller deciding what a successful one boots. `unpack` and
  `remove` are not serialised: they configure nothing and arm nothing.

  Which kind of transition an install is, is decided from the release the system
  is running, and another install completing in between would change that answer -
  which is the other reason the region reaches past the arming.

  A restart install while another one is already pending
  is refused rather than allowed to take over its marker, saying so and changing
  nothing; the marker is consumed by the next start of the deployment, so a
  restart clears one left behind by an install that was interrupted. And the
  marker records which attempt armed it, so a failed install removes only its own
  - a start of the deployment consumes the marker whether or not it goes on to
  boot, so the file at that path when an install fails is not necessarily the one
  that install wrote. It is published by linking a file that is already complete
  into place, the way the pristine configuration above is, so no start can read a
  marker that is half written and a race is refused rather than silently won.

  The marker is settled on **every** way out of the install, including the ones
  that do not return: an exit, a throw or a raise out of `install_release/1` is
  caught, the marker dealt with, and the failure then let out unchanged. Before,
  only a returned error cleared it - so an exception left the marker armed, and
  where `:release_handler` had already written its own file the pair was complete
  and the next start booted a version whose install had blown up.

  And an install that cannot settle its marker now **says so, and says what it
  means**, rather than reporting the original failure alone. A marker Castle
  could not remove, or could not read well enough to tell whether it was still
  its own, is a live instruction to the next start of that system: the failure
  message names the file, says that `new_start_erl.data` may already be beside
  it, says that an ordinary restart will therefore boot the version the install
  did not finish, and asks for the marker to be removed first. Clearing it used
  to be best effort on the argument that a directory the marker cannot be removed
  from is one it could not have been linked into - which holds only if nothing
  changed in between, and `install_release/1` runs in between.

  What the install *reports* is different for such a transition, because
  `install_release/1` replies the same `{ok, Vsn, Descr}` for a completed hot
  upgrade and for one that is about to reboot. Rather than say "Now running", it
  says that the version was installed, that the emulator is restarting, and that
  the version stays provisional until it is committed - which is what
  `releases/start_erl.data` still naming the previous version means. `bin/castle
  install` goes on asking the system what it is running across the reboot, and
  exits 0 once the installed version answers.

  The rollback that provisional state buys is real and needs nothing:
  `make_permanent/1` is the only thing that writes `releases/start_erl.data`, so
  a provisional release that dies before `Castle.commit/1` is followed by an
  ordinary start of the version that was permanent before.

  The two-stage `restart_new_emulator` transition remains unsupported. It reboots
  into a temporary hybrid release whose version directory holds a boot script and
  a configuration and none of the launcher's own files, so there is nothing for a
  launcher to boot; Forecastle refuses to generate one.

### Changed

- Raised the minimum Elixir requirement to 1.18.
- `make_releases/0` no longer depends on the working directory. It looks for
  `releases/RELEASES` under the root of the release - `code:root_dir()` - so a
  caller that used to change directory before calling it no longer has to. On a
  release built by Mix that is the file OTP writes; a deployment that sets
  `RELDIR` or the `sasl` `releases_dir` parameter moves the release records
  elsewhere, and Castle does not yet follow them.
- `Castle.install/1` accepts four further arguments, all defaulted, naming the
  releases directory and the modules it talks to. `Castle.install("1.2.3")` is
  unchanged and is still what `bin/castle` calls; the arguments exist so that
  concurrent installs can be exercised through the function an operator actually
  invokes, rather than one layer below it.
- `unpack/1`, `install/1`, `commit/1`, `remove/1` and
  `make_releases/0` now fail when the operation fails, instead of printing the
  reason and returning normally. These are invoked over `bin/castle`, which
  reaches them by `rpc`, and by the launcher's preboot `eval`, so the reason
  now arrives on the caller's standard error and the command exits non-zero:
  `bin/castle unpack "$VSN" && bin/castle install "$VSN"` stops at the step
  that failed, and an operation the system refused no longer exits 0. The
  running system is unaffected - the failure is raised on the
  node, re-raised in the short-lived VM that made the call, and it is that VM
  which exits. What a successful command reports is unchanged.

### Removed

- `Castle.generate/1`, and with it the path through `install/1` and `commit/1`
  that read a `build.config`. Expanding the target's configuration by folding
  provider state stashed at build time over a renamed `sys.config`, in whichever
  version happens to be running, is what the temporary VM above replaces - and
  from Forecastle 1.0.0 nothing assembles a release that has a `build.config` to
  read. Runtime configuration on a normal boot is Mix's own again, and the
  configuration of a version being installed is expanded by that version's own
  providers.

### Fixed

- The refusal for a system running from a synthesised release record now names a
  remedy that works. It said to restart, and a restart alone is enough only when
  the `RELEASES` file `:release_handler` reads is absent or accepted by the handler
  itself: present, readable and parsing as Erlang terms are each necessary and none
  of them sufficient. The release creates the file only when it is *absent*, so
  anything left in place that the handler will not accept is stepped over on every
  start and the system comes back on another synthesised record. An operator following the old message would have restarted
  indefinitely.

  The refusal now asks for that file to be absent or accepted before the restart,
  and identifies it rather than assuming: `releases/RELEASES` under the release
  root, unless `RELDIR` or the `sasl` `releases_dir` parameter points elsewhere.
  Where one of those does, the two are different files and a restart cannot fix it
  on its own — the release creates the one at the root, which the handler will not
  read — so the file the handler *does* read has to be put there by hand. Castle
  following those overrides itself is
  [#23](https://github.com/ausimian/castle/issues/23).

- A release built with `include_erts: false` is now refused, by name and with
  the reason, rather than quietly managing the Erlang installation it happens to
  be running on. Such a release ships no emulator, so it runs the system one, and
  `code:root_dir()` — the directory `:release_handler` extracts applications
  into, resolves every `lib/<app>-<vsn>` against, and deletes `erts-<vsn>` from —
  is then the shared Erlang installation rather than the deployment. Left to itself, `make_releases/0` created that installation's
  `releases/RELEASES`, which usually fails for want of permission and, where it
  succeeds, puts the release records of unrelated deployments in one file;
  `unpack/1`, `install/1` and `commit/1` wrote into the installation, and
  `remove/1` deleted out of it. Each of those now fails instead, with a message
  naming both directories and saying that the deployment cannot be upgraded by
  Castle. The same refusal covers a release that *did* bring its ERTS but is run
  with `ERL_ROOTDIR` set, which the release's own `erl` honours ahead of its
  location: what makes an upgrade unsafe is that the two directories differ, so
  the message reports that and offers the causes as examples rather than
  asserting one.

  Relocating the release records with `RELDIR` or the `sasl` `releases_dir`
  parameter does not make such a deployment upgradable, and the refusal says so.
  Those really do move the records — `release_handler` reads them ahead of the
  emulator's root — but they move only the bookkeeping: applications are still
  extracted into, resolved against and deleted out of the emulator's root, which
  the handler keeps as separate state.

  The remedy is to make the two directories the same one — most often by
  building the release with its ERTS included, and where `ERL_ROOTDIR` is what
  moved them apart, by unsetting it. There is no third option in which Castle is
  pointed somewhere else instead: `:release_handler` resolves the applications
  themselves against the emulator's root, so records kept anywhere else describe
  applications the handler is not using. A refusal that says so is better than a
  divergence that does not.

  Where the two directories cannot be compared at all — a `stat` refused by a
  mode on a parent, a path that is not there, a filesystem reporting no inode
  numbers — the refusal says *that*, naming what stopped the lookup, rather than
  reporting a difference it did not establish. It still refuses, because a
  comparison that could not be made is no licence to write release records into a
  tree that has not been shown to be the right one.

  `upgradable/0` and `releases/0` are deliberately unaffected. They only read,
  and they are what an operator needs working in order to make sense of the
  refusal.

  Note that this reaches the launcher's preboot step, which is where
  `make_releases/0` is called, so such a deployment meets the refusal on every
  start rather than once: the file the step looks for never appears, so the step
  runs again each time.

  What that costs a start is Forecastle's to decide, not Castle's — Castle
  reports the failure and the `env.sh` fragment chooses what to do with it. Under
  Forecastle 1.0.0 the fragment warns and carries on, so an affected deployment
  still starts, at the price of a warning and a short-lived VM per boot. Pair
  Castle 1.0.0 with Forecastle 1.0.0; an older fragment treats a failure of that
  step as fatal and would stop such a deployment starting at all.
- `install/1` reports the emulator restart that an upgrade to a new emulator,
  or to a new kernel, stdlib or sasl, needs - rather than failing with a
  `CaseClauseError` while the upgrade proceeds.
- `releases/0` reports nothing at all, rather than raising `Enum.EmptyError`,
  when no releases are installed.
- `make_releases/0` says what went wrong - which file could not be read or
  written, and why - rather than raising `MatchError`.
