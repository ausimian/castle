### Added

- Castle now ships an appup, so a consumer upgrade that moves Castle from 1.0.0
  is a hot upgrade under `auto`. Previously, unless the consumer supplied an
  appup for Castle under `rel/appups`, Forecastle generated an emulator restart
  for any upgrade that changed Castle's version.

### Fixed

- Castle now uses the same releases directory as `:release_handler`, following
  the SASL `releases_dir` option, then `RELDIR`, then `<root>/releases`, with a
  relative directory resolved against the release root. Previously it always
  used `<root>/releases`. On a deployment that set either override, it wrote
  `RELEASES` and the target's configuration where the handler never read them.
- Configuring a target release now uses the deployment's root for its
  applications and emulator, rather than the directory two levels above the
  version directory, so it works when the releases directory has been moved.
