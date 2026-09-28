defmodule Castle.FileReason do
  @moduledoc false

  @spec format(term()) :: String.t()
  def format(reason) when is_atom(reason) do
    formatted = reason |> :file.format_error() |> to_string()

    if contains_identity?(formatted, reason) do
      formatted
    else
      "#{inspect(reason)} (#{formatted})"
    end
  end

  def format(reason), do: inspect(reason)

  defp contains_identity?(formatted, reason) do
    identity = reason |> Atom.to_string() |> Regex.escape()
    Regex.match?(Regex.compile!("(?<![[:alnum:]_])#{identity}(?![[:alnum:]_])"), formatted)
  end
end
