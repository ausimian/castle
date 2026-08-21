### Added

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
- `unpack/1`, `install/1`, `commit/1`, `remove/1`, `generate/1` and
  `make_releases/0` now fail when the operation fails, instead of printing the
  reason and returning normally. These are invoked over `bin/castle`, which
  reaches them by `rpc`, and by the launcher's preboot `eval`, so the reason
  now arrives on the caller's standard error and the command exits non-zero:
  `bin/castle unpack "$VSN" && bin/castle install "$VSN"` stops at the step
  that failed, and an operation the system refused no longer exits 0. The
  running system is unaffected - the failure is raised on the
  node, re-raised in the short-lived VM that made the call, and it is that VM
  which exits. What a successful command reports is unchanged.

### Fixed

- `install/1` reports the emulator restart that an upgrade to a new emulator,
  or to a new kernel, stdlib or sasl, needs - rather than failing with a
  `CaseClauseError` while the upgrade proceeds.
- `releases/0` reports nothing at all, rather than raising `Enum.EmptyError`,
  when no releases are installed.
- `generate/1` and `make_releases/0` say what went wrong - which file could not
  be read or written, and why - rather than raising `MatchError`.
