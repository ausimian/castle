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
  # two of them moved it *down* for a reason that is not about tests:
  # `Castle.PeerProviderStub` and most of `Castle.IoSink` execute inside the peer
  # VM, which nothing instruments - see the threshold below. Their code genuinely
  # runs and genuinely cannot be observed from here, so the figure they
  # contributed was an artefact of where they run rather than a gap in the suite,
  # and raising it would have meant calling them directly on the test node, which
  # tests nothing.
  #
  # Named module by module rather than matched by a pattern. A regex over `Stub`
  # or over `Castle.*Release` would quietly swallow a production module that
  # happened to be spelled that way, which is the one thing an exclusion list
  # must not do. Renaming a fixture makes the total drop, which is visible.
  #
  # **The threshold is a floor across the supported range, not this machine's
  # reading.** `elixir: "~> 1.18"` invites in every version from 1.18 upwards,
  # and cover's line attribution is not the same across them: 1.18.3 through
  # 1.19.5 count 473 relevant lines and report 88.58%, while 1.20.3 counts one
  # more in `Castle.Peer` and reports 88.40%. Same tests, same covered lines, a
  # different denominator. So this is the *lowest* of those readings, rounded
  # down, so that it absorbs a line of drift instead of sitting on one version's
  # figure. The per-toolchain measurements are in AGENTS.md.
  #
  # Two earlier values were wrong in opposite directions, and both mistakes are
  # worth keeping written down. 85 sat *below* the figure it was meant to floor,
  # so it ratcheted nothing and licensed a thirteen-line regression. 88.58 was
  # the pinned toolchain's exact reading with no slack, which made the *mandatory*
  # `mix precommit` fail on a clean tree under Elixir 1.20 - a false failure for
  # any contributor on a current release, and the comment beside it had already
  # said attribution varies by version while the number ignored it. So: do not
  # set this from one machine, and do not raise it to 88.40 or above, which
  # re-creates the trap the moment another version attributes differently.
  #
  # 88 absorbs two uncovered lines added to `lib` and fails on the third, which
  # was measured on 1.20 (the least slack of the range) rather than estimated -
  # 88.40, 88.21, 88.03, then 87.84 and exit 3. That is looser than a floor
  # ideally is, and it is the deliberate price of enough headroom that one more
  # line of attribution drift does not fail a clean tree. The direction of the
  # trade is the point: a floor that fires on a clean tree teaches people to
  # bypass the gate.
  #
  # 90% would need 426 covered on 1.19's denominator, seven more than there are.
  # What is left there is 33 lines in the peer's VM (below) plus 21 observable in
  # principle: five are the compiler's own default-argument clauses for arities
  # nothing calls, and the other sixteen need a file mode, a device node, or a
  # config provider sabotaging Castle's working directory. So the seven would
  # have to include all five of the default-argument clauses, whose only effect
  # is on this number. That is the move this project does not make. See AGENTS.md
  # for the line-by-line account.
  #
  # **What cannot be measured is the peer's VM, and the reason is where
  # instrumentation is applied rather than anything cover cannot do.**
  # `:cover.start/0` works perfectly well in a VM with no node name -
  # `is_alive() == false` is no obstacle to it. What happens here is that Mix
  # starts cover on *this* node and instruments the modules loaded here; the peer
  # is a separate VM that loads `Castle.Peer` from the target release's own beam
  # files on disk, which nothing has instrumented. Cover's only mechanism for
  # another VM is `:cover.start/1` over a *distributed* node, and this peer
  # deliberately has no distribution at all. So `resolve/1` and everything below
  # the `## In the peer` comment - 33 lines, about 7% of the shipped total - run
  # on every `Castle.PeerTest` and are counted as missed, which puts the
  # observable ceiling near 93%.
  defp test_coverage do
    [
      summary: [threshold: 88],
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
        # With `--cover`, so the threshold in `test_coverage/0` is a gate rather
        # than decoration: nothing else runs it, and a floor nothing enforces is
        # a number in a comment.
        #
        # **This runs on whatever Elixir the contributor has**, which is the
        # thing to keep in mind before touching the threshold. CI's `test` matrix
        # stays on a plain `mix test` and CI's `precommit` job is pinned to one
        # version, so a floor set from that one version is not checked anywhere
        # against the rest of the `~> 1.18` range - it is checked here, on a
        # machine CI never sees, in the gate this project makes mandatory. That
        # is why the number is a floor across the range and not a reading. See
        # `test_coverage/0`.
        "test --cover"
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
