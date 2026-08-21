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
    generate(vsn)
    report!(Commands.install(vsn))
  end

  def running(vsn) when is_binary(vsn) do
    report!(Commands.running(vsn))
  end

  def commit(vsn) when is_binary(vsn) do
    generate(vsn)
    report!(Commands.commit(vsn))
  end

  def remove(vsn) when is_binary(vsn) do
    report!(Commands.remove(vsn))
  end

  def releases do
    report!(Commands.releases())
  end

  # The version directory of the running release. Where the configuration is
  # written is derived from the release that is running, never chosen by the
  # caller - see castle#13, which materialises target configuration in a peer
  # rather than extending this path.
  defp rel_vsn_dir(vsn), do: Path.join([:code.root_dir(), "releases", vsn])

  defp report!({:ok, lines}), do: Enum.each(lines, &IO.puts/1)
  defp report!({:error, message}), do: raise(Castle.Error, message)
end
