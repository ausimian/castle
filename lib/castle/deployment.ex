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

  `root_dir_relative_path/1` is `filename:join(code:root_dir(), Pathname)`, so
  this is the directory that decides where `releases/RELEASES`,
  `releases/<vsn>/…` and every `lib/<app>-<vsn>` the handler names actually are.
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
end
