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
  runs. It is now the older of two ways to do that — see the next bullet — and
  goes away with the third step of
  [#13](https://github.com/ausimian/castle/issues/13).
- **Materialising the target's configuration**, which `install/1` and `commit/1`
  do before they hand a version to `:release_handler`. Which way depends on
  whether `releases/<vsn>/build.config` exists, and that is a sound
  discriminator because it is Forecastle that creates it: assembling a release
  today strips the providers out, stashes their initialised state under
  `:castle`, and renames the `sys.config` Mix wrote to `build.config`. So the
  file is present exactly when the configuration was intercepted at build time,
  and `Castle.generate/1` is then the only thing that can expand it. Note that
  it has to be the *presence of `build.config`* rather than the absence of
  `sys.config`: once such a release has booted once, it has both.

  When it is absent, Mix's pipeline is intact and `Castle.Peer` materialises the
  configuration instead: a `:peer` reached over a loopback socket — so no epmd,
  cookie, node name or distribution; the peer reports `nonode@nohost` and
  `is_alive() == false` — booted on the target's own `preboot` script and its
  own emulator, which runs `Config.Provider.boot/1` over the target's own
  provider modules and hands the resolved configuration back to be written.
  Castle does not fold providers itself, and must not acquire the ability to:
  the point of #13 is that Elixir's pipeline stays the only implementation of
  it. What Castle arranges is that the pipeline *writes* rather than configuring
  the VM it happens to be in, which is one field of the provider state and a
  reboot function that does nothing.

  A provider module can differ between the version that is running and the
  version being installed, which is why this cannot be done on the running
  node, and is what the peer earns.

  Six things about it are load-bearing.

  Every evaluation starts from the configuration Mix wrote, and never from the
  result of the last one. Providers are not obliged to be idempotent and the
  ones people write are not — `if System.get_env("FEATURE"), do: config …` in a
  `runtime.exs` sets a key on a run where the variable is set and says nothing
  about it on a run where it is not — so resolving over the previous result
  would leave that key behind, and the version an operator commits would be
  configured differently from the way it boots. `sys.config` cannot be the base,
  because that is the file `:release_handler` reads and so the file the resolved
  result has to land in; the first materialisation therefore copies it to
  `sys.config.pristine`, with an exclusive create so two racing installs cannot
  capture anything but the original, and every later one seeds from there. This
  is permanent design: the `build.config` path has always had a pristine base —
  `build.config` *is* one — and this is what carries that property forward when
  step 3 deletes it. It is deliberately not called `build.config`, since that
  name is the discriminator and would send the release back down the path being
  removed. `sys.config` gains a `CASTLE_MATERIALISED` comment line, which makes
  the invariant checkable: written by Castle, so a base must exist. A version
  that says that and has no base beside it is refused, with the remedy (unpack
  it again) named, rather than having a once-resolved configuration captured as
  though it were the original.

  With a pristine base, materialising at `commit` is not merely harmless but
  right: it produces what a boot at commit time would produce, which is the
  point of doing it there.

  The peer is started linked and stopped on every path out, including the
  failing ones; `wait_boot` and the call both have deadlines, so a peer that
  never answers cannot hold an install open. Everything that can refuse — a
  missing boot script, an emulator that is not there, a provider that raises, a
  compile environment that does not agree — refuses before `install_release/1`
  is called. The resolved configuration is assembled in a copy beside
  `sys.config` and renamed onto it, so a version never holds half a
  configuration.

  The control connection is a socket rather than `connection: :standard_io`,
  which is what the issue suggested. Standard IO multiplexes the peer's console
  output with the frames carrying the call over one byte stream and reserves
  sixteen byte values for the framing, every one of them a UTF-8 lead byte — so
  a provider, or a NIF under it, writing an accented character straight to a
  file descriptor fails the frame's checksum and takes the control process down,
  refusing an install that was about to succeed. Nothing outside `:peer` can
  harden that; the shared stream *is* the mechanism. The socket costs the
  diagnosis of a peer that cannot boot: a detached peer says nothing on its way
  down and the origin holds no handle on it, so a failed boot is noticed when
  the deadline expires rather than at once and with the emulator's reason. That
  was the trade, and it went the way it did because a broken release is broken
  either way while a working one must not be refused.

  Because a detached peer's descriptors are the null device, its standard error
  is relayed through its `user` process — which is what makes Elixir's account
  of a provider that raised reach the operator at all. A raw write still goes
  nowhere, which is the safe direction.

  `Castle.Peer.resolve/1` is called *in the target release*, so
  `{Castle.Peer, :resolve, 1}` is a contract between one version of Castle and
  the next. A target too old to have it fails the call and the install is
  refused.

  Finally, `Castle.Peer` makes the compile-environment check Elixir would have
  made, with Elixir's own validator. Elixir makes it in the branch that
  *applies* a resolved configuration, and again on the boot that follows the
  branch that *writes* one; this drives the writing branch and nothing boots
  afterwards, so without it a release Elixir considers unbootable would be
  installed and the problem found on the way up, where the only way out is a
  rollback. Do not weaken it into something that skips when it does not
  recognise what it was given: it refuses instead, because a check that silently
  passes everything looks exactly like a check that works.

- **`Castle.make_releases/0`** — creates the `RELEASES` file from the running
  permanent release if it does not already exist, so a release assembled by Mix
  can manage its own upgrades.
- **`unpack/1`, `install/1`, `commit/1`, `remove/1`, `releases/0`** — wrappers
  over `:release_handler`, with the target version's configuration materialised
  ahead of `install` and `commit` so that it exists before the version is
  booted.
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
| `lib/castle/peer.ex` | The temporary VM that runs the target's own config providers, both sides of it |
| `lib/castle/error.ex` | The exception a failed command raises |
| `test/support/` | Stubs for `:release_handler`, `:init`, the peer and config providers, plus the release-shaped tree a real peer is booted on |

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

`mix test` covers `Castle.Commands` as units. `:release_handler`, `:init` and
`Castle.Peer` are reached through module arguments that default to them, so the
tests hand them `Castle.ReleaseHandlerStub`, `Castle.InitStub` and
`Castle.PeerStub` instead; `generate/1` and `materialise/2` take the version
directory they work on, so the tests give them a `tmp_dir`.
`test/castle_test.exs` drives the boundary itself against the real
`:release_handler` — which is running under `mix test`, because castle depends
on sasl — and the real `:init`, naming releases that do not exist.

`test/castle/peer_test.exs` is the exception: it starts real peers. Stubbing the
peer would prove nothing about the one thing it exists to do, which is to run a
release's *own* code. `Castle.SyntheticRelease` lays out a directory tree with
everything `Castle.Peer` needs — an emulator launcher under `erts-<vsn>/bin`,
applications under `lib/<app>-<vsn>`, a `systools` boot script over them, a
release file and a `sys.config` — so a peer boots on the same kind of script a
release ships, without a `mix release`. The test that matters most compiles two
versions of one provider module, loads one into the node running the tests and
puts the other on the peer's code path, and asserts that the answer came from
the peer's. Peer cleanup is asserted from outside: a provider records the
operating system pid of the VM it ran in, and the test waits for it to go.

`Castle.Peer.materialise/2` takes `:boot_timeout` and `:resolve_timeout` for the
same reason `Castle.Commands` takes the module to talk to — a deadline nothing
can shorten is a deadline no test can show is enforced. Two tests give it a
second and assert that the refusal names it, which is what keeps the deadlines
from being a claim in a comment.

Idempotence is asserted against a control rather than against a hard-coded
expectation: two versions of the same release are built in one root, sharing a
`runtime.exs` so that the state the providers carry is identical, one is
materialised twice with the environment changing in between — install, then
commit — and the other once with the environment as it ended up. The two
`sys.config` terms have to be equal. That is why `Castle.SyntheticRelease` makes
its symlinks idempotently: a root has to be able to hold two versions.

Two of these tests would pass for the wrong reason if written carelessly, so
they are written to fail when what they rest on moves. The compile-environment
test asserts the *refusal*, over provider state built by
`Config.Provider.init/3`: if Elixir stops representing that check as a list of
triples, `init/3` stops producing one, no refusal happens, and the test fails.
It is paired with a release whose check is satisfied, so that "refuses
everything" cannot pass for "checks correctly", and with one carrying a shape
Elixir does not produce, which has to be refused rather than skipped.

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
  by letting callers choose where the configuration is written: it goes with
  `generate/1` itself, once
  [forecastle#6](https://github.com/ausimian/forecastle/issues/6) has stopped
  intercepting configuration at build time and the third step of
  [#13](https://github.com/ausimian/castle/issues/13) has deleted the path that
  reads `build.config`. The peer path does not have it — nothing boots to
  configure a target — but a boot still goes through `generate/1` until then.
- **How the materialised `sys.config` and a later cold boot of the same version
  interact is not verified yet.** Both write the same file. Materialisation
  resolves from `sys.config.pristine` and leaves no `config_provider_booted`
  marker behind, so a cold boot re-runs the providers over the materialised
  result — which is what the issue expects, and what the header Mix wrote is
  preserved for. It only becomes reachable with
  [forecastle#6](https://github.com/ausimian/forecastle/issues/6), and belongs
  there.
- **The public API is undocumented.** `@moduledoc` is still the generated
  placeholder and there are no `@doc` or `@spec` annotations
  ([#11](https://github.com/ausimian/castle/issues/11)).
- **The README is out of date.** It documents an `:appup` compiler and a
  `mix castle.relup` task that moved to Forecastle in 0.3.0, and the release
  management commands it describes on `bin/<release>` now live on `bin/castle`
  ([#9](https://github.com/ausimian/castle/issues/9)).
