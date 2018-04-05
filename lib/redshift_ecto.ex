defmodule RedshiftEcto do
  @moduledoc """
  Ecto adapter for [AWS Redshift](https://aws.amazon.com/redshift/).

  It uses `Postgrex` for communicating to the database and a connection pool,
  such as `DBConnection.Poolboy`.

  This adapter is based on Ecto's builtin `Ecto.Adapters.Postgres` adapter. It
  delegates some functions to it but changes the implementation of most that
  are incompatible with Redshift. The differences are detailed in this
  documentation.

  We also recommend developers to consult the documentation of the
  [Postgres adapter](https://hexdocs.pm/ecto/Ecto.Adapters.Postgres.html).

  ## Notable differences

  * no array type
  * maps are stored as json in `varchar(max)` columns
  * the `:binary_id` and `:uuid` Ecto types are stored in `char(36)` and
    generated as text
  * no binary type and literal support
  * no aliases in `UPDATE` and `DELETE FROM` statements
  * no `RETURNING`
  * no support for `on_conflict` (except for the default `:raise`)
  * no support for `on_delete` and `on_update` on foreign key definitions
  * no support for `ALTER COLUMN`
  * no support for `CHECK` and `EXCLUDE` constraints
  * since Redshift doesn't enforce uniqueness and foreign key constraints the
    adapter can't report violations

  ## Migrations

  RedshiftEcto supports migrations with the exceptions of features that are not
  supported by Redshift (see above). There are also some extra features in
  migrations to help specify table attributes and column options available in
  Redshift.

  We highly recommend reading the
  [Designing Tables](https://docs.aws.amazon.com/redshift/latest/dg/t_Creating_tables.html)
  section from the AWS Redshift documentation.

  ### Table options

  While similarly to other adapters RedshiftEcto accepts table options as an
  opaque string, it also supports a keyword list with the following options:

  * `:diststyle`: data distribution style, possible values: `:even`, `:key`, `:all`
  * `:distkey`: specify the column to be used as the distribution key
  * `:sortkey`: specify one or more sort keys, the value can be a single column
    name, a list of columns, or a 2-tuple where the first element is a sort
    style specifier (`:compound` or `:interleaved`) and the second is a single
    column name or a list of columns

  #### Examples

      create table("posts", options: [distkey: :id, sortkey: :title])
      create table("categories", options: [diststyle: :all, sortkey: {:interleaved, [:name, :parent_id]}])
      create table("reports", options: [diststyle: :even, sortkey: [:department, :year, :month]])

  ### Column options

  In addition to the column options accepted by `Ecto.Migration.add/3`
  RedshiftEcto also accepts the following Redshift specific column options:

  * `:identity`: specifies that the column is an identity column. The value must
    be a tuple of two integers where the first is the `seed` and the second the
    `step`. For example, `identity: {0, 1}` specifies that the values start from
    `0` and increments by `1`. It's worth noting that identity columns may
    behave differently in Redshift that one might be used to. See the [AWS
    Redshift docs][identity] for more details.
  * `:encode`: compression encoding for the column, possible values are lower
    case atom version of the compression encodings supported by Redshift. Some
    common values: `:zstd`, `:lzo`, `:delta`, `:bytedict`, `:raw`. See the [AWS
    Redshift docs][encodings] for more.
  * `:distkey`: specify the column as the distribution key (value must be `true`)
  * `:sortkey`: specify the column as the single (compound) sort key of the table
    (value must be `true`)
  * `:unique`: specify that the column can contain only unique values. Note that
    Redshift won't enforce uniqueness.

  [identity]: https://docs.aws.amazon.com/redshift/latest/dg/r_CREATE_TABLE_NEW.html#identity-clause
  [encodings]: https://docs.aws.amazon.com/redshift/latest/dg/c_Compression_encodings.html

  #### Examples

      create table("posts") do
        add :id, :serial, primary_key: true, distkey: true, encode: :delta
        add :title, :string, size: 765, null: false, unique: true, sortkey: true, encode: :lzo
        add :counter, :serial, identity: {0, 1}, encode: :delta,
        add :views, :smallint, default: 0, encode: :mostly8,
        add :author, :string, default: "anonymous", encode: :text255,
        add :created_at, :naive_datetime, encode: :zstd
      end
  """

  # Inherit all behaviour from Ecto.Adapters.SQL
  use Ecto.Adapters.SQL, :postgrex

  alias Ecto.Adapters.Postgres

  # And provide a custom storage implementation
  @behaviour Ecto.Adapter.Storage
  @behaviour Ecto.Adapter.Structure

  defdelegate extensions, to: Postgres

  ## Custom Redshift types

  @doc false
  def autogenerate(:id), do: nil
  def autogenerate(:embed_id), do: Ecto.UUID.generate()
  def autogenerate(:binary_id), do: Ecto.UUID.generate()

  @doc false
  def loaders(:map, type), do: [&json_decode/1, type]
  def loaders({:map, _}, type), do: [&json_decode/1, type]

  def loaders({:embed, _} = type, _) do
    [&json_decode/1, &Ecto.Adapters.SQL.load_embed(type, &1)]
  end

  def loaders(:binary_id, _type), do: [&{:ok, &1}]
  def loaders(:uuid, Ecto.UUID), do: [&{:ok, &1}]
  def loaders(_, type), do: [type]

  defp json_decode(x) when is_binary(x) do
    {:ok, Ecto.Adapter.json_library().decode!(x)}
  end

  defp json_decode(x), do: {:ok, x}

  @doc false
  def dumpers(:map, type), do: [type, &json_encode/1]
  def dumpers({:map, _}, type), do: [type, &json_encode/1]

  def dumpers({:embed, _} = type, _) do
    [&Ecto.Adapters.SQL.dump_embed(type, &1), &json_encode/1]
  end

  def dumpers(:binary_id, _type), do: [&Ecto.UUID.cast/1]
  def dumpers(:uuid, Ecto.UUID), do: [&Ecto.UUID.cast/1]
  def dumpers(_, type), do: [type]

  defp json_encode(%{} = x) do
    {:ok, Ecto.Adapter.json_library().encode!(x)}
  end

  defp json_encode(x), do: {:ok, x}

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

      {:error, %{postgres: %{code: :duplicate_database}}} ->
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

      {:error, %{postgres: %{code: :invalid_catalog_name}}} ->
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
