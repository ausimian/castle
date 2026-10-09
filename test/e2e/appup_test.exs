defmodule Castle.AppupTest do
  @moduledoc """
  Castle's appup, checked the way a consumer meets it: a release built against a
  Castle on Hex, hot-upgraded to one built against the package this repository
  is about to publish.

  Everything version-specific comes from `appup.exs`. The version it names is
  the candidate, and each literal version it upgrades from is a baseline, built
  against that Castle from Hex. So the test is not edited per release: the appup
  is, and the test follows it. A regex from-version is skipped, because Hex has
  no release to build for a pattern.

  The candidate is built from `mix hex.build --unpack`, not from this tree, so a
  file the package leaves out - `appup.exs` most of all - fails here rather than
  in a consumer's build. Its `@version` is rewritten to the appup's, because that
  version does not exist until `mix publisho` bumps it, and `VERSION_OVERRIDE`
  will not do: Forecastle's `mix.exs` reads the same variable.

  The consumer is `test/fixtures/consumer`, which depends on Castle and nothing
  else, and whose own version never moves - so the relup between the two
  releases is Castle's appup and nothing else.

  Excluded from `mix test` and `mix precommit`; it needs the network for Hex and
  takes minutes. Run it before every release:

      mix test --include e2e test/e2e/appup_test.exs
  """

  use Forecastle.UpgradeCase

  @moduletag :e2e

  @root Path.expand("../..", __DIR__)
  @fixture Path.join(@root, "test/fixtures/consumer")
  @appup Path.join(@root, "appup.exs")
  @external_resource @appup

  {{to, ups, _downs}, _binding} = Code.eval_file(@appup)
  @to to_string(to)
  @froms for {from, _instructions} <- ups, is_list(from), do: to_string(from)

  setup_all %{scratch: scratch} do
    # Builds only: no release is started under here, so clearing it cannot pull a
    # tree out from under a running node - which is the reason the template
    # leaves `scratch` itself alone.
    builds = Path.join(scratch, "builds")
    File.rm_rf!(builds)
    File.mkdir_p!(builds)

    baselines =
      Map.new(@froms, fn from ->
        {from, build!(Path.join(builds, "baseline-#{from}"), "hex:#{from}", from)}
      end)

    package = package!(Path.join(builds, "castle"))

    target =
      build!(Path.join(builds, "target"), "path:#{package}", @to,
        upgrade_from: Enum.map(baselines, fn {_from, tar} -> "tar:#{tar}" end)
      )

    {:ok, builds: builds, baselines: baselines, package: package, target: target}
  end

  test "names a version to upgrade from" do
    assert @froms != [], "appup.exs names no literal version to upgrade from"
  end

  test "the package carries the appup", %{package: package} do
    # The other half of `files:` in `mix.exs`. A package without it builds a
    # Castle with no appup and the upgrades below turn into emulator restarts -
    # which they would report as a failure, but not as this one.
    assert File.regular?(Path.join(package, "appup.exs"))
  end

  for from <- @froms do
    @from from

    test "covers every Castle module that moved from #{from}", %{builds: builds} = context do
      # Forecastle's coverage check, on the two releases the upgrade below uses.
      # It compares compiled modules, so it catches a module changed since the
      # last release that the appup forgot.
      {output, status} =
        mix(
          Path.join(builds, "target"),
          [
            "castle.appup",
            "--app",
            "castle",
            "--from",
            "tar:#{context.baselines[@from]}",
            "--to",
            "rel:" <>
              Path.join(builds, "target/_build/prod/rel/consumer/releases/#{@to}/consumer")
          ],
          consumer_env("path:#{context.package}", @to)
        )

      assert status == 0, output
    end

    test "a consumer on Castle #{from} upgrades to #{@to} without a restart", context do
      deployment =
        Deployment.deploy!(
          "tar:#{context.baselines[@from]}",
          Path.join(context.scratch, "deploy")
        )

      on_exit(fn -> Deployment.stop(deployment) end)

      Deployment.start!(deployment)
      os_pid = Deployment.os_pid(deployment)
      assert castle(deployment).vsn == @from

      # `install` is run by the *old* Castle, which the relup replaces while that
      # install is still in progress - the case `appup.exs` warns about.
      Deployment.stage!(deployment, context.target)
      Deployment.castle!(deployment, ["unpack", @to])
      Deployment.castle!(deployment, ["install", @to])

      installed = castle(deployment)
      assert installed.vsn == @to

      # The new code is what is serving, not merely what is on disk. A module the
      # relup did not load would still be the old one here while the
      # application reported the new version.
      assert installed.stale == [], "not running #{@to}'s code: #{inspect(installed.stale)}"

      Deployment.castle!(deployment, ["commit"])

      # Committing is what purges the old code, and it runs on the new Castle.
      committed = castle(deployment)
      assert committed.old_code == []
      assert Deployment.castle!(deployment, ["releases"]) =~ ~r/#{@to}\s+permanent/

      # And the new Castle answers a command of its own.
      Deployment.castle!(deployment, ["upgradable"])

      assert Deployment.os_pid(deployment) == os_pid, "the upgrade restarted the emulator"
    end
  end

  # What the running node says about Castle: its version, any module whose
  # loaded code differs from that version's beam, and any module still carrying
  # old code. Compared by md5 rather than by where a module was loaded from: a
  # relup loads only the modules that changed, so an unchanged one is still the
  # copy from the previous version's directory - and identical to the new one.
  defp castle(deployment) do
    expression = """
    vsn = to_string(Application.spec(:castle, :vsn))
    mods = Application.spec(:castle, :modules)
    ebin = Path.join(:code.lib_dir(:castle), "ebin")
    stale =
      Enum.reject(mods, fn mod ->
        {:ok, {^mod, md5}} = :beam_lib.md5(String.to_charlist(Path.join(ebin, "\#{mod}.beam")))
        mod.module_info(:md5) == md5
      end)
    old_code = Enum.filter(mods, &:erlang.check_old_code/1)
    IO.puts(:erlang.term_to_binary({vsn, stale, old_code}) |> Base.encode64())
    """

    {vsn, stale, old_code} =
      deployment
      |> Deployment.rpc!(expression)
      |> Base.decode64!()
      |> :erlang.binary_to_term()

    %{vsn: vsn, stale: stale, old_code: old_code}
  end

  # Builds the consumer in a copy of the fixture, against `castle`, as release
  # version `vsn`, and returns the tarball.
  defp build!(dir, castle, vsn, opts \\ []) do
    File.cp_r!(@fixture, dir)

    upgrade_from =
      case Keyword.get(opts, :upgrade_from, []) do
        [] -> nil
        specs -> Enum.join(specs, "|")
      end

    env = consumer_env(castle, vsn) ++ [{"CONSUMER_UPGRADE_FROM", upgrade_from}]
    mix!(dir, ["deps.get"], env)
    mix!(dir, ["release", "--overwrite"], env)

    tar = Path.join(dir, "_build/prod/consumer-#{vsn}.tar.gz")
    assert File.regular?(tar), "#{dir} built no #{Path.basename(tar)}"
    tar
  end

  # The package Hex would serve, unpacked, at the version the appup names.
  defp package!(dir) do
    mix!(@root, ["hex.build", "--unpack", "--output", dir], [])

    mix_exs = Path.join(dir, "mix.exs")
    source = File.read!(mix_exs)
    rewritten = Regex.replace(~r/^  @version ".*"$/m, source, ~s(  @version "#{@to}"))
    assert rewritten =~ ~s(  @version "#{@to}"), "found no @version in #{mix_exs}"
    File.write!(mix_exs, rewritten)

    dir
  end

  defp consumer_env(castle, vsn) do
    [
      {"CONSUMER_CASTLE", castle},
      {"CONSUMER_VSN", vsn},
      {"MIX_ENV", "prod"}
    ]
  end

  defp mix!(dir, args, env) do
    {output, status} = mix(dir, args, env)
    assert status == 0, "mix #{Enum.join(args, " ")} in #{dir} exited with #{status}\n\n#{output}"
    output
  end

  # The environment a deployment command gets, so that nothing in the shell
  # running the tests - `MIX_ENV=test` above all - reaches the build, with the
  # caller's entries taking the place of anything scrubbed under the same name.
  # `VERSION_OVERRIDE` is scrubbed too: Castle's and Forecastle's `mix.exs` both
  # read it, so an inherited one would move both versions.
  defp mix(dir, args, env) do
    names = Enum.map(env, &elem(&1, 0))

    scrubbed =
      Enum.reject(Deployment.scrubbed_env([{"VERSION_OVERRIDE", nil}]), fn {name, _} ->
        name in names
      end)

    System.cmd("mix", args, cd: dir, env: scrubbed ++ env, stderr_to_stdout: true)
  end
end
