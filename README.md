# Castle

Castle adds hot-code upgrade support to Elixir releases. It manages upgrades on
the running node and resolves the target release's runtime configuration before
OTP installs it.

[Forecastle](https://hexdocs.pm/forecastle) handles the build-time work. Castle
includes it as a build-time dependency.

## Requirements

- Elixir 1.18 or later.
- A Unix release built with its own ERTS. Castle refuses releases built with
  `include_erts: false`.
- An external supervisor such as systemd, Docker, Kubernetes or runit if an
  upgrade restarts the emulator.

Use Castle and Forecastle from the same release series. Castle 1.x expects the
release layout produced by Forecastle 1.x.

## Installation

Add Castle to applications that build a release:

```elixir
def deps do
  [
    {:castle, "~> 1.0"}
  ]
end
```

An application that only uses Forecastle's appup compiler can keep Castle out
of its runtime release:

```elixir
def deps do
  [
    {:castle, "~> 1.0", runtime: false}
  ]
end
```

## Project setup

Point the project at its appup file and add the appup compiler:

```elixir
def project do
  [
    appup: "appup.exs",
    compilers: Mix.compilers() ++ [:appup]
  ]
end
```

Define each release lazily and pass its options to `Castle.customize/1`:

```elixir
defp releases do
  [
    my_app: fn ->
      [include_executables_for: [:unix]]
      |> Castle.customize()
    end
  ]
end
```

The function wrapper is required. Mix loads `mix.exs` before dependencies have
been compiled during commands such as `mix deps.get`. It evaluates the release
function later, when Castle is available.

`Castle.customize/1` adds Forecastle's assembly steps around `:assemble`. When
`:steps` is omitted, it uses `[:assemble, :tar]`. An explicit steps list is
preserved; Castle warns if it has no `:tar` step. It changes that one option and
passes every other release option through, `upgrade_from:` included — see
[Appups and relups](#appups-and-relups).

You can also provide `rel/env.sh.eex`. Forecastle keeps its contents and appends
the launcher setup Castle needs.

## Appups and relups

Write an appup for each application you own that has to be upgraded in place.
Whether a given transition needs one depends on the strategy below and on which
applications changed; `mix castle.relup` documents the rules. The appup file
uses Erlang terms written in Elixir syntax:

```elixir
{
  ~c"1.1.0",
  [
    {~c"1.0.0", [{:update, MyApp.Server, {:advanced, []}}]}
  ],
  [
    {~c"1.0.0", [{:update, MyApp.Server, {:advanced, []}}]}
  ]
}
```

### Generating the relup during the build

Name the releases this one can be upgraded from, and the build generates the
relup:

```elixir
defp releases do
  [
    my_app: fn ->
      [
        include_executables_for: [:unix],
        upgrade_from: ["tar:artifacts/my_app-1.0.0.tar.gz"]
      ]
      |> Castle.customize()
    end
  ]
end
```

The relup is written into the version being assembled by a step placed
immediately before `:tar`, so the default `[:assemble, :tar]` produces a tarball
carrying its own upgrade plan from a single `mix release`. Both directions are
generated for every baseline, so each named version can also be rolled back to.

**One rule governs where the relup step goes**, and the default `:steps` satisfy
it without your doing anything: the relup must be generated **after every step
that changes the release, and immediately before the one that packs what you
ship.** With `[:assemble, :tar]` that is exactly where Forecastle puts it.

Two ways to get it wrong, both of which build green:

- **No `:tar`, and a step of your own packs the archive.** With no `:tar` to
  precede, the relup step is appended last — after everything in the list — so
  your archive is packed before the relup exists and ships without one. Place
  `&Forecastle.generate_relup/1` in `:steps` yourself, before the packing step.
  If one step both shapes the tree and packs it, split it in two and put the
  generation between them: generated too early, the relup describes the tree as
  it *was* while the archive holds the tree as it became — an upgrade plan for
  code the release is not carrying.
- **A function step after `:tar`.** Mix allows one, and Forecastle generates the
  relup before `:tar`, so such a step runs after generation. If it changes the
  release, or packs an artefact of its own, that artefact is outside the plan
  the relup describes. Adding `:tar` puts the relup in the archive `:tar`
  builds; it says nothing about one packed afterwards.

`Castle.customize/1` warns about a missing `:tar` and says all of this, but it
cannot see which of your steps packs or which of them mutates, so the placement
is yours to get right — and it cannot warn at all about the second case, since a
list containing `:tar` looks correct to it.

Note also that a `&Forecastle.generate_relup/1` you placed yourself is honoured
rather than joined by a second one, so placing it is how you take the ordering
into your own hands. Placed *after* `:tar` it is refused at the build instead,
because the archive would be packed before generation had written anything into
it and the build would still announce the upgrade plan it generated.

Each baseline is named by a spec, and there are three sources:

| Spec | Baseline |
| --- | --- |
| `tar:artifacts/my_app-1.0.0.tar.gz` | a release tarball that was shipped |
| `rel:_build/prod/rel/my_app/releases/1.0.0/my_app` | an assembled release |
| `ref:1.0.0` | a git ref, built in a worktree |

A value with no prefix is a `rel:` path.

**Prefer `tar:` wherever the artefact that actually shipped still exists.**
`:release_handler` selects a relup entry by from-version string and never checks
that the running code is what the relup was generated against. A baseline
rebuilt from source today is built with today's Erlang, Elixir and dependencies,
so if the module set differs at all from what is deployed, the relup's
instructions miss modules — and the upgrade loads some of the new code over a
system still running the rest of the old. `ref:` is the right answer for
development and for the common case where nobody kept the artefact, and it says
out loud that the baseline was rebuilt.

Resolved baselines are cached under `_build/castle/baselines` — `tar:` keyed by
a digest of the artefact, `ref:` by the resolved commit and the build context
(`MIX_ENV`, `MIX_TARGET`, the Elixir and ERTS versions). A `ref:` baseline is
built on a cache miss, not on every `mix release`; the first build of a given
commit takes as long as building that version did, and later ones are a cache
hit. Cache that directory in CI and the cost is paid once.

Name several baselines to support upgrades from several versions:

```elixir
upgrade_from: [
  "tar:artifacts/my_app-1.0.0.tar.gz",
  "tar:artifacts/my_app-1.0.1.tar.gz"
]
```

The release definition is a `fn -> ... end`, so the list can be computed rather
than written out — read from the environment, or globbed from a directory of
artefacts.

**Castle checks none of this.** `upgrade_from:` is a release option that
`Castle.customize/1` passes through untouched, and Forecastle owns both the
grammar and the refusals. It refuses an empty list, a value that is not a list
of strings, a spec whose prefix names no source, and the option given more than
once — which a definition assembled by joining lists really can produce, and
which is refused rather than resolved by precedence. Leaving the option out is
the one quiet case, and deliberately so: a release that says nothing about
upgrading is assembled exactly as it was before this existed.

**And it refuses an `upgrade_from:` that changed after assembly began.** The
option is resolved once, by the step Castle splices in before `:assemble`, and a
release step of your own that sets or changes it afterwards is refused rather
than half-honoured — because the relup is generated into the version directory
just before `:tar` packs it, so a baseline named after that point produces an
archive with no upgrade plan in it, and nothing would otherwise say so. Compute
the list in the release definition itself, as above, or in a step you place
before `:assemble`; both run early enough to be resolved normally.

### Generating the relup by hand

`mix castle.relup` generates a relup for a target that is already assembled:

```shell
mix castle.relup \
  --target _build/prod/rel/my_app/releases/1.1.0/my_app \
  --fromto _build/prod/rel/my_app/releases/1.0.0/my_app
```

`--target` is a `.rel` path with the extension removed, so the release it names
has to exist. `--fromto`, `--upfrom` and `--downto` take the same baseline specs
as `upgrade_from:` — all three sources, `ref:` included — so this route is not a
rebuild-free one: a `ref:` baseline is built here exactly as it would be during
assembly, through the same cache.

It writes `relup` to the project root, where the next release build packages it.
That means two builds: one to assemble the target the task reads, and one more
to package the relup it wrote. `upgrade_from:` exists to remove that. What the
task still covers is a target that has already been built — so a plan can be
made for an artefact without rebuilding it — separate up and down baselines, and
the strategy switches: `--hot` to require a hot transition, `--restart` to force
a one-stage emulator restart. `upgrade_from:` can ask for none of those; it
generates both directions for every baseline with the default `auto` strategy.

A project-root `relup` and `upgrade_from:` together are refused rather than
ordered by precedence. They are two upgrade plans for one release and only one
of them can be packaged, so choosing silently would discard the other invisibly.

`mix castle.relup` is implemented in Forecastle, which Castle brings in as a
build-time dependency. It is named for Castle because that is the package a
project depends on, and nothing has to be added to `deps` to get it.

The appup compiler comes from Forecastle the same way, but is named for what it
does rather than for either package: it stays `mix compile.appup`, reached
through the `:compilers` list above.

Two more tasks come from Forecastle under the same naming rule. `mix castle.appup`
reports how an appup covers the modules that actually changed between two builds
— a module whose code moved and that no instruction mentions is the failure this
whole area exists to prevent, and it is a release-pipeline gate rather than
something `mix precommit` can run, because it needs a baseline. `mix
castle.appup.gen` drafts the entries it found missing, writing source you review
and commit; `--app <dep>` drafts one for a dependency you do not own, into
`rel/appups/<dep>-<from>-<to>.exs`. Both are documented by their own
`mix help`, which is the authority on their switches.

## Managing releases

Build the new release, then copy `<name>-<vsn>.tar.gz` into the running
deployment's `releases` directory. Manage it with `bin/castle`:

```shell
# Show known releases and their status.
my_app/bin/castle releases

# Check whether this node can be upgraded. Success prints nothing.
my_app/bin/castle upgradable

# Stage, install and make version 1.1.0 permanent.
my_app/bin/castle unpack 1.1.0
my_app/bin/castle install 1.1.0
my_app/bin/castle commit

# Remove a version that is no longer needed.
my_app/bin/castle remove 1.0.0
```

Release statuses are:

- `permanent`: the version used on the next ordinary restart.
- `current`: the running version, installed but not committed.
- `old`: a superseded version that can be removed.
- `unpacked`: a staged version, or one returned to that state after a failed or
  rolled-back install.

`install` resolves the target version's config providers in a temporary VM
running that version's code. It then asks OTP to install the release. The
version remains provisional until `commit` writes it as permanent. If a
provisional hot upgrade fails or the service restarts, the previous permanent
version boots again.

For a relup containing `restart_emulator`, `install` waits across the restart
until the target version has finished booting. The external supervisor must
restart the process. Castle does not support OTP's two-stage
`restart_new_emulator` transition.

## Testing an upgrade

A release that assembles is a release that builds. Whether it can be *upgraded*
is a different question, and the only thing that answers it is starting one
version, installing the next and looking at what survived.

`Forecastle.UpgradeCase` and `Forecastle.Deployment` are the half of that you do
not have to write: an `ExUnit.CaseTemplate` and a deployment driver that assemble
nothing new, but deploy an artefact, start it, install the next version and let
you assert whatever "it worked" means for your project.

```elixir
defmodule MyApp.UpgradeTest do
  use Forecastle.UpgradeCase

  @moduletag :upgrade

  setup_all %{scratch: scratch} do
    deployment =
      Forecastle.Deployment.deploy!(
        "tar:artifacts/myapp-1.0.0.tar.gz",
        Path.join(scratch, "deploy")
      )

    on_exit(fn -> Forecastle.Deployment.stop(deployment) end)
    # start it, put state in it, stage and install the next version, assert
  end
end
```

The baseline is named with the same spec grammar as `upgrade_from:`, so `tar:`
points the test at the artefact that actually shipped rather than at a rebuild
of it. Forecastle's own README documents the whole recipe, including the part
that catches people out: a hot upgrade and a `restart_emulator` transition are
installed by different calls, because one never leaves its operating system
process and the other needs a supervisor to bring it back.

**These are named for Forecastle rather than Castle, unlike the tasks above, and
that is deliberate.** A task name is a string you type, so it follows the package
you depend on; a module name is something you read once in a `use` line, and
`Castle` is a namespace Castle itself ships modules in — `Castle.Deployment`
already exists and means something else entirely. Two packages writing into one
namespace is decided by whichever `ebin` comes first on the code path, which is
not a thing to arrange on purpose.

**There is deliberately no `mix castle.upgrade.test`.** A task would have to
hardcode what a successful upgrade means, and only your project knows: for one
it is a counter that kept counting, for another a socket still open or a job
still in flight. A case template composes with tags, with CI and with your own
assertions instead.

Nothing here reaches a release. Castle takes Forecastle as a build-time
dependency, so the harness is present where `mix test` runs and absent from what
you ship.

## Limitations

- Windows launchers are not supported.
- `RELDIR` and the SASL `releases_dir` option are not supported yet. Castle and
  `:release_handler` must use the same release directory. See
  [issue #23](https://github.com/ausimian/castle/issues/23).
- Castle serialises installs within one Erlang node. Do not run Castle from a
  second VM against the same deployment.
