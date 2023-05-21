defmodule Castle do
  @moduledoc """
  Documentation for `Castle`.
  """

  @app Mix.Project.config()[:app]

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
    rel_vsn_dir = Path.join([:code.root_dir(), "releases", vsn])
    # Read the build time config from build.config
    {:ok, [build_config]} = :file.consult(to_charlist(Path.join(rel_vsn_dir, "build.config")))
    # Generate the sys.config by running the config providers
    sys_config =
      build_config
      |> Keyword.get(@app, [])
      |> Keyword.get(:config_providers, [])
      |> Enum.reduce(build_config, fn {mod, arg}, cfg -> apply(mod, :load, [cfg, arg]) end)

    File.write!(
      Path.join(rel_vsn_dir, "sys.config"),
      :io_lib.format('%% coding: utf-8~n~tp.~n', [sys_config])
    )
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
    |> remove_runtime_configuration()
    |> remove_config_providers()
    |> create_preboot_scripts()
  end

  def post_assemble(%Mix.Release{} = release) do
    release
    |> tap(&add_config_providers/1)
    |> tap(&rename_sys_config/1)
    |> tap(&restructure_bin_dir/1)
    |> tap(&copy_runtime_exs/1)
    |> tap(&copy_relfile/1)
    |> tap(&copy_relup/1)
  end

  defp initialize(%Mix.Release{options: options} = release) do
    %Mix.Release{release | options: [{__MODULE__, []} | options]}
  end

  defp remove_runtime_configuration(%Mix.Release{options: options, version: vsn} = release) do
    runtime_exs = get_runtime_exs()

    if File.exists?(runtime_exs) do
      if Keyword.get(options, :runtime_config_path, true) do
        options =
          Keyword.update(options, __MODULE__, [], fn providers ->
            providers ++
              [
                {Config.Reader,
                 path: {:system, "RELEASE_ROOT", "/releases/#{vsn}/runtime.exs"}, env: Mix.env()}
              ]
          end)

        %Mix.Release{release | options: Keyword.put(options, :runtime_config_path, false)}
      end
    end || release
  end

  defp remove_config_providers(%Mix.Release{} = release) do
    providers =
      release.config_providers
      |> Enum.map(fn {mod, arg} -> if is_list(arg), do: {mod, arg}, else: {mod, path: arg} end)
      |> Enum.map(fn {mod, args} -> {mod, Keyword.put(args, :env, Mix.env())} end)

    options =
      Keyword.update(release.options, __MODULE__, [], fn existing ->
        existing ++ providers
      end)

    %Mix.Release{release | config_providers: [], options: options}
  end

  defp create_preboot_scripts(%Mix.Release{boot_scripts: scripts} = release) do
    preboot =
      scripts[:start_clean]
      |> Keyword.merge(for app <- [:sasl, :compiler, :elixir, @app], do: {app, :permanent})

    %Mix.Release{release | boot_scripts: Map.put(scripts, :preboot, preboot)}
  end

  defp add_config_providers(%Mix.Release{options: options, version_path: vp}) do
    provider_states =
      for {mod, arg} <- Keyword.get(options, __MODULE__, []) do
        {mod, apply(mod, :init, [arg])}
      end

    sys_config_path = Path.join(vp, "sys.config")
    {:ok, [sys_config]} = :file.consult(to_charlist(sys_config_path))

    new_sys_config =
      Keyword.update(
        sys_config,
        @app,
        [config_providers: provider_states],
        &Keyword.put(&1, :config_providers, provider_states)
      )

    File.write!(sys_config_path, :io_lib.format('~tp.~n', [new_sys_config]))
  end

  defp rename_sys_config(%Mix.Release{version_path: vp}) do
    File.rename(Path.join(vp, "sys.config"), Path.join(vp, "build.config"))
  end

  defp restructure_bin_dir(%Mix.Release{name: name, path: path}) do
    bin_path = Path.join(path, "bin")
    original = Path.join(bin_path, ".#{name}")
    invoked = Path.join(bin_path, "#{name}")
    File.rename(Path.join(bin_path, to_string(name)), original)
    File.cp!(Path.join(:code.priv_dir(@app), "script.sh"), invoked)
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
      Mix.Project.project_file()
      |> Path.dirname()
      |> Path.join("relup")

    if File.exists?(relup) do
      File.cp!(relup, Path.join(vp, "relup"))
    end
  end

  defp get_runtime_exs do
    "../config/runtime.exs"
    |> Path.absname(Mix.Project.project_file())
    |> Path.expand()
  end
end
