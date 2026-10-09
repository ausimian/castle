# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

<!-- %% CHANGELOG_ENTRIES %% -->

## 1.0.1 - 2026-10-09

### Added

- Castle now ships an appup, so a consumer upgrade that moves Castle from 1.0.0
  is a hot upgrade under `auto`. Previously, unless the consumer supplied an
  appup for Castle under `rel/appups`, Forecastle generated an emulator restart
  for any upgrade that changed Castle's version.

### Fixed

- Castle now uses the same releases directory as `:release_handler`, following
  the SASL `releases_dir` option, then `RELDIR`, then `<root>/releases`, with a
  relative directory resolved against the release root. Previously it always
  used `<root>/releases`. On a deployment that set either override, it wrote
  `RELEASES` and the target's configuration where the handler never read them.
- Configuring a target release now uses the deployment's root for its
  applications and emulator, rather than the directory two levels above the
  version directory, so it works when the releases directory has been moved.

## 1.0.0 - 2026-09-28

Castle 1.0 resolves each target release's configuration with that release's
own code and config providers, and adds upgrades that restart the emulator under
an external supervisor. It requires Forecastle 1.x and Elixir 1.18 or later.
Two changes break existing pipelines: `mix forecastle.relup` is now
`mix castle.relup`, and `Castle.generate/1` has been removed.

### Added

- `Castle.customize/1`, the release integration API. It adds Forecastle's steps
  around `:assemble` and defaults missing release steps to `[:assemble, :tar]`.
  ([#12](https://github.com/ausimian/castle/issues/12))
- Relup generation during assembly. Name baselines in `upgrade_from:` (a shipped
  `tar:` archive, an assembled `rel:` release or a `ref:` git ref) and one
  `mix release` produces a tarball carrying both its upgrade and downgrade
  instructions.
  ([forecastle#28](https://github.com/ausimian/forecastle/issues/28),
  [forecastle#40](https://github.com/ausimian/forecastle/issues/40))
- Upgrade tooling from Forecastle:
  - `mix castle.appup`, which checks that an appup covers every module that
    changed between two builds.
    ([forecastle#27](https://github.com/ausimian/forecastle/issues/27))
  - `mix castle.appup.gen`, which drafts missing appup entries for review,
    including for dependencies with `--app <dep>`.
    ([forecastle#29](https://github.com/ausimian/forecastle/issues/29),
    [forecastle#30](https://github.com/ausimian/forecastle/issues/30))
  - `mix castle.relup --dry-run`, which reports whether a transition can be hot
    without writing a relup.
    ([forecastle#31](https://github.com/ausimian/forecastle/issues/31))
  - `Forecastle.UpgradeCase` and `Forecastle.Deployment`, a harness for testing
    upgrades against a shipped artifact.
    ([forecastle#32](https://github.com/ausimian/forecastle/issues/32))
- Target configuration resolved in a temporary VM running the target release's
  boot script, emulator and config providers.
  ([#13](https://github.com/ausimian/castle/issues/13))
- `Castle.upgradable/0`, and matching checks in `unpack/1` and `install/1`, which
  refuse nodes running a release record synthesised by `:release_handler` and
  explain how to recover.
- `Castle.running/1`, which confirms that a version is running and has finished
  booting.
- One-stage `restart_emulator` upgrades under systemd, Docker, Kubernetes and
  other external supervisors.
  ([#14](https://github.com/ausimian/castle/issues/14))

### Changed

- **Breaking:** `mix forecastle.relup` is now `mix castle.relup`. There is no
  compatibility alias, so build pipelines calling the old name must be updated.
  `mix compile.appup` is unchanged.
  ([forecastle#24](https://github.com/ausimian/forecastle/issues/24))
- Release commands raise `Castle.Error` on a refusal or an error from
  `:release_handler`, so `bin/castle` exits non-zero. Output on success is
  unchanged. ([#10](https://github.com/ausimian/castle/issues/10))
- Installs and commits on a node are serialised with configuration resolution.
- The minimum supported Elixir version is 1.18.

### Removed

- **Breaking:** `Castle.generate/1` and the `build.config` configuration path.
  Each target release is now configured by its own config providers.

### Fixed

- `install/1` reports an upgrade that replaces the emulator, kernel, stdlib or
  sasl instead of crashing with `CaseClauseError`.
- `releases/0` prints nothing when no release is installed instead of raising
  `Enum.EmptyError`.
- `make_releases/0` reports `RELEASES` read and write errors instead of raising
  `MatchError`, and finds the release directory from the running emulator rather
  than the current working directory.
- Resolved configuration is staged with owner-only permissions and published
  atomically, keeping the original `sys.config` mode.
- Commands that modify a deployment refuse a release whose emulator root differs
  from the release root, including one built with `include_erts: false`, instead
  of letting `:release_handler` modify the shared Erlang installation.

## 0.3.1 - Jan 19, 2025

- Switch to charlist sigils

## 0.3.0 - May 27, 2023

- Move build time support into Forecastle

## 0.2.3 - May 21, 2023

- Fix bug in shell script that prevented execution on Linux

## 0.2.2 - May 21, 2023

- Update Changelog

## 0.2.1 - May 21, 2023

- Update README

## 0.2.0 - May 21, 2023

- Added support for Config Provider expansion

## 0.1.3 - May 16, 2023

- Initial revision
