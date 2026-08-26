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

The relup is written into the version being assembled, immediately before it is
packed, so a single `mix release` produces a tarball carrying its own upgrade
plan. Both directions are generated for every baseline, so each named version
can also be rolled back to.

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
out loud that the baseline was rebuilt. It also rebuilds that version on every
`mix release`, which takes as long as building it did; resolved baselines are
cached under `_build/castle/baselines`, keyed by content or commit, so CI can
cache that directory.

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

### Generating the relup by hand

`mix castle.relup` generates a relup between two releases that already exist,
with no rebuild:

```shell
mix castle.relup \
  --target _build/prod/rel/my_app/releases/1.1.0/my_app \
  --fromto _build/prod/rel/my_app/releases/1.0.0/my_app
```

It writes `relup` to the project root, where the next release build packages it.
That means two builds: one to assemble the target the task reads, and one more
to package the relup it wrote. `upgrade_from:` exists to remove that. What the
task still covers is a plan for two artefacts that already exist, and the
strategy switches — `--hot` to require a hot transition, `--restart` to force a
one-stage emulator restart — neither of which `upgrade_from:` can ask for, since
it always generates with the default `auto` strategy.

A project-root `relup` and `upgrade_from:` together are refused rather than
ordered by precedence. They are two upgrade plans for one release and only one
of them can be packaged, so choosing silently would discard the other invisibly.

`mix castle.relup` is implemented in Forecastle, which Castle brings in as a
build-time dependency. It is named for Castle because that is the package a
project depends on, and nothing has to be added to `deps` to get it.

The appup compiler comes from Forecastle the same way, but is named for what it
does rather than for either package: it stays `mix compile.appup`, reached
through the `:compilers` list above. There is no `mix castle.appup`.

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

## Limitations

- Windows launchers are not supported.
- `RELDIR` and the SASL `releases_dir` option are not supported yet. Castle and
  `:release_handler` must use the same release directory. See
  [issue #23](https://github.com/ausimian/castle/issues/23).
- Castle serialises installs within one Erlang node. Do not run Castle from a
  second VM against the same deployment.
