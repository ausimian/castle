Castle 1.0 moves target configuration into the target release and adds safe
support for upgrades that restart under an external supervisor. It requires
Forecastle 1.x and Elixir 1.18 or later.

### Added

- `Castle.customize/1` as the release integration API. It adds Forecastle's
  steps around `:assemble` and defaults missing release steps to
  `[:assemble, :tar]`.
- Relup generation during assembly. A release that names one or more baselines
  with the `upgrade_from:` option — `tar:` a shipped tarball, `rel:` an
  assembled release or `ref:` a git ref — has its relup generated into the
  version being assembled by a step placed immediately before `:tar`, so the
  default `[:assemble, :tar]` produces a tarball carrying its own upgrade plan
  from a single `mix release`. A project that packs its own archive, in a step
  with no `:tar` or in one placed after it, has to place the generating step
  itself; `Castle.customize/1` and the README give the rule. Both directions are
  generated for every baseline. This replaces the build-generate-rebuild cycle
  `mix castle.relup` required, which the README documented without ever saying
  that it was two builds. `mix castle.relup` remains for a target that is
  already assembled, for separate up and down baselines, and for the
  `--hot`/`--restart` strategies; it takes the same baseline specs, so a `ref:`
  baseline is built there too. A project-root `relup` and `upgrade_from:`
  together are refused rather than ordered by precedence. Omitting the option
  assembles exactly as before.
  ([forecastle#28](https://github.com/ausimian/forecastle/issues/28))
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

- `mix forecastle.relup` is now `mix castle.relup`, and the README documents it
  as Castle's while naming Forecastle as its implementer. There is no
  compatibility alias, so a build pipeline calling the old name has to be
  updated. Nothing changes in `deps` — Castle already brings Forecastle in at
  build time, and which half implements a task is a packaging decision rather
  than something a consumer should have to learn. The appup compiler is **not**
  renamed and is unaffected: it stays `mix compile.appup`, named by its
  `:compilers` entry rather than by either package.
  ([forecastle#24](https://github.com/ausimian/forecastle/issues/24))
- Release-management commands now raise on refusal or a returned OTP error, so
  `bin/castle` exits non-zero. Successful command output is unchanged.
- The missing-`:tar` build warning now says something different when the release
  also sets `upgrade_from:`. With no `:tar` the relup step is appended last, so
  a step of the project's own that packs the archive packs it before the relup
  is generated — and the previous wording told the author, on the error channel,
  that no change was needed. It now states the rule that governs where the relup
  step goes — after every step that changes the release, immediately before the
  one that packs what ships — says what adding `:tar` achieves and what falls
  outside it, and withdraws the two qualifications that do not hold for a
  release naming baselines. The wording is unchanged for a release that does not
  set the option.
- Operator-facing errors and warnings are shorter, distinguish preflight
  refusals from attempted operations, report whether the configuration step ran,
  and preserve paths, reasons and recovery steps.
- `make_releases/0` now derives the release directory from the running emulator
  instead of the current working directory.
- The minimum supported Elixir version is now 1.18.

### Removed

- `Castle.generate/1` and the `build.config` configuration path. Castle 1.0
  configures every target release with that release's own providers.

### Fixed

- A `&Forecastle.generate_relup/1` a project placed in its own release steps is
  now honoured rather than joined by a second appended copy, so the relup is
  generated once, where the project asked for it. The README previously
  documented the duplicate — and the differing on-disk and archived relups it
  produced — as expected behaviour. A step placed after `:tar`, where the relup
  it writes could never be packaged, is now refused at the build instead of
  succeeding and shipping an archive with no upgrade plan in it.
  ([forecastle#38](https://github.com/ausimian/forecastle/issues/38))
- Protect pristine and resolved configuration files with owner-only staging,
  atomic publication and the original `sys.config` mode.
- Refuse deployments whose emulator root differs from the release root,
  including releases built with `include_erts: false`, before Castle can modify
  the shared Erlang installation.
- Give actionable recovery instructions when `:release_handler` booted without
  an accepted `RELEASES` file.
- Clarify restart-marker failures, including whether the configuration step ran,
  whether `new_start_erl.data` was removed or already absent, and when release
  records, `castle-restart-pending` and `new_start_erl.data` must be inspected
  before restarting, retrying or removing a marker. Also explain the `unpacked`
  record left by an unfinished install and fix the former "a other" wording for
  named pipes and similar marker-path conflicts.
- Report a failed commit as possibly partial instead of claiming the version was
  not made permanent. `:release_handler` writes `releases/start_erl.data` before
  it updates the release record, so an error can leave the file that selects the
  boot version already naming the target; the message now says so and directs
  the operator to inspect release state.
- Report restart installs without raising `CaseClauseError`.
- Return an empty release list without raising `Enum.EmptyError`.
- Report `RELEASES` read and write errors instead of raising `MatchError`.
