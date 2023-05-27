# Castle

Runtime support for hot-code upgrades.

`Castle` provides runtime support for hot-code upgrades. In particular, it generates a 
valid `sys.config` from `runtime.exs` and/or other [Config Providers](https://hexdocs.pm/elixir/main/Config.Provider.html)
prior to both boot and hot-code upgrade.

It relies on [Forecastle](https://hexdocs.pm/forecastle/readme.html) for build-time release generation
and brings it in as a build-time dependency.

## Installation

The package can be installed by adding `castle` to your list of dependencies in
`mix.exs`. For projects that don't define a release, but use the `appup` compiler,
it's sufficient to bring `Castle` in as a build-time dependency:

```elixir
def deps do
  [
    {:castle, "~> 0.3.0", runtime: false}
  ]
end
```

For projects that _do_ define one or more releases, `Castle` should be brought in
as a runtime dependency:

```elixir
def deps do
  [
    {:castle, "~> 0.3.0"}
  ]
end
```

`Castle` brings in `Forecastle` as a build-time dependency.

## Integration

Build-time integration is done via `Forecastle` and more details can be found in its
documentation but, in summary, it will integrate into your release process via the
release assembly process. In particular, it requires that that the `Forecastle.pre_assemble/1` 
and `Forecastle.post_assemble/1` functions are placed around the `:assemble` step, e.g.:

```elixir
defp releases do
  [
    myapp: [
      include_executables_for: [:unix],
      steps: [&Forecastle.pre_assemble/1, :assemble, &Forecastle.post_assemble/1, :tar]
    ]
  ]
end
```

## Release Management

The script in the `bin` folder supports some extra commands to manage upgrades.
Releases, in their tarred-gzipped form, should first be copied to the `releases`
subfolder on the target system. The following commands can be used to manage
them:

  - `releases` - Lists the releases on the system and their status. Status can
    be one of the following:
    - permanent - the release the system will boot into on next restart.
    - current - if it exists, represents the current running release. Will be
      different from the permanent version if a new release has been installed
      but not yet committed. If no version is listed as current, the permanent
      version is the currently running version.
    - old - if it exists, a previously installed version.
    - unpacked - an unpacked version, but not yet installed.
  - `unpack <vsn>` - Unpacks the release called `<name>-<vsn>.tar.gz`.
  - `install <vsn>` - Installs the new release. This makes the release the
    current one, but not yet the permanent one. Prior to running the relup,
    `Castle` generates the version specific `sys.config` for the new version.
  - `commit <vsn>` - Makes the specified release the one the permanent one.
  - `remove <vsn>` - Remove an old version from the filesystem. Any files
    shared with remaining releases are left untouched.

## The Appup Compiler

You are responsible for writing the [appup](https://www.erlang.org/doc/man/appup.html)
scripts for your application, but `Castle` will copy the appup into the `ebin` folder
for you. The steps are as follows:

1. Write a file, in _Elixir form_, describing the application upgrade. e.g.:
   ```elixir
   # You can call the file what you like, e.g. appup.ex, 
   # but you should # keep it away from the compiler paths.
   {
    '0.1.1',
     [
      {'0.1.0', [
        {:update, MyApp.Server, {:advanced, []}}
      ]}
     ],
     [
      {'0.1.0', [
        {:update, MyApp.Server, {:advanced, []}}
      ]}
     ]
   }
   ```
   This file will typically be checked in to SCM.
2. Add the appup file to the Mix project definition in mix.exs and add the
   `:appup` compiler.
   ```elixir
   # Mix.exs
   def project do
     [
       appup: "appup.ex", # Relative to the project root.
       compilers: Mix.compilers() ++ [:appup]
     ]
   end
   ```
   
## Relup Generation

Castle contains a mix task, `castle.relup`, that simplifies the generation of
the relup file. Assuming you have two _unpacked_ releases e.g. `0.1.0` and `0.1.1` 
and you wish to generate a relup between them:

```shell
> mix castle.relup --target myapp/releases/0.1.1/myapp --fromto myapp/releases/0.1.0/myapp
```

If the generated file is in the project root, it will be copied during 
post-assembly to the release.