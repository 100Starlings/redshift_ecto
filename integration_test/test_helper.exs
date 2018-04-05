Logger.configure(level: :info)
ExUnit.start()

# Configure Ecto for support and tests
Application.put_env(:ecto, :lock_for_update, "FOR UPDATE")
Application.put_env(:ecto, :primary_key_type, :id)

# Configure connection
Application.put_env(:ecto, :redshift_test_url, "ecto://" <> System.get_env("REDSHIFT_URL"))

# Load support files
Code.require_file("../deps/ecto/integration_test/support/repo.exs", __DIR__)
Code.require_file("../deps/ecto/integration_test/support/schemas.exs", __DIR__)
Code.require_file("support/migration.exs", __DIR__)

pool =
  case System.get_env("ECTO_POOL") || "poolboy" do
    "poolboy" -> DBConnection.Poolboy
    "sbroker" -> DBConnection.Sojourn
  end

# Pool repo for async, safe tests
alias Ecto.Integration.TestRepo

Application.put_env(
  :ecto,
  TestRepo,
  adapter: RedshiftEcto,
  url: Application.get_env(:ecto, :redshift_test_url) <> "/ecto_test",
  pool: EctoReplaySandbox,
  ownership_pool: pool,
  timeout: 30_000,
  pool_timeout: 10_000
)

defmodule Ecto.Integration.TestRepo do
  use Ecto.Integration.Repo, otp_app: :ecto
end

# Pool repo for non-async tests
alias Ecto.Integration.PoolRepo

Application.put_env(
  :ecto,
  PoolRepo,
  adapter: RedshiftEcto,
  pool: pool,
  url: Application.get_env(:ecto, :redshift_test_url) <> "/ecto_test",
  pool_size: 10,
  max_restarts: 20,
  max_seconds: 10,
  timeout: 30_000,
  pool_timeout: 10_000
)

defmodule Ecto.Integration.PoolRepo do
  use Ecto.Integration.Repo, otp_app: :ecto

  def create_prefix(prefix) do
    "create schema #{prefix}"
  end

  def drop_prefix(prefix) do
    "drop schema #{prefix}"
  end
end

defmodule Ecto.Integration.Case do
  use ExUnit.CaseTemplate

  setup do
    :ok = EctoReplaySandbox.checkout(TestRepo)
  end
end

{:ok, _} = RedshiftEcto.ensure_all_started(TestRepo, :temporary)

# Load up the repository, start it, and run migrations
case RedshiftEcto.storage_down(TestRepo.config()) do
  :ok -> :ok
  {:error, :already_down} -> :ok
end

:ok = RedshiftEcto.storage_up(TestRepo.config())

{:ok, _pid} = TestRepo.start_link()
{:ok, _pid} = PoolRepo.start_link()

ExUnit.configure(
  exclude: [
    # :add_column,
    :alter_primary_key,
    :array_type,
    # :assigns_id_type,
    # :composite_pk,
    :create_index_if_not_exists,
    # :decimal_type,
    # :delete_with_join,
    # :foreign_key_constraint,
    # :id_type,
    # :invalid_prefix,
    # :join,
    # :left_join,
    # :map_type,
    :modify_column,
    :modify_foreign_key_on_delete,
    :modify_foreign_key_on_update,
    # :no_primary_key,
    # :prefix,
    # :read_after_writes,
    # :remove_column,
    # :rename_column,
    # :rename_table,
    :returning,
    # :right_join,
    :strict_savepoint,
    :transaction_isolation,
    :unique_constraint,
    # :update_with_join,
    :upsert,
    :upsert_all,
    # :uses_msec,
    # :uses_usec,
    :with_conflict_target,
    :without_conflict_target
  ]
)

:ok = Ecto.Migrator.up(TestRepo, 0, RedshiftEcto.Integration.Migration, log: false)
EctoReplaySandbox.mode(TestRepo, :manual)
Process.flag(:trap_exit, true)
