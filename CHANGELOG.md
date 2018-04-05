# Changelog

## v0.2.0 (2018-04-05)

* Enhancements
  * support Redshift specific features in migrations including `:diststyle`, `:distkey`, and `:sortkey` table options and `:identity`, `:encode`, and `:unique` column options

## v0.1.0 (2018-04-04)

Initial release

* Adapt the builtin Postgres adapter of Ecto to Redshift's limitations
  * no array type
  * maps are stored as json in `varchar(max)` columns
  * the `:binary_id` and `:uuid` Ecto types are stored in `char(36)` and generated as text
  * no binary type and literal support
  * no aliases in `UPDATE` and `DELETE FROM` statements
  * no `RETURNING`
  * no support for `on_conflict` (except for the default `:raise`)
  * no support for `on_delete` and `on_update` on foreign key definitions
  * no support for `ALTER COLUMN`
  * no support for `CHECK` and `EXCLUDE` constraints
