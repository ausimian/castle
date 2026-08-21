defmodule Castle.Commands do
  @moduledoc false

  # The implementation of each of Castle's commands, held apart from the
  # command boundary in `Castle` so that it can be exercised without a booted
  # release:
  #
  #   * every function returns its outcome - the lines to print, or the message
  #     describing the failure - instead of printing or raising, and
  #   * every function that talks to `:release_handler` takes the module to
  #     talk to, so a test can hand it a stub.
  #
  # The module argument is the smallest seam that keeps `Castle`'s own
  # signatures - the ones `bin/castle` and `env.sh` call - unchanged. Nothing
  # outside `Castle` is meant to call this module.

  @app Mix.Project.config()[:app]

  @typedoc """
  The outcome of a command: the lines to report, or the message to fail with.
  """
  @type result :: {:ok, [String.t()]} | {:error, String.t()}

  @reldir "releases"

  @doc """
  Creates the `RELEASES` file from the running permanent release.

  Does nothing if the file already exists. Resolved relative to the current
  working directory, which the caller is expected to have set to the release
  root.
  """
  @spec make_releases(module()) :: result()
  def make_releases(handler \\ :release_handler) do
    releases_file = Path.join(@reldir, "RELEASES")

    if File.exists?(releases_file) do
      {:ok, []}
    else
      {:ok, _} = Application.ensure_all_started(:sasl)
      create_releases(releases_file, handler)
    end
  end

  defp create_releases(releases_file, handler) do
    case handler.which_releases(:permanent) do
      [{name, vsn, _, _}] ->
        relfile = Path.join([@reldir, vsn, "#{name}.rel"])

        # credo:disable-for-next-line Credo.Check.Readability.FunctionNames
        case handler.create_RELEASES(to_charlist(@reldir), relfile, []) do
          :ok ->
            {:ok, []}

          {:error, reason} ->
            {:error, "Cannot create #{releases_file} from #{relfile}. #{inspect(reason)}"}
        end

      [] ->
        {:error, "Cannot create #{releases_file}: no release is running as permanent."}

      releases ->
        vsns = Enum.map_join(releases, ", ", fn {_, vsn, _, _} -> vsn end)

        {:error, "Cannot create #{releases_file}: expected one permanent release, found #{vsns}."}
    end
  end

  @doc """
  Expands the build-time configuration in `rel_vsn_dir` into its `sys.config`.

  The directory is the version directory of the release being configured. It is
  an argument because that is what makes this testable, not because a caller
  gets to choose it: `Castle.generate/1` derives it from the running release,
  and the configuration always lands beside the `build.config` it came from.
  """
  @spec generate(Path.t()) :: result()
  def generate(rel_vsn_dir) do
    build_config_path = Path.join(rel_vsn_dir, "build.config")

    case :file.consult(to_charlist(build_config_path)) do
      {:ok, [build_config]} ->
        write_sys_config(rel_vsn_dir, expand(build_config))

      {:ok, terms} ->
        {:error, "Cannot read #{build_config_path}: expected one term, found #{length(terms)}."}

      {:error, reason} ->
        {:error, "Cannot read #{build_config_path}. #{:file.format_error(reason)}"}
    end
  end

  # The providers were stashed under this application's key at build time, each
  # already initialised, so all that is left to do is fold them over the
  # configuration they were built from. An exception raised by a provider - a
  # runtime.exs that cannot find what it needs, say - is left to propagate: it
  # describes the problem better than anything that could be said here.
  defp expand(build_config) do
    build_config
    |> Keyword.get(@app, [])
    |> Keyword.get(:config_providers, [])
    |> Enum.reduce(build_config, fn {mod, arg}, cfg -> mod.load(cfg, arg) end)
  end

  defp write_sys_config(rel_vsn_dir, sys_config) do
    path = Path.join(rel_vsn_dir, "sys.config")
    contents = :io_lib.format(~c"%% coding: utf-8~n~tp.~n", [sys_config])

    case File.write(path, contents) do
      :ok -> {:ok, []}
      {:error, reason} -> {:error, "Cannot write #{path}. #{:file.format_error(reason)}"}
    end
  end

  @doc """
  Unpacks the named release tarball.
  """
  @spec unpack(String.t(), module()) :: result()
  def unpack(name, handler \\ :release_handler) do
    case handler.unpack_release(to_charlist(name)) do
      {:ok, vsn} -> {:ok, ["Unpacked #{vsn} ok"]}
      {:error, reason} -> {:error, "Failed to unpack #{name}. #{inspect(reason)}"}
    end
  end

  @doc """
  Installs `vsn` and makes it the version that is running now.
  """
  @spec install(String.t(), module()) :: result()
  def install(vsn, handler \\ :release_handler) do
    case handler.install_release(to_charlist(vsn)) do
      {:ok, other_vsn, _descr} ->
        {:ok, ["Now running #{vsn} (previously #{other_vsn})."]}

      # The emulator, or one of kernel, stdlib and sasl, is being replaced, so
      # the node reboots and the upgrade instructions run after it comes back.
      # Nothing has failed.
      {:continue_after_restart, other_vsn, _descr} ->
        {:ok,
         [
           "Restarting to install #{vsn} (previously #{other_vsn}).",
           "The upgrade continues once the emulator has restarted."
         ]}

      {:error, reason} ->
        {:error, "Install of #{vsn} failed. #{inspect(reason)}"}

      other ->
        {:error, "Install of #{vsn} returned an unexpected result. #{inspect(other)}"}
    end
  end

  @doc """
  Confirms that `vsn` is the release the system is running.

  What `install_release/1` replies says only that the upgrade was accepted. A
  transition that restarts the emulator is replied to and *then* rebooted, and
  for an emulator upgrade the instructions run on the way back up, where they
  can still fail and roll back - so completion has to be observed rather than
  inferred, and the reply does not say which kind of transition it was. This is
  what a caller polls to observe it.

  The running release is the one whose status is `:current` if there is one,
  and the `:permanent` one otherwise: `install` leaves its target `:current`,
  `commit` promotes it to `:permanent`, and both are running. No other status
  is - notably `:unpacked`, which is what a rolled-back continuation leaves the
  target as, and `:tmp_current`, which is written before the reboot a restart
  transition has yet to make.

  Being the running release is necessary but not sufficient, because a node
  that restarted into it can be seen part-way up. `release_handler` records the
  new version as `:current` while `sasl` starts, and distribution is already
  answering by then - so a reply is available before the applications after
  `sasl` have started, and one of them can still fail the boot and take the
  system back to the previous permanent release. Committing on the strength of
  that would make a version that cannot boot the permanent one. So the boot has
  to have finished too, which is what the second condition below is for.
  """
  @spec running(String.t(), module(), module()) :: result()
  def running(vsn, handler \\ :release_handler, init \\ :init) do
    case running_release(handler) do
      ^vsn -> booted(vsn, init)
      nil -> {:error, "#{vsn} is not the running release. No release is running."}
      other -> {:error, "#{vsn} is not the running release. #{other} is."}
    end
  end

  # `init:get_status/0` answers `{InternalStatus, ProvidedStatus}`, and only the
  # second element is any use here. The internal one stays `:starting` for as
  # long as the boot process is alive, which is the whole life of a release
  # started by its boot script - a booted node reports `{:starting, :started}`,
  # so waiting for `{:started, _}` would wait forever.
  #
  # The provided status is what the boot script's `{progress, _}` instructions
  # set (init.erl:692), and `:started` is the last of them. Every boot script
  # Mix generates ends with `{progress, started}`, after the instruction that
  # starts the release's own applications; the hybrid script that continues an
  # emulator upgrade has `release_handler:new_emulator_upgrade/2` applied just
  # before that same marker (systools_make.erl:336). So a provided status of
  # `:started` means the script ran to the end: applications up, and any
  # continuation of the upgrade finished.
  #
  # The marker is the whole of the evidence, so this trusts whichever boot
  # script was selected to emit it where it means what it says. One that never
  # reaches it is never confirmed - `install` waits, then fails, and the message
  # below names the progress the node did reach - and one that emits it early
  # defeats the check. Mix generates these scripts; both states take an operator
  # writing their own and pointing RELEASE_BOOT_SCRIPT at it.
  defp booted(vsn, init) do
    case init.get_status() do
      {_internal, :started} ->
        {:ok, []}

      {_internal, progress} ->
        {:error,
         "#{vsn} is the running release but has not finished booting: #{inspect(progress)}."}
    end
  end

  defp running_release(handler) do
    releases = for {_, vsn, _, status} <- handler.which_releases(), do: {to_string(vsn), status}

    case with_status(releases, :current) do
      nil -> with_status(releases, :permanent)
      vsn -> vsn
    end
  end

  defp with_status(releases, wanted) do
    Enum.find_value(releases, fn {vsn, status} -> if status == wanted, do: vsn end)
  end

  @doc """
  Makes `vsn` permanent, so that it is the version a restart boots into.
  """
  @spec commit(String.t(), module()) :: result()
  def commit(vsn, handler \\ :release_handler) do
    case handler.make_permanent(to_charlist(vsn)) do
      :ok -> {:ok, ["Committed #{vsn}. System restarts will now boot into this version."]}
      {:error, reason} -> {:error, "Commit of #{vsn} failed. #{inspect(reason)}"}
    end
  end

  @doc """
  Removes `vsn` from the system.
  """
  @spec remove(String.t(), module()) :: result()
  def remove(vsn, handler \\ :release_handler) do
    case handler.remove_release(to_charlist(vsn)) do
      :ok -> {:ok, ["Removed #{vsn}."]}
      {:error, reason} -> {:error, "Removal of #{vsn} failed. #{inspect(reason)}"}
    end
  end

  @doc """
  Lists the releases known to the system, and the status of each.

  Reports no lines at all when the system knows of no releases, rather than
  failing over the column width of an empty table.
  """
  @spec releases(module()) :: result()
  def releases(handler \\ :release_handler) do
    vsns =
      for {_, vsn, _, status} <- handler.which_releases() do
        {to_string(vsn), to_string(status)}
      end

    width = Enum.reduce(vsns, 0, fn {vsn, _}, widest -> max(widest, String.length(vsn)) end)

    {:ok, for({vsn, status} <- vsns, do: "#{String.pad_trailing(vsn, width + 2)}#{status}")}
  end
end
