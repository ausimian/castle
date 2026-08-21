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

Forecastle is what arranges for these to be reachable: it renames `sys.config`
to `build.config` at assembly time, adds a `:preboot` script that starts
`:castle`, and writes the `env.sh` fragment and `bin/castle` wrapper that call
into this module.

## Layout

| Path | Purpose |
| --- | --- |
| `lib/castle.ex` | The whole of the runtime logic |

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

There is no test coverage yet. `test/castle_test.exs` is a `doctest` stub.

Every function here talks to `:release_handler` against a real installed
release, and `generate/1` resolves paths from `:code.root_dir()`, so none of it
is reachable from a plain `mix test`. Testing it needs a release fixture booted
in a workspace, the way Forecastle's `:e2e` suite does — tracked in
[#8](https://github.com/ausimian/castle/issues/8). Forecastle's
`test/forecastle/upgrade_test.exs` exercises this code end to end in the
meantime.

## Known limitations

- **Failed operations exit 0.** Every command catches the `:release_handler`
  error, prints it and returns normally, so `bin/castle` cannot tell a failed
  unpack/install/commit/remove from a successful one. Tracked in
  [#10](https://github.com/ausimian/castle/issues/10), together with letting
  `generate/1` take a caller-chosen destination path
  ([#15](https://github.com/ausimian/castle/issues/15)).
- **Concurrent boots race on `sys.config`.** `generate/1` writes into the
  version directory, so simultaneous `start`/`daemon`/`eval` invocations with
  differing environments overwrite each other's configuration. Same issue.
- **The public API is undocumented.** `@moduledoc` is still the generated
  placeholder and there are no `@doc` or `@spec` annotations
  ([#11](https://github.com/ausimian/castle/issues/11)).
- **The README is out of date.** It documents an `:appup` compiler and a
  `mix castle.relup` task that moved to Forecastle in 0.3.0, and the release
  management commands it describes on `bin/<release>` now live on `bin/castle`
  ([#9](https://github.com/ausimian/castle/issues/9)).
