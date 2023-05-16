defmodule Castle do
  @moduledoc """
  Documentation for `Castle`.
  """

  defstruct configuration_providers: [], include_paths: [], copy_runtime_exs: true

  def make_releases() do
    reldir = "releases"
    releases_file = Path.join(reldir, "RELEASES")
    unless File.exists?(releases_file) do
      {:ok, _} = Application.ensure_all_started(:sasl)
      [{name, vsn, _, _}] = :release_handler.which_releases(:permanent)
      relfile = Path.join([reldir, vsn, "#{name}.rel"])
      :ok = :release_handler.create_RELEASES(to_charlist(reldir), relfile, [])
    end
  end

  def generate(vsn) do
    rel_vsn_dir = Path.join([:code.root_dir, "releases", vsn])
    # Read the build time config from build.config
    {:ok, [build_config]} = :file.consult(to_charlist(Path.join(rel_vsn_dir, "build.config")))
    # Merge runtime.exs into it
    runtime_exs = Path.join(rel_vsn_dir, "runtime.exs")
    sys_config =
      if File.exists?(runtime_exs) do
        Config.Reader.load(build_config, Config.Reader.init(runtime_exs))
      else
        build_config
      end
    File.write!(Path.join(rel_vsn_dir, "sys.config"), :io_lib.format('%% coding: utf-8~n~tp.~n', [sys_config]))
  end

  def unpack(name) when is_binary(name) do
    case :release_handler.unpack_release(to_charlist(name)) do
      {:ok, vsn} ->
        IO.puts("Unpacked #{vsn} ok")
      {:error, reason} ->
        IO.puts("Failed to unpack #{name}. #{inspect(reason)}")
    end
  end

  def install(vsn) when is_binary(vsn) do
    generate(vsn)
    case :release_handler.install_release(to_charlist(vsn)) do
      {:ok, other_vsn, _} ->
        IO.puts("Now running #{vsn} (previously #{other_vsn}).")
      {:error, reason} ->
        IO.puts("Install of #{vsn} failed. #{inspect(reason)}")
    end
  end

  def commit(vsn) when is_binary(vsn) do
    generate(vsn)
    case :release_handler.make_permanent(to_charlist(vsn)) do
      :ok ->
        IO.puts("Committed #{vsn}. System restarts will now boot into this version.")
      {:error, reason} ->
        IO.puts("Commit of #{vsn} failed. #{inspect(reason)}")
    end
  end

  def remove(vsn) when is_binary(vsn) do
    case :release_handler.remove_release(to_charlist(vsn)) do
      :ok ->
        IO.puts("Removed #{vsn}.")
      {:error, reason} ->
        IO.puts("Removal of #{vsn} failed. #{inspect(reason)}")
    end
  end

  def releases() do
    vsns =
      for {_, vsn, _, status} <- :release_handler.which_releases() do
        {to_string(vsn), to_string(status)}
      end
    width =
      vsns
      |> Enum.map(&elem(&1, 0))
      |> Enum.map(&String.length/1)
      |> Enum.max()
    Enum.each(vsns, fn {vsn, status} ->
      IO.puts("#{String.pad_trailing(vsn, width + 2)}#{status}")
    end)
  end

  def pre_assemble(%Mix.Release{} = release) do
    release
    |> initialize()
    |> handle_runtime_configuration()
    |> create_preboot_scripts()
  end

  def post_assemble(%Mix.Release{} = release) do
    release
    |> tap(&rename_sys_config/1)
    |> tap(&restructure_bin_dir/1)
    |> tap(&copy_runtime_exs/1)
    |> tap(&copy_relfile/1)
    |> tap(&copy_relup/1)
  end

  defp initialize(%Mix.Release{options: options} = release) do
    %Mix.Release{release | options: [{__MODULE__, %__MODULE__{}} | options]}
  end

  defp handle_runtime_configuration(%Mix.Release{options: options} = release) do
    runtime_exs = get_runtime_exs()
    if File.exists?(runtime_exs) do
      if Keyword.get(options, :runtime_config_path, true) do
        options = Keyword.update!(options, __MODULE__, fn %__MODULE__{include_paths: incs} = copts ->
          %__MODULE__{copts | copy_runtime_exs: true, include_paths: ["runtime" | incs]}
        end)
        %Mix.Release{release | options: Keyword.put(options, :runtime_config_path, false)}
      end
    end || release
  end

  defp create_preboot_scripts(%Mix.Release{boot_scripts: scripts}  = release) do
    preboot =
      scripts[:start_clean]
      |> Keyword.merge(for app <- [:sasl, :compiler, :elixir, :castle], do: {app, :permanent})
    %Mix.Release{release | boot_scripts: Map.put(scripts, :preboot, preboot)}
  end

  defp rename_sys_config(%Mix.Release{version_path: vp}) do
    File.rename(Path.join(vp, "sys.config"), Path.join(vp, "build.config"))
  end

  defp restructure_bin_dir(%Mix.Release{name: name, path: path}) do
    bin_path = Path.join(path, "bin")
    original = Path.join(bin_path, ".#{name}")
    invoked  = Path.join(bin_path, "#{name}")
    File.rename(Path.join(bin_path, to_string(name)), original)
    File.cp!(Path.join(:code.priv_dir(:castle), "script.sh"), invoked)
    # Enum.each([original, invoked], &File.chmod!(&1, 0o755))
  end

  defp copy_runtime_exs(%Mix.Release{version_path: vp}) do
    runtime_exs = get_runtime_exs()
    if File.exists?(runtime_exs) do
      File.cp!(runtime_exs, Path.join(vp, "runtime.exs"))
    end
  end

  defp copy_relfile(%Mix.Release{name: name, version: vsn, path: path, version_path: vp}) do
    File.cp!(Path.join(vp, "#{name}.rel"), Path.join([path, "releases", "#{name}-#{vsn}.rel"]))
  end

  defp copy_relup(%Mix.Release{version_path: vp}) do
    relup =
      Mix.Project.project_file
      |> Path.dirname()
      |> Path.join("relup")
    if File.exists?(relup) do
      File.cp!(relup, Path.join(vp, "relup"))
    end
  end

  defp get_runtime_exs do
    "../config/runtime.exs"
    |> Path.absname(Mix.Project.project_file)
    |> Path.expand()
  end

end
