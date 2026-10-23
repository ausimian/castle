### Changed

- Castle now requires Forecastle 1.1 or later, which adds the
  `require_relup: true` release option: a build that sets it and has no
  `upgrade_from:` is rejected before assembly instead of producing a release
  with no relup.
