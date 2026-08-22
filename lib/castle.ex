defmodule Castle do
  @moduledoc """
  Documentation for `Castle`.
  """

  alias Castle.Commands

  # Every function in this module is a command entry point: `bin/castle` sends
  # each one to the running node over `bin/<release> rpc`, and the launcher's
  # env.sh fragment evaluates generate/1 and make_releases/0 in the preboot VM.
  # There is no separate CLI layer to carry the process status, so these
  # functions are the command boundary, and it is here that a failure raises.
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
    report!(Commands.make_releases())
  end

  def generate(vsn) do
    report!(Commands.generate(rel_vsn_dir(vsn)))
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

  # The version directory of the release being operated on, under the root of
  # the release that is running. Derived, never chosen by the caller: which file
  # the configuration lands in is a property of the installation, not an
  # argument. It resolves for any version the running release knows about,
  # because `:release_handler` unpacks every version into this same root.
  defp rel_vsn_dir(vsn), do: Path.join([:code.root_dir(), "releases", vsn])

  defp report!({:ok, lines}), do: Enum.each(lines, &IO.puts/1)
  defp report!({:error, message}), do: raise(Castle.Error, message)
end
