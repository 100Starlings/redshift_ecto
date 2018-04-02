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

  # Inherit all behaviour from Ecto.Adapters.SQL
  use Ecto.Adapters.SQL, :postgrex

  alias Ecto.Adapters.Postgres

  # And provide a custom storage implementation
  @behaviour Ecto.Adapter.Storage
  @behaviour Ecto.Adapter.Structure

  defdelegate extensions, to: Postgres

  ## Storage API

  @doc false
  def storage_up(opts) do
    database =
      Keyword.fetch!(opts, :database) || raise ":database is nil in repository configuration"

    encoding = opts[:encoding] || "UTF8"
    opts = Keyword.put(opts, :database, "template1")

    command = ~s(CREATE DATABASE "#{database}" ENCODING '#{encoding}')

    case run_query(command, opts) do
      {:ok, _} ->
        :ok

      {:error, "ERROR 42P04 (duplicate_database)" <> _} ->
        {:error, :already_up}

      {:error, error} ->
        {:error, Exception.message(error)}
    end
  end

  @doc false
  def storage_down(opts) do
    database =
      Keyword.fetch!(opts, :database) || raise ":database is nil in repository configuration"

    command = "DROP DATABASE \"#{database}\""
    opts = Keyword.put(opts, :database, "template1")

    case run_query(command, opts) do
      {:ok, _} ->
        :ok

      {:error, "ERROR 3D000 (invalid_catalog_name)" <> _} ->
        {:error, :already_down}

      {:error, error} ->
        {:error, Exception.message(error)}
    end
  end

  @doc false
  def supports_ddl_transaction? do
    true
  end

  defdelegate structure_dump(default, config), to: Postgres
  defdelegate structure_load(default, config), to: Postgres

  ## Helpers

  defp run_query(sql, opts) do
    {:ok, _} = Application.ensure_all_started(:postgrex)

    opts =
      opts
      |> Keyword.drop([:name, :log])
      |> Keyword.put(:pool, DBConnection.Connection)
      |> Keyword.put(:backoff_type, :stop)

    {:ok, pid} = Task.Supervisor.start_link()

    task =
      Task.Supervisor.async_nolink(pid, fn ->
        {:ok, conn} = Postgrex.start_link(opts)

        value = RedshiftEcto.Connection.execute(conn, sql, [], opts)
        GenServer.stop(conn)
        value
      end)

    timeout = Keyword.get(opts, :timeout, 15_000)

    case Task.yield(task, timeout) || Task.shutdown(task) do
      {:ok, {:ok, result}} ->
        {:ok, result}

      {:ok, {:error, error}} ->
        {:error, error}

      {:exit, {%{__struct__: struct} = error, _}}
      when struct in [Postgrex.Error, DBConnection.Error] ->
        {:error, error}

      {:exit, reason} ->
        {:error, RuntimeError.exception(Exception.format_exit(reason))}

      nil ->
        {:error, RuntimeError.exception("command timed out")}
    end
  end
end
