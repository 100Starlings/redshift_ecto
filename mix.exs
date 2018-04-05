defmodule RedshiftEcto.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :redshift_ecto,
      version: @version,
      elixir: "~> 1.6",
      deps: deps(),
      build_per_environment: false,
      build_embedded: Mix.env() == :prod,
      start_permanent: Mix.env() == :prod,

      # Testing
      test_paths: test_paths(Mix.env()),
      aliases: ["test.all": ["test", "test.integration"], "test.integration": &test_integration/1],
      preferred_cli_env: ["test.all": :test],

      # Hex
      description: "Ecto Adapter for Redshift.",
      package: package(),

      # Docs
      name: "RedshiftEcto",
      docs: docs()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:ecto, "~> 2.2"},
      {:postgrex, "~> 0.13"},
      {:ecto_replay_sandbox, "~> 1.0.0"},
      {:ex_doc, "~> 0.18", only: :dev, runtime: false},
      {:poison, "~> 2.2 or ~> 3.0", optional: true}
    ]
  end

  defp package do
    [
      maintainers: ["László Bácsi"],
      licenses: ["Apache 2.0"],
      links: %{"GitHub" => repo_url()}
    ]
  end

  defp test_paths(:integration), do: ["integration_test"]
  defp test_paths(_), do: ["test"]

  defp test_integration(args) do
    args = if IO.ANSI.enabled?(), do: ["--color" | args], else: ["--no-color" | args]

    IO.puts("==> Running tests for MIX_ENV=integration mix test")

    {_, res} =
      System.cmd(
        "mix",
        ["test" | args],
        into: IO.binstream(:stdio, :line),
        env: [{"MIX_ENV", "integration"}]
      )

    if res > 0 do
      System.at_exit(fn _ -> exit({:shutdown, 1}) end)
    end
  end

  defp docs do
    [
      main: "RedshiftEcto",
      canonical: "https://hexdocs.pm/redshift_ecto",
      source_url: repo_url()
    ]
  end

  defp repo_url do
    "https://github.com/100Starlings/redshift_ecto"
  end
end
