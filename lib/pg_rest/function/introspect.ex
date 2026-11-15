defmodule PgRest.Function.Introspect do
  @moduledoc """
  Loads `PgRest.Function`s from `pg_proc`, in one statement.

  Only plain functions (`prokind = 'f'`) of the given schemas are read. Extension-owned
  functions and functions returning `trigger`, `event_trigger` or `internal` are always
  skipped. The filter narrows further:

    * `only:` keeps exactly the listed names, `except:` drops them (matched as strings)
    * `as_role:` keeps a function only when at least one listed role may `EXECUTE` it

  Every name and role is a bind parameter, and the statement runs with the statement options
  of `Executor.repo_opts/2` (internal) (`log: false`, no repo query event), like every other
  PgRest statement. Types are `pg_catalog.format_type(oid, NULL)` text under an empty
  `search_path` (`Catalog.with_empty_search_path/3` (internal), as every catalog load), so every
  type outside `pg_catalog` is schema qualified (`test.status_enum`, `public.user_status`).
  Each result column also carries its `pg_type.typcategory` (`PgRest.Function.Return`
  `categories`).

  ## Differences from PostgREST

  Extension-owned functions are never exposed, even when EXECUTE is granted.
  This keeps extension infrastructure outside the application RPC surface.
  """

  alias PgRest.{Catalog, Executor, Function}
  alias PgRest.Error.Translate
  alias PgRest.Function.{Param, Return}

  @type filter :: %{
          optional(:only) => [String.t()] | nil,
          optional(:except) => [String.t()],
          optional(:as_role) => [String.t()] | nil
        }

  @sql """
  SELECT
    n.nspname::text,
    p.proname::text,
    p.provolatile::text,
    p.proretset,
    p.pronargdefaults::int,
    coalesce(p.proargnames, '{}')::text[],
    coalesce(p.proargmodes::text[], '{}'),
    ARRAY(
      SELECT ARRAY[pg_catalog.format_type(a.oid, NULL), argt.typcategory::text]
      FROM unnest(coalesce(p.proallargtypes, p.proargtypes::oid[])) WITH ORDINALITY AS a(oid, i)
      JOIN pg_catalog.pg_type argt ON argt.oid = a.oid
      ORDER BY a.i
    ),
    pg_catalog.format_type(p.prorettype, NULL),
    t.typtype::text,
    cn.nspname::text,
    c.relname::text,
    ARRAY(
      SELECT ARRAY[att.attname::text, pg_catalog.format_type(att.atttypid, NULL),
        ct.typcategory::text]
      FROM pg_catalog.pg_attribute att
      JOIN pg_catalog.pg_type ct ON ct.oid = att.atttypid
      WHERE att.attrelid = t.typrelid AND att.attnum > 0 AND NOT att.attisdropped
      ORDER BY att.attnum
    )
  FROM pg_catalog.pg_proc p
  JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
  JOIN pg_catalog.pg_type t ON t.oid = p.prorettype
  LEFT JOIN pg_catalog.pg_class c ON c.oid = t.typrelid
  LEFT JOIN pg_catalog.pg_namespace cn ON cn.oid = c.relnamespace
  WHERE p.prokind = 'f'
    AND n.nspname = ANY($1::text[])
    AND p.prorettype NOT IN ('pg_catalog.trigger'::pg_catalog.regtype,
      'pg_catalog.event_trigger'::pg_catalog.regtype, 'pg_catalog.internal'::pg_catalog.regtype)
    AND NOT EXISTS (
      SELECT 1 FROM pg_catalog.pg_depend d
      WHERE d.classid = 'pg_catalog.pg_proc'::pg_catalog.regclass AND d.objid = p.oid
        AND d.deptype = 'e'
    )
    AND ($2::text[] IS NULL OR p.proname = ANY($2::text[]))
    AND NOT (p.proname = ANY($3::text[]))
    AND ($4::text[] IS NULL OR EXISTS (
      SELECT 1 FROM unnest($4::text[]) AS r(role)
      WHERE pg_catalog.has_function_privilege(r.role, p.oid, 'EXECUTE')
    ))
  ORDER BY n.nspname, p.proname, p.oid
  """

  @volatility %{"i" => :immutable, "s" => :stable, "v" => :volatile}
  @input_modes ["i", "b", "v"]
  @output_modes ["o", "b", "t"]

  @doc """
  The functions of `schemas` that `filter` keeps. A composite return whose type is the table
  of one of `resource_configs` carries that resource. A database or connection failure is
  `{:error, exception}`.
  """
  @spec load(module(), [String.t()], [map()], filter()) ::
          {:ok, [Function.t()]} | {:error, Exception.t()}
  def load(repo, schemas, resource_configs, filter \\ %{}) do
    resources = Map.new(resource_configs, &{{&1.schema, &1.table}, &1.module})

    params = [
      schemas,
      Map.get(filter, :only),
      Map.get(filter, :except) || [],
      Map.get(filter, :as_role)
    ]

    opts = Executor.repo_opts(@sql, %{statement_cache: false})

    {:ok, %{rows: rows}} =
      Catalog.with_empty_search_path(repo, __MODULE__, fn -> repo.query!(@sql, params, opts) end)

    {:ok, Enum.map(rows, &to_function(&1, resources))}
  rescue
    exception in [Postgrex.Error, DBConnection.ConnectionError] -> {:error, exception}
  end

  @doc false
  # Whether a load failure may fix itself (the server was unreachable), so it is retried.
  @spec transient?(Exception.t()) :: boolean()
  def transient?(exception), do: Translate.kind(exception) == :connection

  defp to_function(row, resources) do
    [schema, name, volatility, set?, n_defaults, names, modes, types | return] = row
    args = args(names, modes, Enum.map(types, &List.first/1))
    categories = Enum.map(types, &List.last/1)

    %Function{
      schema: schema,
      name: name,
      params: params(args, n_defaults),
      returns: returns(args, categories, set?, return, resources),
      volatility: Map.fetch!(@volatility, volatility)
    }
  end

  # `{name, mode, type}` per argument. No modes means every argument is IN; unnamed
  # arguments have no (or an empty) name.
  defp args(names, modes, types) do
    count = length(types)

    [types, pad(names, count, ""), pad(modes, count, "i")]
    |> Enum.zip_with(fn [type, name, mode] -> {name, mode, type} end)
  end

  defp pad(list, count, fill), do: Enum.take(list ++ List.duplicate(fill, count), count)

  # The last `pronargdefaults` inputs have defaults.
  defp params(args, n_defaults) do
    inputs = Enum.filter(args, fn {_name, mode, _type} -> mode in @input_modes end)
    first_optional = length(inputs) - n_defaults

    inputs
    |> Enum.with_index()
    |> Enum.map(fn {{name, mode, type}, i} ->
      %Param{name: name, type: type, required?: i < first_optional, variadic?: mode == "v"}
    end)
  end

  defp returns(args, categories, set?, [type, typtype, rel_schema, rel_name, columns], resources) do
    outputs =
      for {{name, mode, arg_type}, category} <- Enum.zip(args, categories),
          mode in @output_modes,
          do: [name, arg_type, category]

    case outputs do
      [] -> declared_return(type, typtype, set?, {rel_schema, rel_name}, columns, resources)
      outputs -> composite(%Return{kind: :composite, set?: set?, type: type}, outputs)
    end
  end

  defp declared_return("void", "p", set?, _rel, _columns, _resources),
    do: %Return{kind: :void, set?: set?, type: "void"}

  defp declared_return("record", "p", set?, _rel, _columns, _resources),
    do: %Return{kind: :composite, set?: set?, type: "record"}

  defp declared_return(type, "c", set?, rel, columns, resources) do
    return = %Return{kind: :composite, set?: set?, type: type, resource: Map.get(resources, rel)}
    composite(return, columns)
  end

  defp declared_return(type, _typtype, set?, _rel, _columns, _resources),
    do: %Return{kind: :scalar, set?: set?, type: type}

  # `[name, type, typcategory]` per result column.
  defp composite(return, rows) do
    {columns, categories} = Catalog.typed_rows(rows)
    %{return | columns: columns, categories: categories}
  end
end
