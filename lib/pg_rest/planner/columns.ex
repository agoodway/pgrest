defmodule PgRest.Planner.Columns do
  @moduledoc """
  Per-resource column data for the planner and request-column validation.

  `info/2` combines the resource's config with the catalog types, keyed by Ecto field
  name (the catalog itself is keyed by database column). The result is memoized next to
  the catalog cache, so a request recomputes nothing. Request column names are database
  names; `translate_field/3` maps them to field names, which is how scoped sources
  expose their columns, and fails with PostgREST's `42703` (with Postgres's closest-column
  hint) or `42501` for a column outside `readable:`.
  """

  alias PgRest.AST.Field
  alias PgRest.{Catalog, Error}
  alias PgRest.SchemaGraph.Fuzzy

  @max_fuzzy_distance 3
  # Fallback when the catalog is unreadable; anything else binds as plain text.
  @ecto_pg_types %{
    id: "bigint",
    integer: "bigint",
    string: "text",
    boolean: "boolean",
    decimal: "numeric",
    float: "double precision",
    date: "date",
    time: "time",
    naive_datetime: "timestamp",
    utc_datetime: "timestamptz",
    map: "jsonb",
    binary_id: "uuid",
    binary: "bytea"
  }

  @type info :: %{
          optional(:role) => :anon | :authenticated,
          config: map(),
          table: String.t(),
          columns: [{String.t(), String.t()}],
          by_source: %{String.t() => String.t()},
          types: %{String.t() => String.t()},
          categories: %{String.t() => String.t()}
        }

  @doc """
  The info map of `module`: `columns` are `{source, field_name}` in field order,
  `by_source` maps a database column to its field name, `types` and `categories` are keyed
  by field name. `schema` is the resource's effective schema
  (`PgRest.SQL.ScopedSource.effective_schema/2`). Calls the catalog (cached per schema) on
  first use; not inside a transaction.
  """
  @spec info(module(), module(), String.t()) :: info()
  def info(module, repo, schema) do
    # Under the catalog's namespace, so `Catalog.forget/1` clears it too.
    key = {Catalog, repo, :info, {module, module.__info__(:md5), schema}}

    case :persistent_term.get(key, nil) do
      nil ->
        info = load(module, repo, schema)
        :persistent_term.put(key, info)
        info

      info ->
        info
    end
  end

  defp load(module, repo, schema) do
    config = module.__pgrest_config__()
    catalog_types = Catalog.column_types(repo, schema, config.table)
    catalog_categories = Catalog.column_categories(repo, schema, config.table)

    columns =
      for field <- config.fields do
        {Map.fetch!(config.field_sources, field), Atom.to_string(field), field}
      end

    # The catalog is keyed by database column; the plan by Ecto field name.
    types =
      for {source, name, field} <- columns,
          type = Map.get(catalog_types, source) || Map.get(@ecto_pg_types, config.types[field]),
          into: %{},
          do: {name, type}

    categories =
      for {source, name, _field} <- columns,
          category = Map.get(catalog_categories, source),
          into: %{},
          do: {name, category}

    pairs = Enum.map(columns, fn {source, name, _field} -> {source, name} end)

    %{
      config: config,
      table: config.table,
      columns: pairs,
      by_source: config.source_fields,
      types: types,
      categories: categories
    }
  end

  @doc "Whether the Ecto field is readable."
  @spec readable?(info(), String.t()) :: boolean()
  def readable?(info, field_name), do: MapSet.member?(info.config.readable, field_name)

  @doc """
  The exposed (Ecto field) name of a database column of `module`, without the catalog.
  """
  @spec exposed_name(module(), String.t()) :: String.t()
  def exposed_name(module, column) do
    case module.__pgrest_config__().source_fields do
      %{^column => name} -> name
      _ -> raise ArgumentError, "#{inspect(module)} has no column #{column}"
    end
  end

  @doc """
  Request column (database name) to Ecto field name, or `42703` / `42501` (401 or 403 by the
  info's `:role`, which `PgRest.Planner` sets).
  """
  @spec translate_field(Field.t(), info(), String.t()) :: {:ok, Field.t()} | {:error, Error.t()}
  def translate_field(%Field{name: name} = field, info, alias_name) do
    case Map.fetch(info.by_source, name) do
      {:ok, field_name} ->
        if readable?(info, field_name),
          do: {:ok, %{field | name: field_name}},
          else: {:error, Error.table_denied(%{table: info.table}, Map.get(info, :role, :anon))}

      :error ->
        {:error, Error.unknown_column(alias_name, name, hint(info, alias_name, name))}
    end
  end

  # Postgres suggests the closest column when it is within 3 edits and no more than
  # half the typed name away; two equally close ones are both named.
  defp hint(info, alias_name, name) do
    length = String.length(name)
    max = min(@max_fuzzy_distance, div(length, 2))

    info.columns
    # The distance is at least the length difference: skip what can never be within `max`
    # before the edit distance runs on a URL-sized name.
    |> Enum.filter(fn {source, field_name} ->
      readable?(info, field_name) and source != name and
        abs(String.length(source) - length) <= max
    end)
    |> Enum.map(fn {source, _} -> {Fuzzy.levenshtein(name, source), source} end)
    |> Enum.filter(fn {distance, _} -> distance <= max end)
    |> Enum.sort_by(&elem(&1, 0))
    |> suggestion(alias_name)
  end

  defp suggestion([], _alias_name), do: nil

  defp suggestion([{best, first} | rest], alias_name) do
    case Enum.find(rest, fn {distance, _} -> distance == best end) do
      nil ->
        "Perhaps you meant to reference the column \"#{alias_name}.#{first}\"."

      {_, second} ->
        "Perhaps you meant to reference the column \"#{alias_name}.#{first}\" or the column " <>
          "\"#{alias_name}.#{second}\"."
    end
  end
end
