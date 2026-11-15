defmodule PgRest.SchemaGraph do
  @moduledoc """
  The relationship graph over registered resources, with PostgREST's embedding
  resolution rules.

  Relationships come from these places, none of which touch the database:

    * Ecto associations: `belongs_to` gives `:m2o` (and the inverse `:o2m`),
      `has_many` / `has_one` the same pair. The foreign key constraint name defaults
      to `"<table>_<column>_fkey"`.
    * Junctions, as in PostgREST: a registered resource with `:m2o` relationships to
      two tables whose key columns all lie in its primary key yields `:m2m` in both
      directions (self joins included). `many_to_many` associations are not a source;
      their name is accepted as an embed alias for the derived relationship.
    * Overrides in the resource's `relationships:` option keyed by association name:
      `[constraint: "client"]` renames the constraint, `[cardinality: :one_to_one]`
      makes the pair `:o2o`.
    * Explicit declarations in `relationships:`, needed for composite keys:

          relationships: [
            students_info: [
              kind: :o2o,
              target: MyApp.StudentsInfo,
              columns: [{"code", "code"}, {"id", "id"}],
              constraint: "students_info_code_id_fkey"
            ],
            files: [
              kind: :m2m,
              target: MyApp.Files,
              junction: [
                table: "touched_files",
                schema: "public",
                source_columns: [{"user_id", "user_id"}],
                target_columns: [{"filename", "filename"}],
                constraints: {"fk_users_tasks", "fk_upload"}
              ]
            ]
          ]

      An explicit `:m2m` yields both directions and its junction table must be a
      registered resource (`ArgumentError` otherwise, as for an unregistered `target:`).
      `:m2o` declares the foreign key on this resource; `:o2m` and `:o2o` declare it
      on the target. `columns` pairs are `{source_column, target_column}`.

  Every foreign key yields both directions, so a relationship is discoverable from
  either resource even when only one side declares it.
  """

  alias PgRest.Error
  alias PgRest.SchemaGraph.{Fuzzy, Relationship}

  @enforce_keys [:rels, :tables]
  defstruct [:rels, :tables]

  @type t :: %__MODULE__{
          rels: %{module() => [Relationship.t()]},
          tables: %{module() => {schema :: String.t(), table :: String.t()}}
        }

  @doc """
  Builds the graph for the given resource modules. Ecto associations to other modules
  are ignored; explicit declarations naming an unregistered target or junction raise
  `ArgumentError`.
  """
  @spec build([module()]) :: t()
  def build(modules) do
    infos = Map.new(modules, &{&1, info(&1)})

    fk_rels =
      infos
      |> Map.values()
      |> Enum.flat_map(&foreign_keys(&1, infos))
      |> merge_foreign_keys()
      |> Enum.flat_map(&directed/1)

    junctions = infos |> Map.values() |> Enum.flat_map(&junction_rels(&1, fk_rels))
    explicit = infos |> Map.values() |> Enum.flat_map(&explicit_m2m(&1, infos))

    rels =
      (fk_rels ++ junctions ++ explicit)
      |> dedupe()
      |> name_m2m_aliases(infos)
      |> Enum.group_by(& &1.source)

    %__MODULE__{
      rels: rels,
      tables: Map.new(infos, fn {module, info} -> {module, {info.schema, info.table}} end)
    }
  end

  @doc """
  The relationships a request against `schema` can embed: those whose source and target
  tables both live in `schema`. PostgREST keys its relationships by the foreign table's
  schema and looks them up with the request schema, so a foreign key into another exposed
  schema is not embeddable (`PGRST200`), even though it is in the full graph.
  """
  @spec restrict(t(), String.t()) :: t()
  def restrict(%__MODULE__{} = graph, schema) do
    in_schema? = fn module -> graph |> table(module) |> elem(0) == schema end

    rels =
      for {source, rels} <- graph.rels,
          in_schema?.(source),
          kept = Enum.filter(rels, &in_schema?.(&1.target)),
          kept != [],
          into: %{},
          do: {source, kept}

    %{graph | rels: rels}
  end

  @doc """
  Resolves the embed `name` (with optional `hint`) from `source`.

  Mirrors PostgREST's `findRel`: the name is a target table, a constraint or a
  single foreign-key column of the source; the hint a constraint, a single key
  column on either side, or a junction table. A name that is an association name
  on `source` is accepted when nothing else matches.

  Errors are `PGRST200` (nothing matches, 400) and `PGRST201` (several match, 300).
  """
  @spec resolve(t(), module(), String.t(), String.t() | nil) ::
          {:ok, Relationship.t()} | {:error, Error.t()}
  def resolve(%__MODULE__{} = graph, source, name, hint) do
    candidates = Map.get(graph.rels, source, [])

    case Enum.filter(candidates, &match_rel?(graph, &1, name, hint)) do
      [rel] -> {:ok, rel}
      [] -> resolve_by_assoc(graph, candidates, source, name, hint)
      rels -> {:error, ambiguous(graph, source, name, rels)}
    end
  end

  defp resolve_by_assoc(graph, candidates, source, name, nil) do
    case Enum.filter(candidates, &(assoc_name(&1) == name)) do
      [rel] -> {:ok, rel}
      _ -> {:error, no_relationship(graph, source, name, nil)}
    end
  end

  defp resolve_by_assoc(graph, _candidates, source, name, hint),
    do: {:error, no_relationship(graph, source, name, hint)}

  defp assoc_name(%Relationship{assoc: nil}), do: nil
  defp assoc_name(%Relationship{assoc: assoc}), do: Atom.to_string(assoc)

  # ── matching (PostgREST Plan.findRel) ──────────────────────────────────────

  defp match_rel?(graph, rel, name, hint) do
    if self_relationship?(graph, rel),
      do: match_self?(graph, rel, name, hint),
      else: match_other?(graph, rel, name, hint)
  end

  defp self_relationship?(graph, rel), do: table(graph, rel.source) == table(graph, rel.target)

  defp match_self?(graph, rel, name, nil) do
    (name == target_table(graph, rel) and rel.kind == :o2m) or
      (single_column?(rel.source_columns, name) and key_kind?(rel) and rel.kind == :m2o)
  end

  defp match_self?(graph, rel, name, hint) do
    name == target_table(graph, rel) and rel.kind == :o2m and
      single_column?(rel.target_columns, hint)
  end

  defp match_other?(graph, rel, name, nil) do
    name == target_table(graph, rel) or constraint?(rel, name) or
      (key_kind?(rel) and single_column?(rel.source_columns, name))
  end

  defp match_other?(graph, rel, name, hint) do
    name == target_table(graph, rel) and
      (constraint?(rel, hint) or
         (key_kind?(rel) and
            (single_column?(rel.source_columns, hint) or single_column?(rel.target_columns, hint))) or
         junction?(rel, hint))
  end

  defp key_kind?(%Relationship{kind: kind}), do: kind != :m2m
  defp constraint?(%Relationship{kind: :m2m}, _name), do: false
  defp constraint?(%Relationship{constraint: constraint}, name), do: constraint == name

  defp junction?(%Relationship{kind: :m2m, junction: %{table: table}}, name), do: table == name
  defp junction?(_rel, _name), do: false

  defp single_column?([column], name), do: column == name
  defp single_column?(_columns, _name), do: false

  # ── errors ─────────────────────────────────────────────────────────────────

  defp ambiguous(graph, source, name, rels) do
    rels = Enum.sort_by(rels, &sort_key(graph, &1))

    %Error{
      status: 300,
      code: "PGRST201",
      message:
        "Could not embed because more than one relationship was found for " <>
          "'#{table_name(graph, source)}' and '#{name}'",
      details: Enum.map(rels, &compressed(graph, &1)),
      hint:
        "Try changing '#{name}' to one of the following: " <>
          Enum.map_join(rels, ", ", &"'#{target_table(graph, &1)}!#{hint_name(&1)}'") <>
          ". Find the desired relationship in the 'details' key."
    }
  end

  # PostgREST sorts relationships by their derived Ord: foreign table, cardinality
  # constructor order (O2M, M2O, O2O, M2M), then constraint / junction table, columns.
  defp sort_key(graph, rel) do
    rank = Enum.find_index([:o2m, :m2o, :o2o, :m2m], &(&1 == rel.kind))
    {table(graph, rel.target), rank, identity(rel)}
  end

  defp identity(%Relationship{kind: :m2m, junction: junction} = rel) do
    {c1, c2} = junction.constraints
    {{junction.schema, junction.table}, c1, c2, column_pairs(rel)}
  end

  defp identity(rel), do: {rel.constraint, column_pairs(rel)}

  # Upstream compares the (source, target) column pairs, not the two lists one after the
  # other.
  defp column_pairs(rel), do: Enum.zip(rel.source_columns, rel.target_columns)

  defp hint_name(%Relationship{kind: :m2m, junction: %{table: table}}), do: table
  defp hint_name(%Relationship{constraint: constraint}), do: constraint

  defp compressed(graph, %Relationship{kind: :m2m, junction: junction} = rel) do
    {c1, c2} = junction.constraints

    %{
      "embedding" => embedding(graph, rel),
      "cardinality" => "many-to-many",
      "relationship" =>
        "#{junction.table} using #{c1}#{columns(junction.source_columns)} and " <>
          "#{c2}#{columns(junction.target_columns)}"
    }
  end

  defp compressed(graph, rel) do
    %{
      "embedding" => embedding(graph, rel),
      "cardinality" => cardinality(rel.kind),
      "relationship" =>
        "#{rel.constraint} using #{table_name(graph, rel.source)}#{columns(rel.source_columns)} and " <>
          "#{target_table(graph, rel)}#{columns(rel.target_columns)}"
    }
  end

  defp embedding(graph, rel),
    do: "#{table_name(graph, rel.source)} with #{target_table(graph, rel)}"

  defp cardinality(:m2o), do: "many-to-one"
  defp cardinality(:o2m), do: "one-to-many"
  defp cardinality(:o2o), do: "one-to-one"

  defp columns(columns), do: "(" <> Enum.join(columns, ", ") <> ")"

  defp no_relationship(graph, source, name, hint) do
    {schema, parent} = table(graph, source)

    Error.no_relationship(
      schema,
      parent,
      name,
      hint,
      suggestion(graph, source, schema, parent, name)
    )
  end

  # As PostgREST: when the origin has relationships, suggest the closest related table
  # (never one that matches exactly, which means the hint was the problem); when it
  # has none, suggest the closest table that has relationships.
  defp suggestion(graph, source, schema, parent, child) do
    case Map.get(graph.rels, source, []) do
      [] ->
        parent_suggestion(graph, schema, parent)

      rels ->
        rels
        |> Enum.map(&target_table(graph, &1))
        |> Fuzzy.get(child)
        |> Enum.find_value(&inexact/1)
        |> perhaps(child)
    end
  end

  @doc """
  `PGRST200` for an embed `name` from `parent`, a source that is no registered resource and so
  has no relationships (a function's composite result): as PostgREST, the hint names the
  closest table of `schema` that has relationships.
  """
  @spec no_relationship_from(t(), String.t(), String.t(), String.t(), String.t() | nil) ::
          Error.t()
  def no_relationship_from(graph, schema, parent, name, hint) do
    Error.no_relationship(schema, parent, name, hint, parent_suggestion(graph, schema, parent))
  end

  defp parent_suggestion(graph, schema, parent) do
    graph
    |> parents(schema)
    |> Fuzzy.closest(parent)
    |> perhaps(parent)
  end

  defp inexact({score, candidate}) when score < 1.0, do: candidate
  defp inexact(_exact), do: nil

  defp perhaps(nil, _typed), do: nil
  defp perhaps(candidate, typed), do: "Perhaps you meant '#{candidate}' instead of '#{typed}'."

  defp parents(graph, schema) do
    for {module, [_ | _]} <- graph.rels,
        {^schema, table} <- [table(graph, module)],
        do: table
  end

  defp table(graph, module), do: Map.fetch!(graph.tables, module)
  defp table_name(graph, module), do: graph |> table(module) |> elem(1)
  defp target_table(graph, rel), do: table_name(graph, rel.target)

  # ── derivation ─────────────────────────────────────────────────────────────

  defp info(module) do
    config = module.__pgrest_config__()

    %{
      module: module,
      table: config.table,
      schema: config.schema,
      field_sources: config.field_sources,
      primary_key: config.primary_key,
      relationships: config.relationships
    }
  end

  defp column(infos, module, field),
    do: infos |> Map.fetch!(module) |> Map.fetch!(:field_sources) |> Map.fetch!(field)

  defp foreign_keys(info, infos) do
    association_fks(info, infos) ++ declared_fks(info, infos)
  end

  defp association_fks(%{module: module} = info, infos) do
    for name <- module.__schema__(:associations),
        fk <- association_fk(info, name, module.__schema__(:association, name), infos),
        do: fk
  end

  defp association_fk(info, name, %Ecto.Association.BelongsTo{} = assoc, infos)
       when is_map_key(infos, assoc.related) do
    opts = Keyword.get(info.relationships, name, [])
    child_columns = [column(infos, info.module, assoc.owner_key)]
    {constraint, explicit?} = constraint_for(opts, info.table, child_columns)

    [
      fk(
        {info.module, assoc.related},
        {child_columns, [column(infos, assoc.related, assoc.related_key)]},
        {constraint, explicit?, opts[:cardinality] == :one_to_one},
        {name, nil}
      )
    ]
  end

  defp association_fk(info, name, %Ecto.Association.Has{} = assoc, infos)
       when is_map_key(infos, assoc.related) do
    opts = Keyword.get(info.relationships, name, [])
    child_columns = [column(infos, assoc.related, assoc.related_key)]
    {constraint, explicit?} = constraint_for(opts, infos[assoc.related].table, child_columns)
    o2o? = assoc.cardinality == :one or opts[:cardinality] == :one_to_one

    [
      fk(
        {assoc.related, info.module},
        {child_columns, [column(infos, info.module, assoc.owner_key)]},
        {constraint, explicit?, o2o?},
        {nil, name}
      )
    ]
  end

  defp association_fk(_info, _name, _assoc, _infos), do: []

  defp constraint_for(opts, table, columns) do
    case opts[:constraint] do
      nil -> {"#{table}_#{Enum.join(columns, "_")}_fkey", false}
      constraint -> {constraint, true}
    end
  end

  defp fk(
         {child, parent},
         {child_columns, parent_columns},
         {constraint, explicit?, o2o?},
         {child_assoc, parent_assoc}
       ) do
    %{
      child: child,
      parent: parent,
      child_columns: child_columns,
      parent_columns: parent_columns,
      constraint: constraint,
      explicit?: explicit?,
      o2o?: o2o?,
      child_assoc: child_assoc,
      parent_assoc: parent_assoc
    }
  end

  defp declared_fks(info, infos) do
    for {name, opts} <- info.relationships, opts[:kind] in [:m2o, :o2m, :o2o] do
      declared_fk(info, name, opts, ensure_registered!(info, name, opts[:target], infos))
    end
  end

  defp declared_fk(info, name, opts, target) do
    {source_columns, target_columns} = opts |> Keyword.fetch!(:columns) |> Enum.unzip()
    constraint = Keyword.fetch!(opts, :constraint)

    case opts[:kind] do
      :m2o ->
        fk(
          {info.module, target},
          {source_columns, target_columns},
          {constraint, true, false},
          {name, nil}
        )

      kind ->
        fk(
          {target, info.module},
          {target_columns, source_columns},
          {constraint, true, kind == :o2o},
          {nil, name}
        )
    end
  end

  defp ensure_registered!(info, name, target, infos) do
    if Map.has_key?(infos, target) do
      target
    else
      raise ArgumentError,
            "#{inspect(info.module)} declares relationship #{inspect(name)} with target " <>
              "#{inspect(target)}, which is not a registered resource"
    end
  end

  # The same foreign key is usually seen from both resources (belongs_to on the
  # child, has_many on the parent); merge the sightings into one.
  defp merge_foreign_keys(fks) do
    fks
    |> Enum.group_by(&{&1.child, &1.parent, &1.child_columns, &1.parent_columns})
    |> Map.values()
    |> Enum.flat_map(&merge_group/1)
  end

  # Explicit constraint names are real constraints: two different names on the same
  # columns are two relationships (as PostgREST lists both). Sightings without an
  # explicit name carry the default name, so they join the first explicit group.
  defp merge_group(sightings) do
    {explicit, implicit} = Enum.split_with(sightings, & &1.explicit?)

    groups =
      case explicit |> Enum.group_by(& &1.constraint) |> Enum.sort() do
        [] -> [implicit]
        [{_name, first} | rest] -> [first ++ implicit | Enum.map(rest, &elem(&1, 1))]
      end

    Enum.map(groups, fn [first | rest] -> Enum.reduce(rest, first, &merge_sighting/2) end)
  end

  defp merge_sighting(sighting, acc) do
    %{
      acc
      | explicit?: acc.explicit? or sighting.explicit?,
        o2o?: acc.o2o? or sighting.o2o?,
        child_assoc: acc.child_assoc || sighting.child_assoc,
        parent_assoc: acc.parent_assoc || sighting.parent_assoc
    }
  end

  defp directed(fk) do
    {from_child, from_parent} = if fk.o2o?, do: {:o2o, :o2o}, else: {:m2o, :o2m}

    [
      %Relationship{
        kind: from_child,
        source: fk.child,
        target: fk.parent,
        constraint: fk.constraint,
        source_columns: fk.child_columns,
        target_columns: fk.parent_columns,
        assoc: fk.child_assoc
      },
      %Relationship{
        kind: from_parent,
        source: fk.parent,
        target: fk.child,
        constraint: fk.constraint,
        source_columns: fk.parent_columns,
        target_columns: fk.child_columns,
        assoc: fk.parent_assoc
      }
    ]
  end

  # PostgREST (SchemaCache.addM2MRels): a table with many-to-one relationships to two
  # tables, whose foreign key columns all belong to its primary key, is a junction.
  # Every ordered pair of distinct constraints gives one relationship, so both
  # directions and self joins come out.
  defp junction_rels(info, fk_rels) do
    primary_key = MapSet.new(info.primary_key, &Map.fetch!(info.field_sources, &1))
    m2os = Enum.filter(fk_rels, &(&1.source == info.module and &1.kind == :m2o))

    for first <- m2os,
        second <- m2os,
        first.constraint != second.constraint,
        MapSet.subset?(MapSet.new(first.source_columns ++ second.source_columns), primary_key) do
      m2m(
        first.target,
        second.target,
        %{
          module: info.module,
          table: info.table,
          schema: info.schema,
          source_columns: first.source_columns,
          target_columns: second.source_columns,
          constraints: {first.constraint, second.constraint}
        },
        first.target_columns,
        second.target_columns
      )
    end
  end

  defp explicit_m2m(info, infos) do
    for {name, opts} <- info.relationships,
        opts[:kind] == :m2m,
        rel <- declared_m2m(info, name, opts, infos) do
      rel
    end
  end

  defp declared_m2m(info, name, opts, infos) do
    target = ensure_registered!(info, name, opts[:target], infos)
    junction = Keyword.fetch!(opts, :junction)

    source_pairs = Keyword.fetch!(junction, :source_columns)
    target_pairs = Keyword.fetch!(junction, :target_columns)

    {c1, c2} = Keyword.fetch!(junction, :constraints)
    table = Keyword.fetch!(junction, :table)
    schema = Keyword.fetch!(junction, :schema)
    junction_module = junction_module!(info, name, infos, schema, table)
    base = %{module: junction_module, table: table, schema: schema}

    {source_columns, to_junction} = Enum.unzip(source_pairs)
    {from_junction, target_columns} = Enum.unzip(target_pairs)

    forward =
      m2m(
        info.module,
        target,
        Map.merge(base, %{
          source_columns: to_junction,
          target_columns: from_junction,
          constraints: {c1, c2}
        }),
        source_columns,
        target_columns
      )

    backward =
      m2m(
        target,
        info.module,
        Map.merge(base, %{
          source_columns: from_junction,
          target_columns: to_junction,
          constraints: {c2, c1}
        }),
        target_columns,
        source_columns
      )

    [%{forward | assoc: name}, backward]
  end

  # The same relationship can be seen twice (a derived junction and an explicit m2m over
  # it, or an explicit m2m declared from both sides). Keep one copy, preferring the one
  # that carries an association name.
  defp dedupe(rels) do
    rels
    |> Enum.sort_by(&(&1.assoc == nil))
    |> Enum.uniq_by(
      &{&1.source, &1.target, &1.kind, &1.constraint, &1.source_columns, &1.target_columns,
       &1.junction}
    )
  end

  defp junction_module!(info, name, infos, schema, table) do
    case Enum.find(Map.values(infos), &(&1.schema == schema and &1.table == table)) do
      nil ->
        raise ArgumentError,
              "#{inspect(info.module)} relationship #{inspect(name)} goes through junction " <>
                "#{schema}.#{table}, which has no registered resource"

      %{module: module} ->
        module
    end
  end

  defp m2m(source, target, junction, source_columns, target_columns) do
    %Relationship{
      kind: :m2m,
      source: source,
      target: target,
      constraint: junction.table,
      source_columns: source_columns,
      target_columns: target_columns,
      junction: junction
    }
  end

  # `many_to_many` is not a relationship source; its association name becomes an
  # accepted embed alias for the derived junction relationship.
  defp name_m2m_aliases(rels, infos) do
    aliases =
      for {module, info} <- infos,
          name <- module.__schema__(:associations),
          %Ecto.Association.ManyToMany{related: related} = assoc <- [
            module.__schema__(:association, name)
          ],
          Map.has_key?(infos, related),
          into: %{},
          do: {{module, related, join_table(info, infos, assoc.join_through)}, name}

    ambiguous =
      rels
      |> Enum.filter(&(&1.kind == :m2m and &1.assoc == nil))
      |> Enum.frequencies_by(&alias_key/1)

    Enum.map(rels, fn
      %Relationship{kind: :m2m, assoc: nil} = rel ->
        key = alias_key(rel)
        if ambiguous[key] == 1, do: %{rel | assoc: Map.get(aliases, key)}, else: rel

      rel ->
        rel
    end)
  end

  defp alias_key(rel), do: {rel.source, rel.target, {rel.junction.schema, rel.junction.table}}

  defp join_table(info, _infos, table) when is_binary(table), do: {info.schema, table}

  defp join_table(info, infos, module) when is_atom(module) do
    schema = if infos[module], do: infos[module].schema, else: info.schema
    {schema, module.__schema__(:source)}
  end
end
