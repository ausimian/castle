### Added

- `unpack`, `install`, `commit` and `remove` log what they report on the running
  node, at `info` level in the `[:castle]` logger domain, so the node's own log
  records each change to the deployment. The install that brings this version
  is run by the previous Castle, so that one install is not logged.

### Changed

- Castle now requires Forecastle 1.2.2 or later. Its hot relups take an
  application they remove off the code path, so a later upgrade with an optional
  dependency on it no longer finds it present, and they start an added
  application that has no modules, which used to stay stopped until the node
  restarted. ([forecastle#72](https://github.com/ausimian/forecastle/pull/72))
- A consumer upgrade that moves Castle from 1.0.0, 1.0.1, 1.1.0, 1.2.0-rc.1,
  1.2.0 or 1.2.1 to 1.3.0 stays hot under `auto`, since Castle's appup covers
  each.
