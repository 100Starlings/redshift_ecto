defmodule RedshiftEcto do
  @moduledoc """
  Adapter module for Redshift.

  It uses `postgrex` for communicating to the database and a connection pool,
  such as `poolboy`.

  This adapter is built on top of Ecto's builtin `Ecto.Adapters.Postgres`
  adapter. It delegates most functions to it only changing the implementation
  of those that are incompatible with Redshift. The differences are detailed in
  this documentation.

  We also recommend developers to consult the documentation of the
  [Postgres adapter](https://hexdocs.pm/ecto/Ecto.Adapters.Postgres.html).
  """
end
