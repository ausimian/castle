# Castle

Hot-code upgrade support for Elixir Releases.

`Castle` provides build and runtime support for the generation of releases that correctly support hot-code upgrades. This includes:

  - Generation of runtime configuration into 
    [sys.config](https://www.erlang.org/doc/man/config.html#sys.config) prior to
    system boot.
  - Creation of the [RELEASES](https://www.erlang.org/doc/man/release_handler.html#description)
    file on first boot.
  - Support for [appup](https://www.erlang.org/doc/man/appup.html) and 
    [relup](https://www.erlang.org/doc/man/relup.html) files.
  - Shell-script support for managing upgrades.


## Installation

The package can be installed by adding `castle` to your list of dependencies in
`mix.exs`:

```elixir
def deps do
  [
    {:castle, "~> 0.1.0"}
  ]
end
```

## Integration

`Castle` integrates into the steps of the release assembly process. It requires
that the `Castle.pre_assemble/1` and `Castle.post_assemble/1` functions are
placed around the `:assemble` step, e.g.:

```elixir
defp releases do
  [
    myapp: [
      include_executables_for: [:unix],
      steps: [&Castle.pre_assemble/1, :assemble, &Castle.post_assemble/1, :tar]
    ]
  ]
end
```

## Build Time Support

The following steps shape the release at build-time:

### Pre-assembly

In the pre-assembly step:

  - The default evaluation of runtime configuration is disabled. `Castle` will
    do its own equivalent expansion into `sys.config` prior to system start.
  - A 'preboot' boot script is created that starts only `Castle` and its
    dependencies. This is used only during the aforementioned expansion.

The system is then assembled under the `:assemble` step as normal.

### Post-assembly

In the post-assembly step:

  - The `sys.config` generated from build-time configuration is copied to 
    `build.config`.
  - The shell-script in the `bin` folder is renamed from _name_ to _.name_, and
    a new script called _name_ is created in its place. This new script will
    ensure that the `sys.config` is correctly generated before the system is 
    started.
  - Any `runtime.exs` is copied into the version path of the release.
  - The generated _name.rel_ is copied into the `releases` folder as _name-vsn.rel_.
  - Any `relup` file is copied into the version path of the release.

## Runtime Support

At runtime, the script in the `bin` folder will intercept any calls to `start`,
`start_iex`, `daemon` and `daemon_iex` and bring up an ephemeral node to generate
`sys.config` by merging `build.config` with the results of evaluating `runtime.exs`.
Additionally, this ephemeral node will create the `RELEASES` file if it does not
already exist.

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