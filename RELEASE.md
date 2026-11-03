### Added

- `unpack`, `install`, `commit` and `remove` log what they report on the running
  node, at `info` level in the `[:castle]` logger domain, so the node's own log
  records each change to the deployment. The install that brings this version
  is run by the previous Castle, so that one install is not logged.
