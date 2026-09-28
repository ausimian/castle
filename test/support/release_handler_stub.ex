defmodule Castle.ReleaseHandlerStub do
  @moduledoc false

  # A stand-in for `:release_handler`, so that the outcome of each of Castle's
  # commands can be tested without a booted release.
  #
  # Replies are registered per test with `stub/2` and calls recorded for
  # `calls/1`. Both live in the process dictionary of the calling process:
  # `Castle.Commands` calls this module inline, in the test process, so nothing
  # is shared between tests running concurrently.

  @doc """
  Registers the value the named function replies with, and returns this module
  so that it can be passed straight to the function under test.

  A reply that is a function of one argument is called with the call's arguments
  and its result used as the reply. That is for the tests about *ordering* around
  a mutating call: `install_release/1` is the one thing that happens between
  arming the restart marker and reporting, and `prepare_restart_new_emulator/7`
  writing `new_start_erl.data` before it can still fail is a state no end-state
  fixture can produce, because it only exists while a call is in flight.
  """
  def stub(fun, reply) when is_atom(fun) do
    Process.put({__MODULE__, fun}, reply)
    __MODULE__
  end

  @doc """
  The arguments of each call made to the named function, oldest first.
  """
  def calls(fun) when is_atom(fun) do
    Enum.reverse(Process.get({__MODULE__, {:calls, fun}}, []))
  end

  def unpack_release(name), do: reply(:unpack_release, [name])
  def install_release(vsn), do: reply(:install_release, [vsn])
  def make_permanent(vsn), do: reply(:make_permanent, [vsn])
  def remove_release(vsn), do: reply(:remove_release, [vsn])

  # Both arities answer from the same registration; no command uses both.
  def which_releases, do: reply(:which_releases, [])
  def which_releases(status), do: reply(:which_releases, [status])

  # credo:disable-for-next-line Credo.Check.Readability.FunctionNames
  def create_RELEASES(root, relfile, appdirs) do
    reply(:create_RELEASES, [root, relfile, appdirs])
  end

  defp reply(fun, args) do
    calls = {__MODULE__, {:calls, fun}}
    Process.put(calls, [args | Process.get(calls, [])])

    case Process.get({__MODULE__, fun}, :unstubbed) do
      :unstubbed -> raise "#{fun}/#{length(args)} was called without a registered reply"
      reply when is_function(reply, 1) -> reply.(args)
      reply -> reply
    end
  end
end
