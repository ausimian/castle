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
preserved; Castle warns if it has no `:tar` step.

You can also provide `rel/env.sh.eex`. Forecastle keeps its contents and appends
the launcher setup Castle needs.

## Appups and relups

Write an appup for each application whose code changes during a hot upgrade.
The appup file uses Erlang terms written in Elixir syntax:

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

Generate a relup between assembled releases:

```shell
mix forecastle.relup \
  --target _build/prod/rel/my_app/releases/1.1.0/my_app \
  --fromto _build/prod/rel/my_app/releases/1.0.0/my_app
```

The task writes `relup` to the project root by default. Leave it there for the
next release build to package. Use `--hot` to require a hot transition or
`--restart` to force a one-stage emulator restart.

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
