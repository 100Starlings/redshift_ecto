# RedshiftEcto

[Ecto](https://github.com/elixir-ecto/ecto) Adapter for [AWS Redshift](https://aws.amazon.com/redshift/).

This adapter is based on Ecto's builtin [Postgres adapter](https://hexdocs.pm/ecto/Ecto.Adapters.Postgres.html). It delegates some functions to it but changes the implementation of most that are incompatible with Redshift. The differences are detailed in the documentation.

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

## Testing

Redshift doesn't support nested transactions which makes the builtin sandbox implementation of Ecto unusable for testing. RedshiftEcto depends on [ecto_replay_sandbox](https://github.com/jumpn/ecto_replay_sandbox) which implements pseudo transactions that provides a similar experience in testing to the Ecto's sandbox. See the integration tests of the adapter for an example on how to use it.
