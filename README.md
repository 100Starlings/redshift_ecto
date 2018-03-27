# RedshiftEcto

[Ecto](https://github.com/elixir-ecto/ecto) Adapter for [AWS Redshift](https://aws.amazon.com/redshift/).

This is aimed to be a Redshift compatibility layer on top Ecto's builtin [Postgres adapter](https://hexdocs.pm/ecto/Ecto.Adapters.Postgres.html). Starting with a basic implementation it delegates most functions to the Postgres adapter. This means that while basic statements and queries will work there will be others that don't. The goal is to fix each of these incompatibilities one at a time as they are discovered.

Documentation can be found at [https://hexdocs.pm/redshift_ecto](https://hexdocs.pm/redshift_ecto).

## Installation

Add `redshift_ecto` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:redshift_ecto, "~> 0.1.0"}
  ]
end
```

### Example configuration

```elixir
config :my_app, MyApp.Repo,
  adapter: RedshiftEcto,
  url: "ecto://user:pass@data-warehouse.abc123.us-east-1.redshift.amazonaws.com:5439/db"
```
