defmodule Castle do
  @moduledoc """
  Documentation for `Castle`.
  """

  alias Castle.Commands

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

  def upgradable do
    report!(Commands.upgradable())
  end

  def unpack(name) when is_binary(name) do
    report!(Commands.unpack(name))
  end

  def install(vsn) when is_binary(vsn) do
    materialise(vsn)
    report!(Commands.install(vsn))
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
  # handed to `:release_handler`, and fails here if it cannot be made to. It
  # runs ahead of both operations that need it, and everything that can refuse
  # to go on - a peer that will not start, a boot script that is not there, a
  # provider that raises - refuses from inside this call, which is to say before
  # `install_release/1` has been asked for anything. Nothing after that point
  # may fail without saying that an install happened.
  defp materialise(vsn), do: report!(Commands.materialise(rel_vsn_dir(vsn)))

  # The release directory, and the version directory of the release being
  # operated on beneath it. Derived, never chosen by the caller: which file the
  # configuration lands in, and which file the release records go in, are
  # properties of the installation rather than arguments. `code:root_dir()` is
  # the root because that is the root `:release_handler` itself resolves
  # relative paths against, so these name the files it will read, and a caller's
  # working directory cannot make them name different ones. The version
  # directory resolves for any version the running release knows about, because
  # `:release_handler` unpacks every version into this same root.
  defp rel_dir, do: Path.join(to_string(:code.root_dir()), "releases")
  defp rel_vsn_dir(vsn), do: Path.join(rel_dir(), vsn)

  defp report!({:ok, lines}), do: Enum.each(lines, &IO.puts/1)
  defp report!({:error, message}), do: raise(Castle.Error, message)
end
