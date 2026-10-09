defmodule Castle.PeerStub do
  @moduledoc false

  # A stand-in for `Castle.Peer`, so that the decision `Castle.Commands`
  # makes about *which* way a release is configured can be tested without
  # starting a VM to configure it.
  #
  # Replies are registered per test and calls recorded, both in the calling
  # process's dictionary, for the same reason `Castle.ReleaseHandlerStub` uses
  # it: the call is made inline, in the test process.

  @doc """
  Registers the reply `materialise/2` answers with, and returns this module so
  that it can be passed straight to the function under test.

  A reply that is a function of one argument is called with the version directory
  and its result used as the reply, the way `Castle.ReleaseHandlerStub` does it.
  That is for the tests about what materialisation *left behind*: the real thing
  ends by renaming a resolved configuration onto the target's `sys.config`, so a
  stub that only answers `{:ok, []}` cannot show which caller's configuration a
  version ended up with. One that writes a distinguishable `sys.config` can.
  """
  def stub(reply) do
    Process.put(__MODULE__, reply)
    __MODULE__
  end

  @doc "The version directory of each call made, oldest first."
  def calls, do: Enum.reverse(Process.get({__MODULE__, :calls}, []))

  @doc "The options each call was given, oldest first, in step with `calls/0`."
  def options, do: Enum.reverse(Process.get({__MODULE__, :options}, []))

  def materialise(rel_vsn_dir, opts \\ []) do
    Process.put({__MODULE__, :calls}, [rel_vsn_dir | Process.get({__MODULE__, :calls}, [])])
    Process.put({__MODULE__, :options}, [opts | Process.get({__MODULE__, :options}, [])])

    case Process.get(__MODULE__, :unstubbed) do
      :unstubbed -> raise "materialise/2 was called without a registered reply"
      reply when is_function(reply, 1) -> reply.(rel_vsn_dir)
      reply -> reply
    end
  end
end
