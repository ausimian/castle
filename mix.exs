defmodule Castle.MixProject do
  use Mix.Project

  @version "0.3.1"
  @source_url "https://github.com/ausimian/castle"

  def project do
    [
      app: :castle,
      description: "Runtime Hot-Code Upgrade support for Elixir",
      version: System.get_env("VERSION_OVERRIDE", @version),
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      package: package(),
      docs: docs(),
      test_coverage: test_coverage(),
      source_url: @source_url
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:sasl]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  # The stubs the unit tests stand in front of :release_handler and the config
  # providers live in test/support.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  # `mix test --cover` measures the shipped code, which is `lib` - the modules
  # under `test/support` are fixtures, and a fixture is covered by being run at
  # all. Left in, they moved the total without ever being the thing measured, and
  # two of them moved it *down* for a reason that is not about tests: `mix test`
  # compiles everything into one `cover` run on this node, while
  # `Castle.PeerProviderStub` and most of `Castle.IoSink` execute inside the peer
  # VM, which is a separate node with no `cover` on it. Their code genuinely runs
  # and genuinely cannot be observed from here, so the figure they contributed was
  # an artefact of where they run rather than a gap in the suite - and raising it
  # would have meant calling them directly on the test node, which tests nothing.
  #
  # Named module by module rather than matched by a pattern. A regex over `Stub`
  # or over `Castle.*Release` would quietly swallow a production module that
  # happened to be spelled that way, which is the one thing an exclusion list
  # must not do. Renaming a fixture makes the total drop, which is visible.
  #
  # The threshold is explicit because the default, 90, is unreachable here by
  # construction rather than for want of tests. The second half of
  # `Castle.Peer` - `resolve/1` and everything below the `## In the peer` comment -
  # runs in the peer VM, which has no node name and `is_alive() == false`, so
  # `cover` cannot be started on it. Around 7% of the shipped lines therefore
  # execute on every run of `Castle.PeerTest` and are counted as missed, which
  # puts the observable ceiling near 93%. Left at the default, `mix test --cover`
  # reports a failure that no test can fix and that says nothing about the suite.
  #
  # It is deliberately not part of `mix precommit`. A percentage is the wrong
  # shape of gate for this project: every test here is justified by what it fails
  # against, and a merge-blocking number cannot tell a test that discriminates
  # from one written to raise it. See AGENTS.md for what is left uncovered and
  # why.
  defp test_coverage do
    [
      summary: [threshold: 85],
      ignore_modules: [
        Castle.DeploymentStub,
        Castle.InitStub,
        Castle.IoSink,
        Castle.PeerProviderStub,
        Castle.PeerStub,
        Castle.ReleaseHandlerStub,
        Castle.SyntheticRelease
      ]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # TEMPORARY for the 1.0.0 cycle. Castle and Forecastle are being developed
      # together, so each depends on the other's integration branch. This MUST be
      # flipped back to {:forecastle, "~> 1.0", runtime: false} before publishing:
      # mix hex.publish hard-fails on a git dependency.
      {:forecastle, github: "ausimian/forecastle", branch: "release/1.0.0", runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.39", only: :dev, runtime: false},
      {:publisho, "~> 1.0", only: :dev, runtime: false}
    ]
  end

  defp aliases do
    [
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --unused",
        "format",
        "credo --strict",
        "test"
      ]
    ]
  end

  defp package do
    [
      maintainers: ["Nick Gunn"],
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Forecastle" => "https://hex.pm/packages/forecastle"
      },
      files: ~w(lib CHANGELOG.md LICENSE mix.exs README.md .formatter.exs)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: @version,
      extras: ["README.md", "CHANGELOG.md"]
    ]
  end
end
