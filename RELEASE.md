### Added

- `Castle.Error`, the exception raised by a release-management command that did
  not succeed.

### Changed

- Raised the minimum Elixir requirement to 1.18.
- `unpack/1`, `install/1`, `commit/1`, `remove/1`, `generate/1` and
  `make_releases/0` now fail when the operation fails, instead of printing the
  reason and returning normally. These are invoked over `bin/castle`, which
  reaches them by `rpc`, and by the launcher's preboot `eval`, so the reason
  now arrives on the caller's standard error and the command exits non-zero:
  `bin/castle unpack "$VSN" && bin/castle install "$VSN"` stops at the step
  that failed, and a deployment that did not happen no longer looks like one
  that did. The running system is unaffected - the failure is raised on the
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
