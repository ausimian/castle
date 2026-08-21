defmodule Castle.InitStub do
  @moduledoc false

  # A stand-in for `:init`, so that a node seen part-way through its boot can be
  # tested. Answers from the calling process's dictionary, like
  # `Castle.ReleaseHandlerStub`, and for the same reason.

  @doc """
  Registers the status `get_status/0` replies with, and returns this module so
  that it can be passed straight to the function under test.
  """
  def stub(status) do
    Process.put(__MODULE__, status)
    __MODULE__
  end

  def get_status do
    case Process.get(__MODULE__, :unstubbed) do
      :unstubbed -> raise "get_status/0 was called without a registered reply"
      status -> status
    end
  end
end
