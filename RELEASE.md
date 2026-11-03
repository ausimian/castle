### Fixed

- The lines `unpack`, `install`, `commit` and `remove` log now reach the node's
  log on a node using Elixir's default `Logger` handler. In 1.3.0 that handler's
  `remote_gl` filter dropped them, because they were logged under the group
  leader of the `rpc` that ran the command, which is on another node. The
  `unpack` and `install` that bring 1.3.1 are run by 1.3.0, so those two are
  still not logged. ([#63](https://github.com/ausimian/castle/issues/63))
