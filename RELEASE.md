Castle 1.0 moves target configuration into the target release and adds safe
support for upgrades that restart under an external supervisor. It requires
Forecastle 1.x and Elixir 1.18 or later.

### Added

- `Castle.customize/1` as the release integration API. It adds Forecastle's
  steps around `:assemble` and defaults missing release steps to
  `[:assemble, :tar]`.
- Target configuration through a temporary VM running the target release's boot
  script, emulator and config providers. Each run starts from the original
  `sys.config` and validates the compile environment before installation.
- `Castle.upgradable/0` and matching checks in `unpack/1` and `install/1` to
  refuse nodes using a release record synthesised by `:release_handler`.
- `Castle.running/1` so installers can confirm that a version is running and has
  finished booting.
- Support for one-stage `restart_emulator` upgrades under systemd, Docker,
  Kubernetes and other external supervisors. Installs are serialised and use an
  attempt-owned marker to carry the target version across the restart.
- Public documentation and specs for the Castle command surface.

### Changed

- Release-management commands now raise on refusal or a returned OTP error, so
  `bin/castle` exits non-zero. Successful command output is unchanged.
- `make_releases/0` now derives the release directory from the running emulator
  instead of the current working directory.
- The minimum supported Elixir version is now 1.18.

### Removed

- `Castle.generate/1` and the `build.config` configuration path. Castle 1.0
  configures every target release with that release's own providers.

### Fixed

- Protect pristine and resolved configuration files with owner-only staging,
  atomic publication and the original `sys.config` mode.
- Refuse deployments whose emulator root differs from the release root,
  including releases built with `include_erts: false`, before Castle can modify
  the shared Erlang installation.
- Give actionable recovery instructions when `:release_handler` booted without
  an accepted `RELEASES` file.
- Report restart installs without raising `CaseClauseError`.
- Return an empty release list without raising `Enum.EmptyError`.
- Report `RELEASES` read and write errors instead of raising `MatchError`.
