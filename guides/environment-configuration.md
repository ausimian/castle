# Configuring from environment variables

Many releases read their configuration from environment variables in
`config/runtime.exs`. A hot upgrade can change that configuration, but only
for variables Castle can see when it installs. This guide covers how to set a
release up so that a hot upgrade and a restart configure each version from the
same values, and how to change those values safely.

## How configuration reaches a running release

`bin/castle install` resolves the target version's configuration before it
installs it. Castle starts a temporary VM on the target's own code, runs the
target's config providers (`runtime.exs` among them), and writes the result to
the target's `releases/<vsn>/sys.config`. The relup then applies it, and OTP
calls `config_change/3` on each application whose environment changed.

The temporary VM inherits the running node's environment, which is the one
the node booted with. So a variable you change in your shell, or in a unit
file, does not reach the providers. Neither does a change to a file that only
the release's `env.sh` reads, because only a boot reads it.

`CASTLE_ENV_FILE` closes that gap. It names a file of variables that a boot, a
hot install and a commit all read, in the same way.

## One file per version

The file is an input to one version's configuration, so it lives in that
version's directory, beside its `env.sh` and `sys.config`:
`releases/<vsn>/castle.env`. Each version is configured from its own file.

- `install` and `commit` read the target's file.
- A restart reads the file of the version it boots. A rollback therefore
  configures the previous version from the file it was installed with, not from
  the new one.
- An install that is refused, or never committed, leaves the running version's
  file alone.
- `bin/castle remove` deletes the file with the rest of the version.

The file is not part of the release tarball, because it usually holds secrets
and a build artefact should not. Whatever deploys a version writes it.

## Setting it up

1. Set `CASTLE_ENV_FILE` to a relative name where the supervisor starts the
   release. It stays the same for every version. For systemd:

   ```ini
   [Service]
   Environment=CASTLE_ENV_FILE=castle.env
   ExecStart=/opt/my_app/bin/my_app start
   ```

   In a container spec, set it as an ordinary environment variable.

2. Build the release with a Forecastle that includes the environment-file
   prefix ([forecastle#60](https://github.com/ausimian/forecastle/issues/60)),
   and with a Castle that supports it
   ([castle#56](https://github.com/ausimian/castle/issues/56)). Forecastle's
   prefix reads the file at boot; Castle reads it when a hot install or a
   commit resolves the configuration.

3. Write the file for the version you are running, in its version directory,
   and restart once, so that the running node has `CASTLE_ENV_FILE` in its
   environment. Castle looks for the variable there.

Castle reads the file when the *target* is installed, using the target's own
Castle code. So the upgrade that brings this Castle version is the first one
that reads it.

An absolute `CASTLE_ENV_FILE` names one file that every version reads instead.
That gives up everything in the list above, and is there for deployments that
want it.

## Deploying a version

1. Copy the tarball into `releases/` and run `bin/castle unpack <vsn>`.
2. Write `releases/<vsn>/castle.env`. Start from the running version's file and
   change what this version needs.
3. Run `bin/castle install <vsn>`. The target's providers read its file, and
   `config_change/3` sees the result.
4. Check the system, then run `bin/castle commit`.

A version whose file is missing is refused at step 3, and nothing changes. A
version that becomes permanent without one cannot start, and neither can
`bin/castle`, because every launcher command reads the permanent version's
file.

Because a hot upgrade installs a version, configuration changes travel with a
new version. There is no command that re-resolves the configuration of the
version that is already running; to change that, restart it.

### Removing a variable

Write `unset NAME` in the new version's file. Leaving the line out is not
enough: the running node still holds the value from its own file, and Castle
reads the target's file over the node's environment, so the value survives the
hot install. A restart into a pending version behaves the same way, reading the
replaced version's file and then the target's. Only a plain restart starts from
the supervisor's environment alone. `unset` removes the variable in every case,
even when the supervisor also sets it.

### Leave the file alone between install and commit

`commit` resolves the configuration again, so that the version made permanent
is configured as a boot at that moment would configure it. It does not call
`config_change/3`. If the file changed after the install, the running system
keeps the configuration it was installed with, while `sys.config` holds the new
one, and the two differ until the next restart.

## The file

Forecastle's README describes the format in full, under *Environment file*. In
short:

- It is a shell script, run by `/bin/sh` with `set -a`, so every plain
  `KEY=value` line is exported. Quote values that contain spaces, and remember
  that a `'` or `$` in a value is shell syntax.
- It can be read over an environment that already holds values from it or from
  another version's file, so it must give the same result either way. Write
  assignments and `unset`. Do not append to an existing value, as
  `PATH=$PATH:/opt/bin` does.
- If it is missing, unreadable, or a command in it fails, a start stops, and an
  install or commit is refused with nothing changed.
- Do not set `RELEASE_*` variables or `CASTLE_ENV_FILE` in it.

Treat the file as code, because it is executed. Make it writable only by the
people who deploy the release, and readable only by them and the release's
user if it holds secrets (for example, mode `0640`, owned by `root` with the
release's group).

## Writing `runtime.exs` for hot upgrades

- **Use `System.fetch_env!/1` for required variables.** If one is missing, the
  provider raises, and the install is refused before anything changes. A
  default hides the mistake: the target is installed with the default, and the
  running system changes behaviour without saying why.
- **Read variables in `runtime.exs`, not in application code.** Application
  code that calls `System.get_env/1` at runtime sees the running node's
  environment, which a hot upgrade does not change. Read the variable into the
  application environment in `runtime.exs`, and read that.
- **Handle the change in `config_change/3`.** Changing the application
  environment does not restart anything. If a process reads its configuration
  once, at start, implement `config_change/3` in the application callback
  module, and tell that process to reload:

  ```elixir
  @impl Application
  def config_change(changed, _new, removed) do
    if Keyword.has_key?(changed, :pool_size) or :pool_size in removed do
      MyApp.Pool.resize()
    end

    :ok
  end
  ```

- **Handle keys that disappear.** Castle resolves from the configuration Mix
  built every time, never from the last result, so a key that `runtime.exs`
  sets only when a variable is present is gone once the variable is unset.
  `config_change/3` reports it in `removed`, not in `changed`, and code that
  reads the key must treat its absence as "off", not as "unchanged".

## What is not covered

- `bin/castle` and other `rpc` commands read the file only once the permanent
  version was built with Forecastle's prefix. Until then, a restart into a
  pending version reads it only in its second pass. See Forecastle's README.
- The node's own environment is never changed by a hot upgrade. Only the
  configuration is.
- Changes to the supervisor's own environment, including to `CASTLE_ENV_FILE`
  itself, take effect only at a restart.
- A deployment that moved its releases directory with `RELDIR` or
  `{sasl, releases_dir}` keeps `sys.config` there, but the file stays in
  `releases/<vsn>/` under the release root, beside `env.sh`, and `remove` does
  not delete it.
- There is no equivalent for the Windows `.bat` launcher.
