# Castle

Runtime support for hot-code upgrades in Elixir releases. Castle is the runtime
half of a pair: [Forecastle](https://github.com/ausimian/forecastle) is the
build-time half. Consumers depend on Castle, which pulls Forecastle in as a
build-time dependency.

## What it does

Castle's job is configuration and release management on a running node.

- **`Castle.generate/1`** — reads `build.config` from the release's version
  directory, folds the stashed config providers over it, and writes the result
  as that version's `sys.config`. This is the whole reason the pair exists:
  Mix expands runtime configuration once, at boot, from the version it booted;
  Castle re-expands it for the version being upgraded *to*, before the relup
  runs.
- **`Castle.make_releases/0`** — creates the `RELEASES` file from the running
  permanent release if it does not already exist, so a release assembled by Mix
  can manage its own upgrades.
- **`unpack/1`, `install/1`, `commit/1`, `remove/1`, `releases/0`** — wrappers
  over `:release_handler`, with `generate/1` called ahead of `install` and
  `commit` so the target version's configuration exists before it is booted.
- **`Castle.running/1`** — succeeds when the version it is given is the release
  the system is running. `install_release/1`'s reply says only that the upgrade
  was accepted: a transition that restarts the emulator is replied to and then
  rebooted, and an emulator upgrade finishes on the way back up, where it can
  still roll back. So Castle answers the question and leaves the asking to
  Forecastle: `bin/castle install` repeats it rather than trusting the reply,
  from Forecastle 1.0.0 — the revision pinned in this project's `mix.lock`
  installs with a single rpc and never calls this, so do not describe the
  polling as something Castle's own integrated state does. Two conditions. The
  version is the running release: the
  `current` one, or the `permanent` one when none is current — `install` leaves
  its target `current` and `commit` promotes it, so both count; `unpacked` (a
  rolled-back continuation) and `tmp_current` (written before the reboot) do
  not. And its boot has finished, which is `:init.get_status/0`'s *provided*
  status being `:started`. Do not gate on the internal status: it stays
  `:starting` for the life of a release started by its boot script, so a booted
  node reports `{:starting, :started}`. The provided status is what the script's
  `{progress, _}` instructions move along, and `started` is its last one — after
  the applications have started, and after `new_emulator_upgrade/2` in the
  hybrid script that continues an emulator upgrade. Without that second
  condition a poll can confirm a node that is still booting, and automation
  that commits straight after installing would make a version that cannot boot
  the permanent one.

  The marker is the whole of the evidence, so it inherits whatever the selected
  boot script does with it. `RELEASE_BOOT_SCRIPT` naming a hand-written script
  that never reaches `{progress, started}` will never be confirmed — `install`
  waits and then fails, and the refusal names the progress the node did reach,
  so it is diagnosable and never a false success — and one that emits the marker
  before its applications start defeats the check. Both are documented rather
  than validated: Mix generates the boot scripts and offers no `rel/` template
  for them, so reaching either state takes deliberate work. (An earlier note
  here claimed `systools_make:add_apply_upgrade/2`'s hard match on the trailing
  marker ruled this out. It does not: that builds the hybrid script for an
  emulator upgrade and says nothing about a script an operator supplies.)

Every one of them is a command entry point, so `Castle` is the command
boundary: an operation that fails raises `Castle.Error` there, which is what
leaves a non-zero exit status behind for the shell that asked for it. Raising,
not halting — the expression runs on the *running* node, so halting would take
down the system under management; `Kernel.CLI` catches on the node and
re-raises in the calling VM, and only that VM exits. `Castle.Commands` holds
the operations themselves, returning their outcome instead of acting on the
process, which is what makes them testable.

Forecastle is what arranges for these to be reachable: it renames `sys.config`
to `build.config` at assembly time, adds a `:preboot` script that starts
`:castle`, and writes the `env.sh` fragment and `bin/castle` wrapper that call
into this module.

## Layout

| Path | Purpose |
| --- | --- |
| `lib/castle.ex` | The command boundary: print the outcome, or raise |
| `lib/castle/commands.ex` | The commands themselves, returning their outcome |
| `lib/castle/error.ex` | The exception a failed command raises |
| `test/support/` | Stubs for `:release_handler`, `:init` and a config provider |

## Working on this project

- Run `mix precommit` before committing. It is the single validation gate —
  `compile --warnings-as-errors`, `deps.unlock --unused`, `format`,
  `credo --strict`, `test`. Do not run the individual checks piecemeal.
- `@version` in `mix.exs` is the single source of truth for the version.
- Add user-visible changes to `RELEASE.md` on the feature branch, using
  [Keep a Changelog](https://keepachangelog.com/) sections. Do not defer release
  notes to release time, and exclude internal CI/lint churn.
- Release with `mix publisho <patch|minor|major>`, which bumps `@version`, folds
  `RELEASE.md` into `CHANGELOG.md` at the `<!-- %% CHANGELOG_ENTRIES %% -->`
  placeholder, commits and tags. Tags are bare semver — no `v` prefix. Pushing
  a tag triggers `.github/workflows/publish.yml`, which publishes to Hex.
- Never commit directly to `main`; work on a feature branch and open a PR.

## Tests

`mix test` covers `Castle.Commands` as units. `:release_handler` and `:init` are
reached through module arguments that default to them, so the tests hand them
`Castle.ReleaseHandlerStub` and `Castle.InitStub` instead; `generate/1` takes
the version directory it writes to, so the tests give it a `tmp_dir` holding a
synthetic `build.config`. `test/castle_test.exs` drives the boundary itself
against the real `:release_handler` — which is running under `mix test`, because
castle depends on sasl — and the real `:init`, naming releases that do not
exist.

What is *not* covered here is a booted release: the upgrade of a running
system, and the exit statuses `bin/castle` returns, belong to Forecastle's
`:e2e` suite ([#8](https://github.com/ausimian/castle/issues/8)), which
exercises this code against a real release and asserts on the success messages
each command prints. Those strings — `Unpacked <vsn> ok`,
`Now running <vsn> (previously <other>).`, `Committed <vsn>. …` and the
`releases/0` table — are a contract with that suite. Failure messages are not.

## Known limitations

- **Concurrent boots race on `sys.config`.** `generate/1` writes into the
  version directory, so simultaneous `start`/`daemon`/`eval` invocations with
  differing environments overwrite each other's configuration. Do not fix this
  by letting callers choose where the configuration is written: it goes away
  with [#13](https://github.com/ausimian/castle/issues/13), which materialises
  the target release's configuration in a `:peer` running its own config
  providers, and takes `Castle.generate/1` with it.
- **The public API is undocumented.** `@moduledoc` is still the generated
  placeholder and there are no `@doc` or `@spec` annotations
  ([#11](https://github.com/ausimian/castle/issues/11)).
- **The README is out of date.** It documents an `:appup` compiler and a
  `mix castle.relup` task that moved to Forecastle in 0.3.0, and the release
  management commands it describes on `bin/<release>` now live on `bin/castle`
  ([#9](https://github.com/ausimian/castle/issues/9)).
