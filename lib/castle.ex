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
      :io_lib.format(~c"%% coding: utf-8~n~tp.~n", [sys_config])
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

end
