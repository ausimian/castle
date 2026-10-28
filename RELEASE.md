### Changed

- Castle now requires Forecastle 1.2.1 or later, whose hot relups start the
  applications they add in dependency order and stop the ones they remove in
  reverse, instead of in the alphabetical order of the `.rel` file. An added
  application started before one it depends on used to stay stopped until the
  node restarted.
  ([forecastle#66](https://github.com/ausimian/forecastle/issues/66))
- A consumer upgrade that moves Castle from 1.0.0, 1.0.1, 1.1.0, 1.2.0-rc.1 or
  1.2.0 to 1.2.1 stays hot under `auto`, since Castle's appup covers each.
