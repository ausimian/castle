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
  when the file is not there it makes a release record up out of the boot
  script's name and version — a record that names no applications at all.
  Upgrading a system in that state is worse than being stopped: the install
  reports success, and every application whose version changed but whose code the
  upgrade does not explicitly load goes on running its old code out of the
  directory of the release that was just replaced, until a later `remove` deletes
  it. Nothing can repair the running system afterwards, because creating the file
  changes no record the node holds — so what the refusal says is to restart,
  which is the one thing that does: the release creates the file before it
  starts.

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
  since the file is only created when it is missing. Committing and removing are
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
  asking, and the Forecastle this release is built against does not yet ask.

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

  Nothing can build a relup that restarts the emulator until
  [forecastle#4](https://github.com/ausimian/forecastle/issues/4), so the
  restart transitions this addresses cannot be exercised end to end yet. The
  hot-upgrade path is covered by Forecastle's end-to-end suite; the statuses
  themselves are covered by unit tests here.

### Changed

- Raised the minimum Elixir requirement to 1.18.
- `make_releases/0` no longer depends on the working directory. It looks for
  `releases/RELEASES` under the root of the release - `code:root_dir()`, which is
  the root `:release_handler` resolves its own relative paths against - so the
  file it looks for is necessarily the file OTP writes, and a caller that used to
  change directory before calling it no longer has to.
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

- `install/1` reports the emulator restart that an upgrade to a new emulator,
  or to a new kernel, stdlib or sasl, needs - rather than failing with a
  `CaseClauseError` while the upgrade proceeds.
- `releases/0` reports nothing at all, rather than raising `Enum.EmptyError`,
  when no releases are installed.
- `make_releases/0` says what went wrong - which file could not be read or
  written, and why - rather than raising `MatchError`.
