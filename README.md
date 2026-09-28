# Castle

Castle adds hot-code upgrades to Elixir releases. It manages releases on the
running node and resolves the target release's runtime configuration before OTP
installs it.

[Forecastle](https://hexdocs.pm/forecastle) performs the build-time work. Castle
includes it as a build-time dependency.

## Requirements

- Elixir 1.18 or later.
- A Unix release that includes ERTS. Castle refuses releases built with
  `include_erts: false`.
- An external supervisor such as systemd, Docker, Kubernetes or runit for
  upgrades that restart the emulator.

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

An application that uses only Forecastle's appup compiler can exclude Castle
from its runtime release:

```elixir
def deps do
  [
    {:castle, "~> 1.0", runtime: false}
  ]
end
```

## Project setup

Point the project at its appup source and add the appup compiler:

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

The function wrapper delays evaluation until Castle has been compiled.

`Castle.customize/1` adds Forecastle's steps around `:assemble`. It uses
`[:assemble, :tar]` when `:steps` is absent, preserves explicit step lists, and
warns when an explicit list has no `:tar`. Other release options pass through
unchanged.

A custom `rel/env.sh.eex` is optional. Forecastle preserves it and appends
Castle's launcher setup.

## Appups and relups

Write an appup for each owned application that must be upgraded in place. The
file contains Erlang terms written in Elixir syntax:

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

### Generate a relup during assembly

Set `upgrade_from:` to the releases this version supports:

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

Forecastle generates both upgrade and downgrade instructions for each baseline.
It writes the relup immediately before `:tar`, after any custom steps between
`:assemble` and `:tar`, so one `mix release` produces a tarball containing its
upgrade plan.

If a custom step packages the release without `:tar`, place
`&Forecastle.generate_relup/1` immediately before that step. Generate the relup
after every step that changes the release. Split a step that both changes and
packages it. A custom step after `:tar` must not change or repackage the release.

Baseline specs use one of these sources:

| Spec | Baseline |
| --- | --- |
| `tar:artifacts/my_app-1.0.0.tar.gz` | A shipped release tarball |
| `rel:_build/prod/rel/my_app/releases/1.0.0/my_app` | An assembled release |
| `ref:1.0.0` | A git ref built in a worktree |

A path without a prefix is a `rel:` path. Prefer `tar:` when the shipped
artifact is available; a release rebuilt from source may differ from the one
that was deployed.

Resolved `tar:` and `ref:` baselines are cached under
`_build/castle/baselines`. Cache this directory in CI. A `tar:` entry is keyed
by the artifact digest. A `ref:` entry is keyed by the commit, Mix environment
and target, and the Elixir and ERTS versions.

List several baselines to support several source versions:

```elixir
upgrade_from: [
  "tar:artifacts/my_app-1.0.0.tar.gz",
  "tar:artifacts/my_app-1.0.1.tar.gz"
]
```

Forecastle validates `upgrade_from:` before assembly. Define or compute it in
the release definition, or in a step before `:assemble`. A project-root `relup`
cannot be combined with `upgrade_from:`.

### Generate a relup for an existing target

`mix castle.relup` generates a relup for an assembled target:

```shell
mix castle.relup \
  --target _build/prod/rel/my_app/releases/1.1.0/my_app \
  --fromto _build/prod/rel/my_app/releases/1.0.0/my_app
```

`--target` is the target `.rel` path without its extension. `--fromto`,
`--upfrom` and `--downto` accept the same baseline specs as `upgrade_from:`.
The task writes `relup` to the project root by default, where the next release
build packages it.

Use this task when the target already exists, when upgrade and downgrade need
different baselines, or when selecting `--hot` or `--restart` explicitly.
`upgrade_from:` always generates both directions with the default `auto`
strategy.

Forecastle also supplies:

- `mix castle.appup`, which checks whether an appup covers the modules that
  changed between two builds.
- `mix castle.appup.gen`, which drafts missing appup entries for review. With
  `--app <dep>`, it writes a dependency appup under `rel/appups`.
- `mix castle.relup --dry-run`, which checks whether relup generation would
  succeed without writing the relup.

See `mix help` for each task's options.

## Managing releases

Build the new release and copy `<name>-<vsn>.tar.gz` into the running
deployment's `releases` directory. Then use `bin/castle`:

```shell
# Show known releases and their status.
my_app/bin/castle releases

# Check whether the node can be upgraded. Success prints nothing.
my_app/bin/castle upgradable

# Stage, install and make version 1.1.0 permanent.
my_app/bin/castle unpack 1.1.0
my_app/bin/castle install 1.1.0
my_app/bin/castle commit

# Remove an unused version.
my_app/bin/castle remove 1.0.0
```

Release statuses are:

- `permanent`: used on the next ordinary restart.
- `current`: running but not committed.
- `old`: superseded and eligible for removal.
- `unpacked`: staged, failed or rolled back.

`install` resolves the target's config providers in a temporary VM running the
target code, then asks OTP to install it. The version remains provisional until
`commit` makes it permanent. A restart before commit normally returns to the
previous permanent version.

For a relup containing `restart_emulator`, `install` waits across the restart
until the target has finished booting. The external supervisor must restart the
process. Castle does not support the two-stage `restart_new_emulator`
transition.

## Testing an upgrade

An assembled release may still fail during an upgrade. Test the transition by
starting the old release, installing the new one, and checking both application
state and the code version serving requests.

`Forecastle.UpgradeCase` supplies a scratch directory for each test module.
`Forecastle.Deployment` deploys an artifact, starts and stops it, runs release
commands, and supports both hot and supervised restart installs.

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
    {:ok, deployment: deployment}
  end
end
```

Use `tar:` to test the artifact that was actually shipped. See Forecastle's
README and the module documentation for the full workflow.

## Limitations

- Windows launchers are not supported.
- `RELDIR` and the SASL `releases_dir` option are not supported. Castle and
  `:release_handler` must use the same release directory. See
  [issue #23](https://github.com/ausimian/castle/issues/23).
- Castle serialises installs within one Erlang node. Do not run Castle from a
  second VM against the same deployment.
