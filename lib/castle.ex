defmodule Castle do
  @moduledoc """
  Documentation for `Castle`.
  """

  alias Castle.Commands
  alias Castle.Deployment
  alias Castle.Peer

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
  #
  # **And that claim is tested here rather than one layer down, which is what the
  # four defaulted arguments are for.** `Castle.Commands.install/5` already took
  # the handler, the peer and the deployment so that its own suite could drive two
  # concurrent callers through it; but a test that drives *it* cannot see anything
  # composed in *this* function, so the composition that was the whole defect would
  # have been reintroducible with every test still green. `rel_dir` joins them for
  # the same reason it is an argument there - a suite needs a releases directory of
  # its own to contend over, or the cases cannot run async - and the three module
  # arguments follow it because a caller held at `which_releases/0` is the only
  # seam the interleaving has.
  #
  # They are defaults rather than a separate entry point so that `bin/castle`
  # keeps calling `Castle.install/1` over `rpc` and nothing about the deployment
  # is chosen by a caller: see `rel_dir/0`.
  def install(
        vsn,
        rel_dir \\ rel_dir(),
        handler \\ :release_handler,
        peer \\ Peer,
        deployment \\ Deployment
      )
      when is_binary(vsn) do
    report!(Commands.install(vsn, rel_dir, handler, peer, deployment))
  end

  def running(vsn) when is_binary(vsn) do
    report!(Commands.running(vsn))
  end

  def commit(vsn) when is_binary(vsn) do
    report!(Commands.commit(vsn, rel_dir()))
  end

  def remove(vsn) when is_binary(vsn) do
    report!(Commands.remove(vsn))
  end

  def releases do
    report!(Commands.releases())
  end

  # **Nothing here composes materialisation any more, and neither entry point may
  # start again.** It is a *replace*: the last thing it does is rename the
  # resolved configuration onto `sys.config`. In front of an operation it is two
  # steps another caller can get between, which is why `Commands.install/5` took
  # it back inside its own lock — and `commit/1` has now followed, into
  # `Commands.commit/5`.
  #
  # `commit` was left out on the argument that it is different in kind: it makes
  # permanent a version this node already installed and is running, so there is no
  # marker, no reboot and no window between a configuration and a boot of it. The
  # part that was wrong is what the argument then concluded — that putting commit
  # behind the install lock would be "a deadlock dressed as caution, since an
  # install waiting on a reboot is exactly when a commit is wanted". **An install
  # never holds the lock while waiting on a reboot.** `install_release/1` replies
  # before `init:reboot()` and the reboot runs in `release_handler`'s process, so
  # `Commands.install/5` returns and its `trans` releases before the node goes
  # down; `bin/castle install` then polls `Castle.running/1` over separate rpcs
  # that take no lock, and after a restart transition the VM that held it is gone
  # entirely. The only thing a commit can now wait for is a hot install still
  # inside `install_release/1` — and waiting there is right, because committing
  # part-way through an upgrade is what should not happen.
  #
  # What the composition actually left open was the reachable case: a duplicate
  # install of the version being committed, materialising between the two calls.
  # The commit succeeds, that install then fails as already installed, and its
  # configuration is what the newly permanent release boots on the next restart —
  # a failed caller deciding what a successful one boots, which is the failure
  # this protocol exists to prevent, reachable through the one operation left
  # outside it.

  # The release directory. Derived, never chosen by the caller: which file the
  # configuration lands in, and which file the release records go in, are
  # properties of the installation rather than arguments, and a caller's working
  # directory cannot make them name different ones.
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

  defp report!({:ok, lines}), do: Enum.each(lines, &IO.puts/1)
  defp report!({:error, message}), do: raise(Castle.Error, message)
end
