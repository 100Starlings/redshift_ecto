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

    alias Ecto.Query
    alias Ecto.Query.{BooleanExpr, JoinExpr, QueryExpr}

    def all(query) do
      sources = create_names(query)
      {select_distinct, order_by_distinct} = distinct(query.distinct, sources, query)

      from = from(query, sources)
      select = select(query, select_distinct, sources)
      join = join(query, sources)
      where = where(query, sources)
      group_by = group_by(query, sources)
      having = having(query, sources)
      order_by = order_by(query, order_by_distinct, sources)
      limit = limit(query, sources)
      offset = offset(query, sources)
      lock = lock(query.lock)

      [select, from, join, where, group_by, having, order_by, limit, offset | lock]
    end

    def update_all(%{from: from, select: nil} = query) do
      sources = sources_unaliased(query)
      {from, _} = get_source(query, sources, 0, from)

      fields = update_fields(query, sources)
      {join, wheres} = using_join(query, :update_all, "FROM", sources)
      where = where(%{query | wheres: wheres ++ query.wheres}, sources)

      ["UPDATE ", from, " SET ", fields, join, where]
    end

    def update_all(_query) do
      error!(nil, "RETURNING is not supported by Redshift")
    end

    def update(prefix, table, fields, filters, []) do
      {fields, count} =
        intersperse_reduce(fields, ", ", 1, fn field, acc ->
          {[quote_name(field), " = $" | Integer.to_string(acc)], acc + 1}
        end)

      {filters, _count} =
        intersperse_reduce(filters, " AND ", count, fn field, acc ->
          {[quote_name(field), " = $" | Integer.to_string(acc)], acc + 1}
        end)

      ["UPDATE ", quote_table(prefix, table), " SET ", fields, " WHERE " | filters]
    end

    def update(_prefix, _table, _fields, _filters, _returning) do
      error!(nil, "RETURNING is not supported by Redshift")
    end

    def delete_all(%{from: from, select: nil} = query) do
      sources = sources_unaliased(query)
      {from, _} = get_source(query, sources, 0, from)

      {join, wheres} = using_join(query, :delete_all, "USING", sources)
      where = where(%{query | wheres: wheres ++ query.wheres}, sources)

      ["DELETE FROM ", from, join, where]
    end

    def delete_all(_query) do
      error!(nil, "RETURNING is not supported by Redshift")
    end

    def delete(prefix, table, filters, []) do
      {filters, _} =
        intersperse_reduce(filters, " AND ", 1, fn field, acc ->
          {[quote_name(field), " = $" | Integer.to_string(acc)], acc + 1}
        end)

      ["DELETE FROM ", quote_table(prefix, table), " WHERE " | filters]
    end

    def delete(_prefix, _table, _filters, _returning) do
      error!(nil, "RETURNING is not supported by Redshift")
    end

    def insert(prefix, table, header, rows, {:raise, _, []}, []) do
      values =
        if header == [] do
          [" VALUES " | intersperse_map(rows, ?,, fn _ -> "(DEFAULT)" end)]
        else
          [?\s, ?(, intersperse_map(header, ?,, &quote_name/1), ") VALUES " | insert_all(rows, 1)]
        end

      ["INSERT INTO ", quote_table(prefix, table) | values]
    end

    def insert(_prefix, _table, _header, _rows, _on_conflict, []) do
      error!(nil, "ON CONFLICT is not supported by Redshift")
    end

    def insert(_prefix, _table, _header, _rows, _on_conflict, _returning) do
      error!(nil, "RETURNING is not supported by Redshift")
    end

    defp insert_all(rows, counter) do
      intersperse_reduce(rows, ?,, counter, fn row, counter ->
        {row, counter} = insert_each(row, counter)
        {[?(, row, ?)], counter}
      end)
      |> elem(0)
    end

    defp insert_each(values, counter) do
      intersperse_reduce(values, ?,, counter, fn
        nil, counter ->
          {"DEFAULT", counter}

        _, counter ->
          {[?$ | Integer.to_string(counter)], counter + 1}
      end)
    end

    ## Query generation

    binary_ops = [
      ==: " = ",
      !=: " != ",
      <=: " <= ",
      >=: " >= ",
      <: " < ",
      >: " > ",
      and: " AND ",
      or: " OR ",
      ilike: " ILIKE ",
      like: " LIKE "
    ]

    @binary_ops Keyword.keys(binary_ops)

    Enum.map(binary_ops, fn {op, str} ->
      defp handle_call(unquote(op), 2), do: {:binary_op, unquote(str)}
    end)

    defp handle_call(fun, _arity), do: {:fun, Atom.to_string(fun)}

    defp select(%Query{select: %{fields: fields}} = query, select_distinct, sources) do
      ["SELECT", select_distinct, ?\s | select_fields(fields, sources, query)]
    end

    defp select_fields([], _sources, _query), do: "TRUE"

    defp select_fields(fields, sources, query) do
      intersperse_map(fields, ", ", fn
        {key, value} ->
          [expr(value, sources, query), " AS " | quote_name(key)]

        value ->
          expr(value, sources, query)
      end)
    end

    defp distinct(nil, _, _), do: {[], []}
    defp distinct(%QueryExpr{expr: []}, _, _), do: {[], []}
    defp distinct(%QueryExpr{expr: true}, _, _), do: {" DISTINCT", []}
    defp distinct(%QueryExpr{expr: false}, _, _), do: {[], []}

    defp distinct(%QueryExpr{expr: exprs}, sources, query) do
      {[
         " DISTINCT ON (",
         intersperse_map(exprs, ", ", fn {_, expr} -> expr(expr, sources, query) end),
         ?)
       ], exprs}
    end

    defp from(%{from: from} = query, sources) do
      {from, name} = get_source(query, sources, 0, from)
      [" FROM ", from, " AS " | name]
    end

    defp update_fields(%Query{updates: updates} = query, sources) do
      for(
        %{expr: expr} <- updates,
        {op, kw} <- expr,
        {key, value} <- kw,
        do: update_op(op, key, value, sources, query)
      )
      |> Enum.intersperse(", ")
    end

    defp update_op(:set, key, value, sources, query) do
      [quote_name(key), " = " | expr(value, sources, query)]
    end

    defp update_op(:inc, key, value, sources, query) do
      [
        quote_name(key),
        " = ",
        quote_qualified_name(key, sources, 0),
        " + "
        | expr(value, sources, query)
      ]
    end

    defp update_op(command, _key, _value, _sources, query) do
      error!(query, "Unknown update operation #{inspect(command)} for Redshift")
    end

    defp using_join(%Query{joins: []}, _kind, _prefix, _sources), do: {[], []}

    defp using_join(%Query{joins: joins} = query, kind, prefix, sources) do
      froms =
        intersperse_map(joins, ", ", fn
          %JoinExpr{qual: :inner, ix: ix, source: source} ->
            {join, _} = get_source(query, sources, ix, source)
            join

          %JoinExpr{qual: qual} ->
            error!(query, "Redshift supports only inner joins on #{kind}, got: `#{qual}`")
        end)

      wheres =
        for %JoinExpr{on: %QueryExpr{expr: value} = expr} <- joins,
            value != true,
            do: expr |> Map.put(:__struct__, BooleanExpr) |> Map.put(:op, :and)

      {[?\s, prefix, ?\s | froms], wheres}
    end

    defp join(%Query{joins: []}, _sources), do: []

    defp join(%Query{joins: joins} = query, sources) do
      [
        ?\s
        | intersperse_map(joins, ?\s, fn %JoinExpr{
                                           on: %QueryExpr{expr: expr},
                                           qual: qual,
                                           ix: ix,
                                           source: source
                                         } ->
            {join, name} = get_source(query, sources, ix, source)
            [join_qual(qual), join, " AS ", name, " ON " | expr(expr, sources, query)]
          end)
      ]
    end

    defp join_qual(:inner), do: "INNER JOIN "
    defp join_qual(:inner_lateral), do: "INNER JOIN LATERAL "
    defp join_qual(:left), do: "LEFT OUTER JOIN "
    defp join_qual(:left_lateral), do: "LEFT OUTER JOIN LATERAL "
    defp join_qual(:right), do: "RIGHT OUTER JOIN "
    defp join_qual(:full), do: "FULL OUTER JOIN "
    defp join_qual(:cross), do: "CROSS JOIN "

    defp where(%Query{wheres: wheres} = query, sources) do
      boolean(" WHERE ", wheres, sources, query)
    end

    defp having(%Query{havings: havings} = query, sources) do
      boolean(" HAVING ", havings, sources, query)
    end

    defp group_by(%Query{group_bys: []}, _sources), do: []

    defp group_by(%Query{group_bys: group_bys} = query, sources) do
      [
        " GROUP BY "
        | intersperse_map(group_bys, ", ", fn %QueryExpr{expr: expr} ->
            intersperse_map(expr, ", ", &expr(&1, sources, query))
          end)
      ]
    end

    defp order_by(%Query{order_bys: []}, _distinct, _sources), do: []

    defp order_by(%Query{order_bys: order_bys} = query, distinct, sources) do
      order_bys = Enum.flat_map(order_bys, & &1.expr)

      [
        " ORDER BY "
        | intersperse_map(distinct ++ order_bys, ", ", &order_by_expr(&1, sources, query))
      ]
    end

    defp order_by_expr({dir, expr}, sources, query) do
      str = expr(expr, sources, query)

      case dir do
        :asc -> str
        :desc -> [str | " DESC"]
      end
    end

    defp limit(%Query{limit: nil}, _sources), do: []

    defp limit(%Query{limit: %QueryExpr{expr: expr}} = query, sources) do
      [" LIMIT " | expr(expr, sources, query)]
    end

    defp offset(%Query{offset: nil}, _sources), do: []

    defp offset(%Query{offset: %QueryExpr{expr: expr}} = query, sources) do
      [" OFFSET " | expr(expr, sources, query)]
    end

    defp lock(nil), do: []
    defp lock(lock_clause), do: [?\s | lock_clause]

    defp boolean(_name, [], _sources, _query), do: []

    defp boolean(name, [%{expr: expr, op: op} | query_exprs], sources, query) do
      [
        name
        | Enum.reduce(query_exprs, {op, paren_expr(expr, sources, query)}, fn
            %BooleanExpr{expr: expr, op: op}, {op, acc} ->
              {op, [acc, operator_to_boolean(op), paren_expr(expr, sources, query)]}

            %BooleanExpr{expr: expr, op: op}, {_, acc} ->
              {op, [?(, acc, ?), operator_to_boolean(op), paren_expr(expr, sources, query)]}
          end)
          |> elem(1)
      ]
    end

    defp operator_to_boolean(:and), do: " AND "
    defp operator_to_boolean(:or), do: " OR "

    defp paren_expr(expr, sources, query) do
      [?(, expr(expr, sources, query), ?)]
    end

    defp expr({:^, [], [ix]}, _sources, _query) do
      [?$ | Integer.to_string(ix + 1)]
    end

    defp expr({{:., _, [{:&, _, [idx]}, field]}, _, []}, sources, _query) when is_atom(field) do
      quote_qualified_name(field, sources, idx)
    end

    defp expr({:&, _, [idx]}, sources, query) do
      {source, _name, _schema} = elem(sources, idx)

      error!(
        query,
        "Redshift does not support selecting all fields from #{source} without a schema. " <>
          "Please specify a schema or specify exactly which fields you want to select"
      )
    end

    defp expr({:in, _, [_left, []]}, _sources, _query) do
      "false"
    end

    defp expr({:in, _, [left, right]}, sources, query) when is_list(right) do
      args = intersperse_map(right, ?,, &expr(&1, sources, query))
      [expr(left, sources, query), " IN (", args, ?)]
    end

    defp expr({:in, _, [_, {:^, _, [_, 0]}]}, _sources, _query) do
      "false"
    end

    defp expr({:in, _, [left, {:^, _, [ix, length]}]}, sources, query) do
      args = (ix + 1)..(ix + length) |> Enum.map(&"$#{&1}") |> Enum.intersperse(?,)
      [expr(left, sources, query), " IN (", args, ?)]
    end

    defp expr({:in, _, [left, right]}, sources, query) do
      [expr(left, sources, query), " IN ", paren_expr(right, sources, query)]
    end

    defp expr({:is_nil, _, [arg]}, sources, query) do
      [expr(arg, sources, query) | " IS NULL"]
    end

    defp expr({:not, _, [expr]}, sources, query) do
      ["NOT (", expr(expr, sources, query), ?)]
    end

    defp expr(%Ecto.SubQuery{query: query}, _sources, _query) do
      all(query)
    end

    defp expr({:fragment, _, [kw]}, _sources, query) when is_list(kw) or tuple_size(kw) == 3 do
      error!(query, "Redshift adapter does not support keyword or interpolated fragments")
    end

    defp expr({:fragment, _, parts}, sources, query) do
      Enum.map(parts, fn
        {:raw, part} -> part
        {:expr, expr} -> expr(expr, sources, query)
      end)
    end

    defp expr({:datetime_add, _, [datetime, count, interval]}, sources, query) do
      [
        ?(,
        expr(datetime, sources, query),
        "::timestamp + ",
        interval(count, interval, sources, query) | ")::timestamp"
      ]
    end

    defp expr({:date_add, _, [date, count, interval]}, sources, query) do
      [
        ?(,
        expr(date, sources, query),
        "::date + ",
        interval(count, interval, sources, query) | ")::date"
      ]
    end

    defp expr({fun, _, args}, sources, query) when is_atom(fun) and is_list(args) do
      {modifier, args} =
        case args do
          [rest, :distinct] -> {"DISTINCT ", [rest]}
          _ -> {[], args}
        end

      case handle_call(fun, length(args)) do
        {:binary_op, op} ->
          [left, right] = args
          [op_to_binary(left, sources, query), op | op_to_binary(right, sources, query)]

        {:fun, fun} ->
          [fun, ?(, modifier, intersperse_map(args, ", ", &expr(&1, sources, query)), ?)]
      end
    end

    defp expr(list, _sources, query) when is_list(list) do
      error!(query, "Array type is not supported by Redshift")
    end

    defp expr(%Decimal{} = decimal, _sources, _query) do
      Decimal.to_string(decimal, :normal)
    end

    defp expr(%Ecto.Query.Tagged{value: binary, type: :binary}, _sources, query)
         when is_binary(binary) do
      error!(query, "The Redshift Adapter doesn't support binaries")
    end

    defp expr(%Ecto.Query.Tagged{value: other, type: type}, sources, query) do
      [expr(other, sources, query), ?:, ?: | tagged_to_db(type)]
    end

    defp expr(nil, _sources, _query), do: "NULL"
    defp expr(true, _sources, _query), do: "TRUE"
    defp expr(false, _sources, _query), do: "FALSE"

    defp expr(literal, _sources, _query) when is_binary(literal) do
      [?\', escape_string(literal), ?\']
    end

    defp expr(literal, _sources, _query) when is_integer(literal) do
      Integer.to_string(literal)
    end

    defp expr(literal, _sources, _query) when is_float(literal) do
      [Float.to_string(literal) | "::float"]
    end

    # Always use the largest possible type for integers
    defp tagged_to_db(:id), do: "bigint"
    defp tagged_to_db(:integer), do: "bigint"
    defp tagged_to_db(type), do: ecto_to_db(type)

    defp interval(count, interval, _sources, _query) when is_integer(count) do
      ["interval '", String.Chars.Integer.to_string(count), ?\s, interval, ?\']
    end

    defp interval(count, interval, _sources, _query) when is_float(count) do
      count = :erlang.float_to_binary(count, [:compact, decimals: 16])
      ["interval '", count, ?\s, interval, ?\']
    end

    defp interval(count, interval, sources, query) do
      [?(, expr(count, sources, query), "::numeric * ", interval(1, interval, sources, query), ?)]
    end

    defp op_to_binary({op, _, [_, _]} = expr, sources, query) when op in @binary_ops do
      paren_expr(expr, sources, query)
    end

    defp op_to_binary(expr, sources, query) do
      expr(expr, sources, query)
    end

    defp sources_unaliased(%{prefix: prefix, sources: sources}) do
      sources_unaliased(prefix, sources, 0, tuple_size(sources)) |> List.to_tuple()
    end

    defp sources_unaliased(prefix, sources, pos, limit) when pos < limit do
      current =
        case elem(sources, pos) do
          {table, schema, _alias} ->
            quoted = quote_table(prefix, table)
            {quoted, quoted, schema}

          {:fragment, _, _} ->
            error!(
              nil,
              "Redshift doesn't support fragment sources in UPDATE and DELETE statements"
            )

          %Ecto.SubQuery{} ->
            error!(
              nil,
              "Redshift doesn't support subquery sources in UPDATE and DELETE statements"
            )
        end

      [current | sources_unaliased(prefix, sources, pos + 1, limit)]
    end

    defp sources_unaliased(_prefix, _sources, pos, pos) do
      []
    end

    defp create_names(%{prefix: prefix, sources: sources}) do
      create_names(prefix, sources, 0, tuple_size(sources)) |> List.to_tuple()
    end

    defp create_names(prefix, sources, pos, limit) when pos < limit do
      current =
        case elem(sources, pos) do
          {table, schema, _alias} ->
            name = [create_alias(table) | Integer.to_string(pos)]
            {quote_table(prefix, table), name, schema}

          {:fragment, _, _} ->
            {nil, [?f | Integer.to_string(pos)], nil}

          %Ecto.SubQuery{} ->
            {nil, [?s | Integer.to_string(pos)], nil}
        end

      [current | create_names(prefix, sources, pos + 1, limit)]
    end

    defp create_names(_prefix, _sources, pos, pos), do: []

    defp create_alias(<<first, _rest::binary>>) when first in ?a..?z when first in ?A..?Z do
      <<first>>
    end

    defp create_alias(_), do: "t"

    ## DDL

    alias Ecto.Migration.{Table, Index, Reference, Constraint}

    @drops [:drop, :drop_if_exists]

    def execute_ddl({command, %Table{} = table, columns})
        when command in [:create, :create_if_not_exists] do
      table_name = quote_table(table.prefix, table.name)

      query = [
        "CREATE TABLE ",
        if_do(command == :create_if_not_exists, "IF NOT EXISTS "),
        table_name,
        ?\s,
        ?(,
        column_definitions(table, columns),
        pk_definition(columns, ", "),
        ?),
        options_expr(table.options)
      ]

      [query] ++
        comments_on("TABLE", table_name, table.comment) ++
        comments_for_columns(table_name, columns)
    end

    def execute_ddl({command, %Table{} = table}) when command in @drops do
      [
        [
          "DROP TABLE ",
          if_do(command == :drop_if_exists, "IF EXISTS "),
          quote_table(table.prefix, table.name)
        ]
      ]
    end

    # TODO: split multiple changes into multiple queries as Redshift doesn't
    # support more than one change in a single ALTER TABLE
    def execute_ddl({:alter, %Table{} = table, changes}) do
      table_name = quote_table(table.prefix, table.name)

      query = [
        "ALTER TABLE ",
        table_name,
        ?\s,
        column_changes(table, changes),
        pk_definition(changes, ", ADD ")
      ]

      [query] ++
        comments_on("TABLE", table_name, table.comment) ++
        comments_for_columns(table_name, changes)
    end

    def execute_ddl({_command, %Index{} = _index}) do
      error!(nil, "CREATE INDEX and DROP INDEX are not supported by Redshift")
    end

    def execute_ddl({:rename, %Table{} = current_table, %Table{} = new_table}) do
      [
        [
          "ALTER TABLE ",
          quote_table(current_table.prefix, current_table.name),
          " RENAME TO ",
          quote_table(nil, new_table.name)
        ]
      ]
    end

    def execute_ddl({:rename, %Table{} = table, current_column, new_column}) do
      [
        [
          "ALTER TABLE ",
          quote_table(table.prefix, table.name),
          " RENAME ",
          quote_name(current_column),
          " TO ",
          quote_name(new_column)
        ]
      ]
    end

    def execute_ddl({:create, %Constraint{}}) do
      error!(nil, "CHECK and EXCLUDE constraints are not supported by Redshift")
    end

    def execute_ddl({:drop, %Constraint{} = constraint}) do
      [
        [
          "ALTER TABLE ",
          quote_table(constraint.prefix, constraint.table),
          " DROP CONSTRAINT ",
          quote_name(constraint.name)
        ]
      ]
    end

    def execute_ddl(string) when is_binary(string), do: [string]

    def execute_ddl(keyword) when is_list(keyword),
      do: error!(nil, "PostgreSQL adapter does not support keyword lists in execute")

    defp pk_definition(columns, prefix) do
      pks = for {_, name, _, opts} <- columns, opts[:primary_key], do: name

      case pks do
        [] -> []
        _ -> [prefix, "PRIMARY KEY (", intersperse_map(pks, ", ", &quote_name/1), ")"]
      end
    end

    defp comments_on(_object, _name, nil), do: []

    defp comments_on(object, name, comment) do
      [["COMMENT ON ", object, ?\s, name, " IS ", single_quote(comment)]]
    end

    defp comments_for_columns(table_name, columns) do
      Enum.flat_map(columns, fn
        {_operation, column_name, _column_type, opts} ->
          column_name = [table_name, ?. | quote_name(column_name)]
          comments_on("COLUMN", column_name, opts[:comment])

        _ ->
          []
      end)
    end

    defp column_definitions(table, columns) do
      intersperse_map(columns, ", ", &column_definition(table, &1))
    end

    defp column_definition(table, {:add, name, %Reference{} = ref, opts}) do
      [
        quote_name(name),
        ?\s,
        reference_column_type(ref.type, opts),
        column_options(ref.type, opts),
        reference_expr(ref, table, name)
      ]
    end

    defp column_definition(_table, {:add, name, type, opts}) do
      [quote_name(name), ?\s, column_type(type, opts), column_options(type, opts)]
    end

    defp column_changes(table, columns) do
      intersperse_map(columns, ", ", &column_change(table, &1))
    end

    defp column_change(table, {:add, name, %Reference{} = ref, opts}) do
      [
        "ADD COLUMN ",
        quote_name(name),
        ?\s,
        reference_column_type(ref.type, opts),
        column_options(ref.type, opts),
        reference_expr(ref, table, name)
      ]
    end

    defp column_change(_table, {:add, name, type, opts}) do
      ["ADD COLUMN ", quote_name(name), ?\s, column_type(type, opts), column_options(type, opts)]
    end

    defp column_change(table, {:modify, name, %Reference{} = ref, _opts}) do
      constraint_expr(ref, table, name)
    end

    defp column_change(_table, {:modify, _name, _type, _opts}) do
      error!(nil, "ALTER COLUMN is not supported by Redshift")
    end

    defp column_change(_table, {:remove, name}), do: ["DROP COLUMN ", quote_name(name)]

    defp column_options(type, opts) do
      default = Keyword.fetch(opts, :default)

      {opts, _rest} =
        Keyword.split(opts, [:identity, :encode, :distkey, :sortkey, :null, :unique])

      [default_expr(default, type), Enum.map(opts, &column_option/1)]
    end

    @compression_encodings [
      :raw,
      :bytedict,
      :delta,
      :delta32k,
      :lzo,
      :mostly8,
      :mostly16,
      :mostly32,
      :runlength,
      :text255,
      :text32k,
      :zstd
    ]

    defp column_option({:encode, encoding}) when encoding in @compression_encodings do
      [" ENCODE ", to_string(encoding)]
    end

    defp column_option({:identity, {seed, step}}) when is_integer(seed) and is_integer(step) do
      [" IDENTITY(", to_string(seed), ?,, to_string(step), ?)]
    end

    defp column_option({:distkey, true}), do: " DISTKEY"
    defp column_option({:sortkey, true}), do: " SORTKEY"
    defp column_option({:null, false}), do: " NOT NULL"
    defp column_option({:null, true}), do: " NULL"
    defp column_option({:unique, true}), do: " UNIQUE"

    defp column_option(expr) do
      error!(nil, "unrecognized column option `#{inspect(expr)}`")
    end

    defp default_expr({:ok, nil}, _type), do: " DEFAULT NULL"

    defp default_expr({:ok, literal}, _type) when is_binary(literal),
      do: [" DEFAULT '", escape_string(literal), ?']

    defp default_expr({:ok, literal}, _type) when is_number(literal) or is_boolean(literal),
      do: [" DEFAULT ", to_string(literal)]

    defp default_expr({:ok, %{} = map}, :map) do
      default = json_library().encode!(map)
      [" DEFAULT ", single_quote(default)]
    end

    defp default_expr({:ok, {:fragment, expr}}, _type), do: [" DEFAULT ", expr]

    defp default_expr({:ok, expr}, type),
      do:
        raise(
          ArgumentError,
          "unknown default `#{inspect(expr)}` for type `#{inspect(type)}`. " <>
            ":default may be a string, number, boolean, map (when type is Map), or a fragment(...)"
        )

    defp default_expr(:error, _), do: []

    defp options_expr(nil), do: []
    defp options_expr(keyword) when is_list(keyword), do: Enum.map(keyword, &table_attribute/1)
    defp options_expr(options), do: [?\s, options]

    defp table_attribute({:diststyle, :even}), do: " DISTSTYLE EVEN"
    defp table_attribute({:diststyle, :all}), do: " DISTSTYLE ALL"
    defp table_attribute({:diststyle, :key}), do: " DISTSTYLE KEY"

    defp table_attribute({:distkey, key}) when is_atom(key) or is_binary(key) do
      [" DISTKEY (", quote_name(key), ?)]
    end

    defp table_attribute({:sortkey, key}) when is_atom(key) or is_binary(key) do
      [" SORTKEY (", quote_name(key), ?)]
    end

    defp table_attribute({:sortkey, keys}) when is_list(keys) do
      [" SORTKEY (", intersperse_map(keys, ", ", &quote_name/1), ?)]
    end

    defp table_attribute({:sortkey, {:compound, keys}}) do
      [" COMPOUND", table_attribute({:sortkey, keys})]
    end

    defp table_attribute({:sortkey, {:interleaved, keys}}) do
      [" INTERLEAVED", table_attribute({:sortkey, keys})]
    end

    defp table_attribute(table_attribute) do
      error!(nil, "unrecognized table attribute `#{inspect(table_attribute)}`")
    end

    defp column_type(type, opts) do
      size = Keyword.get(opts, :size)
      precision = Keyword.get(opts, :precision)
      scale = Keyword.get(opts, :scale)
      type_name = ecto_to_db(type)

      cond do
        size -> [type_name, ?(, to_string(size), ?)]
        precision -> [type_name, ?(, to_string(precision), ?,, to_string(scale || 0), ?)]
        type == :string -> [type_name, "(255)"]
        true -> type_name
      end
    end

    defp reference_expr(%Reference{on_delete: :nothing, on_update: :nothing} = ref, table, name),
      do: [
        " CONSTRAINT ",
        reference_name(ref, table, name),
        " REFERENCES ",
        quote_table(table.prefix, ref.table),
        ?(,
        quote_name(ref.column),
        ?)
      ]

    defp reference_expr(%Reference{on_delete: :nothing}, _table, _name),
      do: error!(nil, "ON UPDATE is not supported by Redshift")

    defp reference_expr(%Reference{}, _table, _name),
      do: error!(nil, "ON DELETE is not supported by Redshift")

    defp constraint_expr(%Reference{on_delete: :nothing, on_update: :nothing} = ref, table, name),
      do: [
        "ADD CONSTRAINT ",
        reference_name(ref, table, name),
        ?\s,
        "FOREIGN KEY (",
        quote_name(name),
        ") REFERENCES ",
        quote_table(table.prefix, ref.table),
        ?(,
        quote_name(ref.column),
        ?)
      ]

    defp constraint_expr(%Reference{on_delete: :nothing}, _table, _name),
      do: error!(nil, "ON UPDATE is not supported by Redshift")

    defp constraint_expr(%Reference{}, _table, _name),
      do: error!(nil, "ON DELETE is not supported by Redshift")

    defp reference_name(%Reference{name: nil}, table, column),
      do: quote_name("#{table.name}_#{column}_fkey")

    defp reference_name(%Reference{name: name}, _table, _column), do: quote_name(name)

    defp reference_column_type(:serial, _opts), do: "integer"
    defp reference_column_type(:bigserial, _opts), do: "bigint"
    defp reference_column_type(type, opts), do: column_type(type, opts)

    ## Helpers

    defp get_source(query, sources, ix, source) do
      {expr, name, _schema} = elem(sources, ix)
      {expr || paren_expr(source, sources, query), name}
    end

    defp quote_qualified_name(name, sources, ix) do
      {_, source, _} = elem(sources, ix)
      [source, ?. | quote_name(name)]
    end

    defp quote_name(name) when is_atom(name) do
      quote_name(Atom.to_string(name))
    end

    defp quote_name(name) do
      if String.contains?(name, "\"") do
        error!(nil, "bad field name #{inspect(name)}")
      end

      [?", name, ?"]
    end

    defp quote_table(nil, name), do: quote_table(name)
    defp quote_table(prefix, name), do: [quote_table(prefix), ?., quote_table(name)]

    defp quote_table(name) when is_atom(name), do: quote_table(Atom.to_string(name))

    defp quote_table(name) do
      if String.contains?(name, "\"") do
        error!(nil, "bad table name #{inspect(name)}")
      end

      [?", name, ?"]
    end

    defp single_quote(value), do: [?', escape_string(value), ?']

    defp intersperse_map(list, separator, mapper, acc \\ [])
    defp intersperse_map([], _separator, _mapper, acc), do: acc
    defp intersperse_map([elem], _separator, mapper, acc), do: [acc | mapper.(elem)]

    defp intersperse_map([elem | rest], separator, mapper, acc),
      do: intersperse_map(rest, separator, mapper, [acc, mapper.(elem), separator])

    defp intersperse_reduce(list, separator, user_acc, reducer, acc \\ [])
    defp intersperse_reduce([], _separator, user_acc, _reducer, acc), do: {acc, user_acc}

    defp intersperse_reduce([elem], _separator, user_acc, reducer, acc) do
      {elem, user_acc} = reducer.(elem, user_acc)
      {[acc | elem], user_acc}
    end

    defp intersperse_reduce([elem | rest], separator, user_acc, reducer, acc) do
      {elem, user_acc} = reducer.(elem, user_acc)
      intersperse_reduce(rest, separator, user_acc, reducer, [acc, elem, separator])
    end

    defp if_do(condition, value) do
      if condition, do: value, else: []
    end

    defp escape_string(value) when is_binary(value) do
      :binary.replace(value, "'", "''", [:global])
    end

    defp ecto_to_db({:array, _}), do: error!(nil, "Array type is not supported by Redshift")
    defp ecto_to_db(:id), do: "bigint"
    defp ecto_to_db(:serial), do: "integer"
    defp ecto_to_db(:bigserial), do: "bigint"
    defp ecto_to_db(:binary_id), do: "char(36)"
    defp ecto_to_db(:uuid), do: "char(36)"
    defp ecto_to_db(:string), do: "varchar"
    defp ecto_to_db(:binary), do: "varchar(max)"
    defp ecto_to_db(:map), do: "varchar(max)"
    defp ecto_to_db({:map, _}), do: "varchar(max)"
    defp ecto_to_db(:utc_datetime), do: "timestamp"
    defp ecto_to_db(:naive_datetime), do: "timestamp"
    defp ecto_to_db(other), do: Atom.to_string(other)

    defp error!(nil, message) do
      raise ArgumentError, message
    end

    defp error!(query, message) do
      raise Ecto.QueryError, query: query, message: message
    end

    defp json_library do
      Application.get_env(:postgrex, :json_library) ||
        raise "REPLACE WITH BETTER ERROR ABOUT CONFIGURING JSON LIBRARY"
    end
  end
end
