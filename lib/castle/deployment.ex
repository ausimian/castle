defmodule Castle.Deployment do
  @moduledoc false

  # The facts about the running deployment that Castle cannot arrange and a test
  # cannot produce on demand. They live here so that there is one place each is
  # read - and so that a test can hand `Castle.Commands` a stub that answers them
  # differently, which is the only way to reach a state `mix test` never runs in.
  # The rules built on them stay in `Castle.Commands`, so what a test exercises is
  # the real rule over substituted inputs, the way the release-record check
  # exercises the real rule over a substituted `which_releases/0`.
  #
  # Two roots, for the ERTS guard, and four filesystem operations: the `stat/1`
  # that guard falls back to, the `lstat/1` that classifies the restart-marker
  # path before configuration changes, and the `read/1` and `rm/1` that settle
  # marker ownership after a failed install. All four are here for one reason -
  # the answers that matter are the *failing* ones, and every fixture that relies
  # on a permission failure depends on a mode that root and some filesystems
  # ignore. See `stat/1`.
  #
  # **This is not a general filesystem seam and must not become one.** The
  # primitives that *publish* the marker - `Castle.Peer.work_dir/1`,
  # `write_private/2` and `publish/2` - are deliberately called directly and not
  # through here: what they guarantee is the point of them, and a stub would
  # prove nothing about it. These operations carry the opposite kind of thing:
  # outcomes Castle has to describe and no reliable way to cause in a fixture.

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
  `erts-<erts_vsn>` a removal deletes.

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

  @doc """
  Inspects a path without following its final symbolic link.

  The restart-marker preflight has to distinguish a missing path, a regular
  marker and some other occupant. A failure to inspect is a fourth state, but it
  cannot be produced reliably with permissions in a test. Keeping this read here
  lets the lifecycle test establish that Castle refuses before configuration or
  `install_release/1` is reached.
  """
  @spec lstat(Path.t()) :: {:ok, File.Stat.t()} | {:error, File.posix()}
  def lstat(path), do: File.lstat(path)

  @doc """
  Reads a file, for deciding whether the restart marker is still this attempt's.

  Here for the reason `stat/1` is, and the reason is sharper: the answer that
  changes what Castle *says* is the one where the marker cannot be read at all,
  and a marker Castle published is a regular file in a directory it verified it
  could write to - so the only ways to make this fail are a mode applied
  underneath it, a filesystem that went away, or a name that stopped being a
  file. None of those is something a test may arrange and then rely on.

  An unreadable marker used to be treated as another attempt's and left where it
  was, which is how an install could fail while leaving behind exactly the file
  the next start acts on. Telling the two apart is what this exists for.
  """
  @spec read(Path.t()) :: {:ok, binary()} | {:error, File.posix()}
  def read(path), do: File.read(path)

  @doc """
  Removes a file, for clearing the restart marker this attempt armed.

  Here for the same reason as `read/1`. The argument this replaced was that a
  removal could not fail where the publish had succeeded, since both need
  permission on the same directory - which is true only if nothing changed in
  between, and `install_release/1` runs in between and can take as long as an
  upgrade takes.
  """
  @spec rm(Path.t()) :: :ok | {:error, File.posix()}
  def rm(path), do: File.rm(path)
end
