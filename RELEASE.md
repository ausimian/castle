### Added

- `Castle.Error`, the exception raised by a release-management command that did
  not succeed.
- `Castle.running/1`, which succeeds when the version it is given is the
  release the system is running, and fails otherwise. `install/1` reports what
  `:release_handler` replied, and that reply says only that the upgrade was
  accepted: a transition that restarts the emulator is replied to and *then*
  rebooted, and for an emulator upgrade the instructions run on the way back
  up, where they can still fail and roll back. Completion therefore has to be
  observed, and `bin/castle install` polls this to observe it. The running
  release is the one whose status is `current`, or the `permanent` one if none
  is current, so a version is confirmed both before and after `commit`.
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
