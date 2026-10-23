### Changed

- Castle now requires Forecastle 1.1 or later, which adds the
  `require_relup: true` release option: a build that sets it and has no
  `upgrade_from:` is rejected before assembly instead of producing a release
  with no relup.
- A consumer upgrade that moves Castle from 1.0.0 or 1.0.1 to 1.1.0 stays hot
  under `auto`, since Castle's appup covers both.
