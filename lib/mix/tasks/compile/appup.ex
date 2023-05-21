defmodule Mix.Tasks.Compile.Appup do
  @moduledoc """
  Compiles appup files into the application's ebin folder.
  """
  @shortdoc "Compiles appup files"
  use Mix.Task.Compiler

  @recursive true

  @impl true
  def run(_args) do
    if src = Mix.Project.config()[:appup] do
      if File.exists?(src) do
        {appup, []} = Code.eval_file(src)
        dst = Path.join(Mix.Project.compile_path(), "#{Mix.Project.config()[:app]}.appup")
        File.write(dst, :io_lib.format('~tp.~n', [appup]))
      else
        {:ok, diagnostic(:warning, "Appup file not found: #{src}")}
      end
    else
      {:ok, diagnostic(:warning, "No appup specified in project")}
    end
  end

  defp diagnostic(severity, message, file \\ Mix.Project.project_file()) do
    %Mix.Task.Compiler.Diagnostic{
      compiler_name: "Appup",
      file: file,
      position: nil,
      severity: severity,
      message: message
    }
  end
end
