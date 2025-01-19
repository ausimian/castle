defmodule Castle.MixProject do
  use Mix.Project

  def project do
    [
      app: :castle,
      version: "0.3.1",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      source_url: "https://github.com/ausimian/castle",
      docs: [
        main: "readme",
        extras: ["README.md", "CHANGELOG.md"]
      ],
      package: package()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:sasl]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:forecastle, "~> 0.1.3", runtime: false},
      {:ex_doc, "~> 0.27", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      description: "Runtime Hot-Code Upgrade support for Elixir",
      licenses: ["MIT"],
      links: %{
        "GitHub" => "https://github.com/ausimian/castle",
        "Forecastle" => "https://hex.pm/packages/forecastle"
      }
    ]
  end
end
