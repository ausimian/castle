defmodule Mix.Tasks.Castle.Relup do
  @moduledoc """
  Generate a relup file between releases.

  `castle.relup` will generate a relup between a `target` release and
  any number of other releases. The paths specifed in the options should
  be the paths to `.rel` files (but without the .rel extension)

  ## Command-line options:

    - `--target` - the path to the .rel file in the target release
    - `--fromto` - the path to the .rel file from a previous release
    - `--upfrom` - the path to the .rel file from a previous release
    - `--downto` - the path to the .rel file from a previous release
    - `--outdir` - the directory to write the relup. Defaults to the current directory

  The `--fromto`, `--upfrom` and `--downto` switches may be specified zero or more
  times and have the following behaviour:

    - `--fromto` generates both upgrade and downgrade instructions
    - `--upfrom` generates only upgrade instructions
    - `--downto` generates only downgrade instructions
  """
  @shortdoc "Generate a relup file between releases"

  use Mix.Task

  @options [upfrom: :keep, downto: :keep, fromto: :keep, outdir: :string, target: :string]

  @impl Mix.Task
  def run(command_line_args) do
    {:ok, _} = :application.ensure_all_started(:sasl)
    case OptionParser.parse(command_line_args, [strict: @options]) do
      {cmdline_args, _, _} ->
        relup_args = make_relup_args(cmdline_args)
        apply(:systools, :make_relup, relup_args)
    end
  end

  defp make_relup_args(cmdline_args) do
    target = Keyword.fetch!(cmdline_args, :target) |> to_charlist()
    upfrom = get_rel_paths(cmdline_args, :upfrom)
    downto = get_rel_paths(cmdline_args, :downto)
    fromto = get_rel_paths(cmdline_args, :fromto)
    opts = [path: get_ebin_paths([target] ++ upfrom ++ downto ++ fromto)]
    [target, upfrom ++ fromto, downto ++ fromto, opts]
  end

  defp get_rel_paths(cmdline_args, type) do
    cmdline_args
    |> Keyword.take([type])
    |> Keyword.values()
    |> Enum.map(&to_charlist/1)
  end

  defp get_ebin_paths(relpaths) do
    relpaths
    |> Enum.map(&Path.join(&1, "../../../lib/*/ebin"))
    |> Enum.map(&Path.expand/1)
    |> Enum.map(&to_charlist/1)
  end

end
