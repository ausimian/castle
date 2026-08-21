defmodule Castle.Error do
  @moduledoc """
  Raised when one of Castle's commands fails.

  Castle's functions are the entry points of the commands that `bin/castle`
  and the launcher's `env.sh` fragment invoke, so a failure has to leave a
  non-zero exit status behind for the shell that asked for the operation.
  Raising is what does that: the expression is evaluated over
  `elixir --rpc-eval`, which catches on the running node and re-raises in the
  local VM, so the local VM exits non-zero while the running node is left
  alone.
  """

  defexception [:message]
end
