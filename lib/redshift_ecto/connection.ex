if Code.ensure_loaded?(Postgrex) do
  defmodule RedshiftEcto.Connection do
    @moduledoc false

    alias Ecto.Adapters.Postgres.Connection, as: Postgres

    @default_port 5439
    @behaviour Ecto.Adapters.SQL.Connection

    ## Module and Options

    def child_spec(opts) do
      opts
      |> Keyword.put_new(:port, @default_port)
      |> Keyword.put_new(:types, Ecto.Adapters.Postgres.TypeModule)
      |> Postgrex.child_spec()
    end

    # constraints may be defined but are not enforced by Amazon Redshift
    def to_constraints(%Postgrex.Error{}), do: []

    ## Query

    defdelegate prepare_execute(conn, name, sql, params, opts), to: Postgres
    defdelegate execute(conn, sql_or_query, params, opts), to: Postgres
    defdelegate stream(conn, sql, params, opts), to: Postgres

    defdelegate all(query), to: Postgres
    defdelegate update_all(query), to: Postgres
    defdelegate delete_all(query), to: Postgres
    defdelegate insert(prefix, table, header, rows, on_conflict, returning), to: Postgres
    defdelegate update(prefix, table, fields, filters, returning), to: Postgres
    defdelegate delete(prefix, table, filters, returning), to: Postgres

    ## DDL

    defdelegate execute_ddl(command), to: Postgres
  end
end
