### Added

- `CASTLE_ENV_FILE`: when the supervisor sets it, `install` and `commit` source
  the file it names before resolving the target's config providers, as
  Forecastle's `env.sh` does at boot. A hot install and a restart now configure
  each version from the same values, and a variable written for the target
  reaches `runtime.exs` and `config_change/3`. A relative name is a file in the
  target's own version directory, `releases/<vsn>/`, which the deployment writes
  after `unpack`, so a rollback reads the file its version was installed with.
  The target's own Castle sources the file, so this works from the upgrade that
  brings this version. A file that is missing, unreadable or fails refuses the
  operation, and nothing changes.
  ([#56](https://github.com/ausimian/castle/issues/56))
- A guide, *Configuring from environment variables*, covering how to set up the
  file, how to deploy a version with it, and how to write `runtime.exs` and
  `config_change/3` for hot upgrades.
