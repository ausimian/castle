defmodule Consumer.MixProject do
  # A project that depends on Castle and nothing else, the way a consumer does.
  # `test/e2e/appup_test.exs` builds it twice - once against a Castle published
  # on Hex, once against the package this repository is about to publish - and
  # upgrades one into the other. It is never built in place: the test copies it
  # into a scratch workspace per build.
  #
  # Everything that differs between the two builds comes from the environment,
  # so that one source tree stands for both sides of the upgrade.
  use Mix.Project

  def project do
    [
      app: :consumer,
      # The application's own version never moves. Only Castle's does, so the
      # relup between the two releases is about Castle and nothing else.
      version: "0.1.0",
      elixir: "~> 1.18",
      deps: deps(),
      releases: releases()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  # `hex:<vsn>` is a Castle a consumer could have deployed. `path:<dir>` is the
  # candidate, unpacked from `mix hex.build` so that it is what Hex would serve.
  defp deps do
    case System.fetch_env!("CONSUMER_CASTLE") do
      "hex:" <> vsn -> [{:castle, vsn}]
      "path:" <> dir -> [{:castle, path: dir}]
    end
  end

  # The lazy form Castle documents, because `Castle.customize/1` is not
  # compiled when Mix first reads this file.
  defp releases do
    [
      consumer: fn ->
        Castle.customize(
          [
            version: System.fetch_env!("CONSUMER_VSN"),
            include_executables_for: [:unix]
          ] ++ upgrade_from()
        )
      end
    ]
  end

  # `|`-separated, because a spec is a path and a comma is legal in one.
  defp upgrade_from do
    case System.get_env("CONSUMER_UPGRADE_FROM") do
      nil -> []
      specs -> [upgrade_from: String.split(specs, "|", trim: true)]
    end
  end
end
