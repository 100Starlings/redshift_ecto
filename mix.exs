defmodule RedshiftEcto.MixProject do
  use Mix.Project

  @version "0.1.0-dev"

  def project do
    [
      app: :redshift_ecto,
      version: @version,
      elixir: "~> 1.6",
      deps: deps(),
      build_per_environment: false,
      build_embedded: Mix.env() == :prod,
      start_permanent: Mix.env() == :prod,

      # Hex
      description: "Ecto Adapter for Redshift based on its built-in Postgres Adapter.",
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
      {:ex_doc, "~> 0.18", only: :dev}
    ]
  end

  defp package do
    [
      maintainers: ["László Bácsi"],
      licenses: ["Apache 2.0"],
      links: %{"GitHub" => repo_url()}
    ]
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
