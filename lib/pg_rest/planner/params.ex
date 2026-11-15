defmodule PgRest.Planner.Params do
  @moduledoc """
  Splits the query string of a read into per-embed-path groups.

  A group is `%{where: [...], order: nil | [OrderTerm], ranges: [{"limit" | "offset", v}],
  custom: [{key, value}]}` keyed by the embed path (`[]` is the root). `select`, `order`
  (root), the reserved `columns` and `on_conflict`, and keys without a value never become
  filters; `limit` and `offset` are collected per path.
  """

  alias PgRest.AST.SelectField
  alias PgRest.Error
  alias PgRest.Grammar.{Common, Filter, Order, Select}
  alias PgRest.Planner.Result

  # The one definition of the parameters that never filter rows. `select` and `order` shape
  # the response (parsed by the planner); `columns` and `on_conflict` matter to writes only and
  # are ignored on reads, as PostgREST does; `limit` and `offset` are collected as ranges.
  @shaping ~w(select order)
  @write_only ~w(columns on_conflict)
  @paging ~w(limit offset)
  @skipped @shaping ++ @write_only

  @doc """
  Whether `key` is never a plain filter or RPC argument: a reserved parameter, a logic key or an
  embed-path `order`/`limit`/`offset`.
  """
  @spec reserved_key?(String.t()) :: boolean()
  def reserved_key?(key),
    do:
      key in reserved() or logic_key?(key) or
        String.ends_with?(key, [".order", ".limit", ".offset"])

  @doc "The query parameters that never filter rows (`PgRest.Write` reads them too)."
  @spec reserved() :: [String.t()]
  def reserved, do: @shaping ++ @write_only ++ @paging

  @doc "The reserved parameters that do not shape a representation either (`columns=`, paging)."
  @spec not_shaping() :: [String.t()]
  def not_shaping, do: @write_only ++ @paging

  @type group :: %{
          where: list(),
          order: nil | [PgRest.AST.OrderTerm.t()],
          ranges: [{String.t(), String.t()}],
          custom: [{String.t(), String.t()}]
        }

  @doc "A group with nothing in it."
  @spec empty_group() :: group()
  def empty_group, do: %{where: [], order: nil, ranges: [], custom: []}

  @doc "The parameters that carry a value (a valueless key never filters)."
  @spec string_pairs([{String.t(), String.t() | nil}]) :: [{String.t(), String.t()}]
  def string_pairs(params), do: for({key, value} <- params, is_binary(value), do: {key, value})

  @doc "The last value of `key`, or nil."
  @spec last_value([{String.t(), String.t()}], String.t()) :: String.t() | nil
  def last_value(params, key) do
    params |> Enum.reverse() |> Enum.find_value(fn {k, v} -> k == key && v end)
  end

  @doc """
  Parses the `select` parameter of `params` (valueless keys already dropped): the select tree,
  `*` when the request has none.
  """
  @spec parse_select([{String.t(), String.t()}]) ::
          {:ok, [PgRest.AST.Embed.item()]} | {:error, Error.t()}
  def parse_select(params) do
    case last_value(params, "select") do
      nil -> {:ok, [%SelectField{field: :star}]}
      value -> Select.parse(value)
    end
  end

  @doc """
  The root group of `groups` (an empty group when the request has no root parameter).
  """
  @spec root(%{[String.t()] => group()}) :: group()
  def root(groups), do: Map.get(groups, [], empty_group())

  @doc """
  Groups the request parameters `params` (`group/2`, valueless keys dropped) and returns the root
  group.
  """
  @spec root_group([{String.t(), String.t() | nil}], [String.t()]) ::
          {:ok, group()} | {:error, Error.t()}
  def root_group(params, declared) do
    with {:ok, groups} <- params |> string_pairs() |> group(declared), do: {:ok, root(groups)}
  end

  @doc """
  Groups `params` (valueless keys already dropped) by embed path. `declared` are the
  root resource's custom param names.
  """
  @spec group([{String.t(), String.t()}], [String.t()]) ::
          {:ok, %{[String.t()] => group()}} | {:error, Error.t()}
  def group(params, declared) do
    with {:ok, seed} <- seed(last_value(params, "order")),
         {:ok, groups} <-
           params
           |> Enum.reject(fn {key, _} -> key in @skipped end)
           |> Result.reduce_ok(seed, fn {key, value}, acc ->
             classify(key, value, declared, acc)
           end) do
      {:ok,
       Map.new(groups, fn {path, group} ->
         {path, %{group | where: Enum.reverse(group.where), ranges: Enum.reverse(group.ranges)}}
       end)}
    end
  end

  defp seed(nil), do: {:ok, %{[] => empty_group()}}

  defp seed(text) do
    with {:ok, terms} <- Order.parse(text), do: {:ok, %{[] => %{empty_group() | order: terms}}}
  end

  @doc """
  The embed path a query-string parameter targets, parsed with the same grammar as `group/2`:
  `[]` for the root (and for a parameter that does not parse, which the planner reports).
  `declared` are the custom params. A key that merely contains a dot (`settings->>"a.b"`) is a
  root filter: embeddedness comes from the parsed path only.
  """
  @spec path(String.t(), term(), [String.t()]) :: [String.t()]
  def path(key, value, declared) when is_binary(value) do
    cond do
      key in ["limit", "offset"] -> []
      logic_key?(key) -> parsed(Filter.parse_logic_tree(key, value))
      String.ends_with?(key, ".order") -> suffix_path(key, ".order")
      String.ends_with?(key, ".limit") -> suffix_path(key, ".limit")
      String.ends_with?(key, ".offset") -> suffix_path(key, ".offset")
      key in declared -> []
      true -> parsed(Filter.parse_filter(key, value))
    end
  end

  def path(_key, _value, _declared), do: []

  @doc "Whether `key` is a logic tree key (`or`, `and`, optionally behind an embed path)."
  @spec logic_key?(String.t()) :: boolean()
  def logic_key?(key), do: key in ["or", "and"] or String.ends_with?(key, [".or", ".and"])

  defp parsed({:ok, {path, _tree}}), do: path
  defp parsed(_error), do: []

  defp suffix_path(key, suffix) do
    case path_of(key, suffix) do
      {:ok, path} -> path
      _error -> []
    end
  end

  defp classify("limit", value, _declared, acc), do: {:ok, range(acc, [], "limit", value)}
  defp classify("offset", value, _declared, acc), do: {:ok, range(acc, [], "offset", value)}

  defp classify(key, value, declared, acc) do
    cond do
      logic_key?(key) -> add_logic(acc, key, value)
      String.ends_with?(key, ".order") -> add_order(acc, key, value)
      String.ends_with?(key, ".limit") -> add_path_range(acc, key, "limit", value)
      String.ends_with?(key, ".offset") -> add_path_range(acc, key, "offset", value)
      key in declared -> {:ok, update_group(acc, [], &%{&1 | custom: [{key, value} | &1.custom]})}
      true -> add_filter(acc, key, value)
    end
  end

  defp add_logic(acc, key, value) do
    with {:ok, {path, tree}} <- Filter.parse_logic_tree(key, value) do
      {:ok, update_group(acc, path, &%{&1 | where: [tree | &1.where]})}
    end
  end

  defp add_filter(acc, key, value) do
    with {:ok, {path, condition}} <- Filter.parse_filter(key, value) do
      {:ok, update_group(acc, path, &%{&1 | where: [condition | &1.where]})}
    end
  end

  defp add_order(acc, key, value) do
    with {:ok, path} <- path_of(key, ".order"),
         {:ok, terms} <- Order.parse(value) do
      {:ok, update_group(acc, path, &%{&1 | order: terms})}
    end
  end

  defp add_path_range(acc, key, name, value) do
    with {:ok, path} <- path_of(key, "." <> name), do: {:ok, range(acc, path, name, value)}
  end

  defp range(acc, path, name, value),
    do: update_group(acc, path, &%{&1 | ranges: [{name, value} | &1.ranges]})

  defp path_of(key, suffix) do
    key |> String.replace_suffix(suffix, "") |> Common.parse_names("embed path")
  end

  defp update_group(groups, path, fun), do: Map.update(groups, path, fun.(empty_group()), fun)
end
