defmodule Castle.Deployment do
  @moduledoc false

  # The two facts about the running deployment that say whether the release
  # brought its own ERTS, and nothing else. They live here so that there is one
  # place each is read - and so that a test can hand `Castle.Commands` a stub
  # that answers them differently, which is the only way to reach a state
  # `mix test` never runs in. The comparison itself stays in
  # `Castle.Commands.ensure_own_erts/2`, so what a test exercises is the real
  # rule over substituted inputs, the way the release-record check exercises the
  # real rule over a substituted `which_releases/0`.

  @doc """
  The root `:release_handler` resolves its own relative paths against.

  This is the authoritative account of what that root does and does not decide;
  everywhere else in Castle that needs it should point here rather than restate
  it, because restating it is how the two halves below came to be conflated in
  four separate places.

  **Two anchors, not one.** `root_dir_relative_path/1` is
  `filename:join(code:root_dir(), Pathname)`, so what is anchored *here* is the
  applications: the `extract_tar(Root, Tar)` an unpack goes through, every
  `lib/<app>-<vsn>` the handler resolves — stored relatively by
  `create_RELEASES/3` precisely so the file can be moved — and the
  `erts-<vsn>` a removal deletes.

  **The release records are not.** `init/1` takes its releases directory from
  `{sasl, releases_dir}`, then `RELDIR`, and only then `init:get_argument(root)`.
  Mix sets neither, so on a Mix release `releases/RELEASES` and
  `releases/<vsn>/…` land under this root too — but by default rather than
  necessarily, and Castle currently derives them as though it were necessarily
  (see [#23](https://github.com/ausimian/castle/issues/23)).

  The distinction is what makes the ERTS guard correct: a deployment whose root
  is not its own cannot be rescued by relocating the records, because relocating
  them moves the bookkeeping and leaves the applications where they were.
  """
  @spec root_dir() :: Path.t()
  def root_dir, do: to_string(:code.root_dir())

  @doc """
  The deployment root the launcher exported, or `nil` when there is none.

  Every launcher `mix release` generates assigns `RELEASE_ROOT` from its own
  location and exports it before it sources `env.sh`, so every VM a release
  starts - the node itself, the preboot VM the `env.sh` fragment runs
  `Castle.make_releases/0` in, and `bin/castle`'s `rpc` - has it. Nothing else
  sets it: under `mix test`, or in a VM started by hand, it is absent, which is
  what makes the guard built on it inert outside a release.
  """
  @spec release_root() :: Path.t() | nil
  def release_root, do: System.get_env("RELEASE_ROOT")

  @doc """
  What the filesystem says about a path, for identifying two of them.

  Here rather than called directly so that the answers the comparison has to
  handle can be produced on demand. Two of them cannot be arranged reliably from
  a test: a `stat` that fails with `:eacces` needs a mode that root and some
  filesystems ignore, and a `%File.Stat{inode: 0}` needs a filesystem that
  reports no inode numbers, which is not something a test can mount. A fixture
  that only sometimes produces the state it describes is a test that only
  sometimes tests anything, and it passes either way - which is exactly how the
  first attempt at covering `:eacces` came to accept the regression it was
  written to catch.
  """
  @spec stat(Path.t()) :: {:ok, File.Stat.t()} | {:error, File.posix()}
  def stat(path), do: File.stat(path)
end
