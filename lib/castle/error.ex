defmodule Castle.Error do
  @moduledoc """
  Raised when Castle refuses a command or `:release_handler` returns an error.

  The exception gives `bin/castle` a non-zero exit status without stopping the
  managed node. Unhandled exceptions, throws and exits propagate unchanged.
  """

  defexception [:message]
end
