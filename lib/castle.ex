defmodule Castle do
  @moduledoc """
  Documentation for `Castle`.
  """

  alias Castle.Commands
  alias Castle.Deployment

  # Every function in this module is a command entry point: `bin/castle` sends
  # each one to the running node over `bin/<release> rpc`, and the launcher's
  # env.sh fragment evaluates make_releases/0 in the preboot VM, on the first
  # start of a deployment. There is no separate CLI layer to carry the process
  # status, so these functions are the command boundary, and it is here that a
  # failure raises.
  #
  # Raising, rather than halting or returning: the rpc expression runs on the
  # running release node, so halting there would halt the system under
  # management rather than the caller. `Kernel.CLI.rpc_eval/1` catches on the
  # node and the local VM re-raises, printing the reason and exiting non-zero
  # while the running node is left untouched. A returned error value would be
  # discarded - `Kernel.CLI` only inspects the result of a command for `:ok`.
  #
  # `Castle.Commands` holds the operations themselves, returning their outcome
  # rather than acting on the process, so that they can be tested.

  def make_releases do
    report!(Commands.make_releases(rel_dir()))
  end

  # A question, and not a gate anything has to ask: `unpack/1` and `install/1`
  # make the same check themselves, inside the operation, where nothing can
  # happen between the answer and the act. This is how an operator asks without
  # acting - the state it reports is invisible otherwise, because the file can be
  # there while the record the node works from was synthesised. Do not put it
  # back in front of them: a check in a call of its own is a check about a moment
  # that has passed, and `bin/castle` sends each of these as a separate rpc.
  def upgradable do
    report!(Commands.upgradable())
  end

  def unpack(name) when is_binary(name) do
    report!(Commands.unpack(name))
  end

  # Materialising is *inside* `Commands.install/5`, and this composing it here is
  # the bug that put it there. Materialisation ends in a rename onto the target's
  # `sys.config` - a replace by design, and it has to be, because that is the file
  # `:release_handler` reads - so it is not the harmless idempotent work the note
  # below used to call it. Two callers here both materialised before either
  # entered the serialised region, and the loser's providers - evaluated in a
  # second VM, with whatever environment that call had - overwrote the
  # configuration the winner's provisional release was about to boot, after which
  # the loser was refused for the winner's marker. The refused install decided the
  # configuration of the one that succeeded.
  #
  # So there is nothing to compose: `Castle.install/1` is one call, and "an
  # install is serialised" is now true of *this* function rather than of a part of
  # it. See `Castle.Commands.install/5` and `serialised/2`.
  def install(vsn) when is_binary(vsn) do
    report!(Commands.install(vsn, rel_dir()))
  end

  def running(vsn) when is_binary(vsn) do
    report!(Commands.running(vsn))
  end

  def commit(vsn) when is_binary(vsn) do
    materialise(vsn)
    report!(Commands.commit(vsn))
  end

  def remove(vsn) when is_binary(vsn) do
    report!(Commands.remove(vsn))
  end

  def releases do
    report!(Commands.releases())
  end

  # Makes sure the target version's configuration exists before the version is
  # handed to `:release_handler`, and fails here if it cannot be made to.
  # Everything about the target that can refuse to go on - a peer that will not
  # start, a boot script that is not there, a provider that raises - refuses from
  # inside this call.
  #
  # **`commit/1` is the only caller, and `install/1` must not become one again.**
  # This is a *replace*: the last thing it does is rename the resolved
  # configuration onto `sys.config`. Composed in front of an operation it turns
  # into two steps that another caller can get between, which is exactly what
  # `Commands.install/5` had to take back inside its own lock. `commit/1` is
  # different in kind rather than merely luckier - it makes permanent a version
  # this node already installed and is running, so materialising produces what a
  # boot at commit time would produce, and there is no marker, no reboot and no
  # window between a configuration and a boot of it for a second caller to land
  # in. Putting `commit` behind the install lock would instead be a deadlock
  # dressed as caution, since an install waiting on a reboot is exactly when a
  # commit is wanted.
  defp materialise(vsn), do: report!(Commands.materialise(rel_vsn_dir(vsn)))

  # The release directory, and the version directory of the release being
  # operated on beneath it. Derived, never chosen by the caller: which file the
  # configuration lands in, and which file the release records go in, are
  # properties of the installation rather than arguments, and a caller's working
  # directory cannot make them name different ones. The version directory
  # resolves for any version the running release knows about, because
  # `:release_handler` unpacks every version into this same root.
  #
  # `Castle.Deployment.root_dir/0` says what that root does and does not decide,
  # and is the one place that says it. The part that bears on these two: it is
  # the right derivation for a release Mix built, and only because Mix sets
  # neither of the two things that would move the release records elsewhere -
  # see castle#23.
  #
  # It is read through `Castle.Deployment` so that there is one place naming it,
  # the same place `Castle.Commands.ensure_own_erts/2` compares it against
  # `RELEASE_ROOT` - which is the one deployment where this derivation names the
  # wrong tree, and where every operation that would act on it refuses.
  defp rel_dir, do: Path.join(Deployment.root_dir(), "releases")
  defp rel_vsn_dir(vsn), do: Path.join(rel_dir(), vsn)

  defp report!({:ok, lines}), do: Enum.each(lines, &IO.puts/1)
  defp report!({:error, message}), do: raise(Castle.Error, message)
end
