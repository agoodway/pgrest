defmodule PgRest.Write.Payload do
  @moduledoc """
  Validates and prepares the body of a write for `PgRest.SQL.Write`.

  Payload keys are database column names. The union of keys is checked once against the
  resource's fields (an unknown one is `PGRST204`) and its effective writable set (a column
  outside it is `42501`, as a missing column privilege would be).

  Without `columns=` every row must have the same keys, as in PostgREST (`PGRST102`).
  With `columns=` only those columns are written and other keys are ignored.

  ## Fast path

  A resource without a custom `changeset/3` or explicitly writable virtual fields skips
  per-row changesets: the original request
  bytes (`raw_body`, or one `Jason.encode!/1` of the decoded body) are bound as is, and
  Postgres reports bad values (`22P02`) as PostgREST does.

  ## Changeset path

  Each row passes through `changeset(struct(resource), row, context)`; the context carries
  `operation: :create | :upsert | :update`. An invalid changeset is a 400 whose `details` are
  `traverse_errors` flattened to one string (`field: message; ...`).

  **The final changes express write intent.** The changeset runs **once per row** (keep it
  pure), on `struct(resource)`. The fields written are the keys of `changeset.changes` that
  are persisted columns (and in `columns=`, when given), each with its `get_field/2` value.
  The writable set gates only client-supplied keys (a `42501` before the changeset runs), so a
  change the callback generates (`put_change/3`) is written even for a non-writable or
  `redact: true` field. The changeset sees `struct(resource)`, also for `PATCH`, not the stored
  row: a `put_change` derived from struct fields uses their defaults. A supplied key the
  changeset does not put in its changes is **not** written: an insert gets the database
  default and an update leaves the column unchanged.

  Ecto's `cast/4` leaves a value equal to the struct default (often `nil`, `0`, `false`,
  `""` through `empty_values`, `[]`) out of the changes, so to write it, cast with
  `force_changes: true` before validating (the default `changeset/3` does). Ecto does not
  force embeds: a `cast_embed/3` that clears an embed to a struct default that is the same
  (`nil` for `embeds_one`, `[]` for `embeds_many`) is not in the changes and is omitted.

  Values are dumped with `Ecto.Type.embedded_dump/3` as `:json` (uuid and similar types
  become strings); `:binary` values (and `{:array, :binary}` elements) become `\\x<hex>`
  text, the `bytea` input form, so any bytes round-trip. Absent keys stay absent and follow
  `missing=`.
  """

  alias PgRest.{Auth, Error, Request}
  alias PgRest.Authorization.Apply
  alias PgRest.Planner.Result

  @type built :: %{
          input: PgRest.SQL.Write.input(),
          columns: [String.t()],
          write_path: :fast | :changeset,
          count: non_neg_integer()
        }

  @doc """
  Builds the statement input of a write. `columns` is the parsed `columns=` list or `nil`;
  `operation` (`:create` or `:upsert`) is what a custom `changeset/3` sees in its context.
  `built.columns` are the source columns the statement writes.
  """
  @spec build(map(), Request.t(), [String.t()] | nil, map(), pos_integer(), :create | :upsert) ::
          {:ok, built()} | {:error, Error.t()}
  def build(config, %Request{} = request, columns, context, max_rows, operation \\ :create) do
    prepare(config, request, columns, max_rows, false, context, operation)
  end

  @doc """
  Builds the statement input of a `PATCH`: at most one object (an array of one is unwrapped;
  `[]`, `{}` and a scalar write nothing; several objects are a 400 `PGRST102`, a documented
  difference from PostgREST, which applies one of them arbitrarily). The columns to `SET` are
  the supplied payload keys, or `columns=`; they come back in `built.columns`.

  A custom `changeset/3` sees `operation: :update`. `:required` errors are dropped for fields
  the payload does not supply (a partial update), any other error is a 400. The columns set
  are the changeset's final changes, as described in the moduledoc.
  """
  @spec build_update(map(), Request.t(), [String.t()] | nil, map(), pos_integer()) ::
          {:ok, built()} | {:error, Error.t()}
  def build_update(config, %Request{} = request, columns, context, max_rows) do
    prepare(config, request, columns, max_rows, true, context, :update)
  end

  # One validation chain for every write; `single?` limits the payload to one object.
  defp prepare(config, request, columns, max_rows, single?, context, operation) do
    with {:ok, rows} <- rows(request.body, max_rows),
         :ok <- ensure_single(rows, single?),
         {:ok, keys} <- uniform_keys(rows, columns),
         :ok <- ensure_known(config, keys),
         :ok <- ensure_writable(config, keys, Auth.role(request)),
         :ok <-
           ensure_policy(
             config,
             keys,
             request.authorization_state.payload_columns,
             Auth.role(request)
           ),
         {:ok, built} <-
           input(config, %{
             rows: rows,
             keys: keys,
             columns: columns,
             request: request,
             context: context,
             operation: operation
           }) do
      {:ok, Map.put(built, :count, length(rows))}
    end
  end

  defp ensure_single(rows, true) when length(rows) > 1,
    do: {:error, Error.single_patch_object()}

  defp ensure_single(_rows, _single?), do: :ok

  # `payload`: the validated `rows` and their `keys`, the `columns=` list, the request and
  # the changeset `context` and `operation`.
  defp input(%{virtual_sources: sources} = config, payload) when map_size(sources) > 0,
    do: changesets(config, payload)

  defp input(%{custom_changeset?: true} = config, payload), do: changesets(config, payload)

  defp input(_config, %{request: request, keys: keys}),
    do: {:ok, %{input: raw(request, keys), columns: keys, write_path: :fast}}

  defp rows(body, _max) when is_map(body), do: {:ok, [body]}

  defp rows(body, max) when is_list(body) do
    if length(body) > max, do: {:error, Error.too_many_rows()}, else: {:ok, body}
  end

  defp rows(_body, _max), do: {:ok, []}

  @doc """
  The keys of a JSON payload's `rows` (a list of decoded elements): `columns` when given (the
  `columns=` list), else the keys every row shares. Every row must be an object (`PGRST102`,
  or Postgres' own `22023` when `columns=` lets a non-object through) and, without `columns=`,
  have the same keys (`PGRST102`).
  """
  @spec uniform_keys(list(), [String.t()] | nil) :: {:ok, [String.t()]} | {:error, Error.t()}
  def uniform_keys(rows, columns) do
    with :ok <- ensure_objects(rows, columns), do: keys(rows, columns)
  end

  # Postgres' own message when `columns=` lets a non-object element through.
  defp ensure_objects(rows, columns) do
    cond do
      Enum.all?(rows, &is_map/1) -> :ok
      columns == nil -> {:error, Error.keys_must_match()}
      true -> {:error, Error.not_objects()}
    end
  end

  defp keys(_rows, columns) when is_list(columns), do: {:ok, columns}
  defp keys([], nil), do: {:ok, []}

  defp keys([first | rest], nil) do
    keys = first |> Map.keys() |> Enum.sort()

    if Enum.all?(rest, &(&1 |> Map.keys() |> Enum.sort() == keys)),
      do: {:ok, keys},
      else: {:error, Error.keys_must_match()}
  end

  defp ensure_known(config, keys) do
    case Enum.find(keys, &(not Map.has_key?(config.input_fields, &1))) do
      nil -> :ok
      key -> {:error, Error.column_not_found(config.table, key)}
    end
  end

  defp ensure_writable(config, keys, role) do
    fields = Enum.map(keys, &Map.fetch!(config.input_fields, &1))
    ensure_keys(Apply.permits?(config.writable, fields), config, role)
  end

  defp ensure_policy(config, keys, columns, role),
    do: ensure_keys(Apply.permits?(columns, keys), config, role)

  defp ensure_keys(true, _config, _role), do: :ok
  defp ensure_keys(false, config, role), do: {:error, Error.table_denied(config, role)}

  defp raw(%Request{} = request, keys), do: {:raw, Request.body_bytes(request), keys}

  # --- changeset path ------------------------------------------------------------

  defp changesets(config, %{rows: rows, columns: columns, operation: operation} = payload) do
    context = Map.put(payload.context, :operation, operation)
    allowed = if columns, do: MapSet.new(columns)

    with {:ok, built} <- Result.map_ok(rows, &row(config, &1, allowed, context)),
         :ok <- ensure_uniform(built, operation),
         {:ok, {:raw, _json, written} = input} <- encode(built) do
      {:ok, %{input: input, columns: written, write_path: :changeset}}
    end
  end

  # An upsert `SET`s every payload column, so a change only some rows generate would write
  # `NULL` over the stored value of the others: the rows must agree, like payload keys.
  defp ensure_uniform(_rows, operation) when operation in [:create, :update], do: :ok

  defp ensure_uniform(rows, :upsert) do
    case rows |> Enum.map(&(&1 |> Map.keys() |> Enum.sort())) |> Enum.uniq() do
      [_one_shape_or_none] -> :ok
      [] -> :ok
      _different -> {:error, Error.keys_must_match()}
    end
  end

  defp row(config, row, allowed, context) do
    module = config.module
    payload = if allowed, do: Map.take(row, MapSet.to_list(allowed)), else: row

    attrs =
      Map.new(payload, fn {key, value} -> {Map.fetch!(config.input_fields, key), value} end)

    changeset =
      module
      |> struct()
      |> module.changeset(attrs, context)
      |> relax(Map.get(context, :operation), Map.keys(attrs))

    if changeset.valid?,
      do: dump(config, changeset, allowed),
      else: {:error, Error.invalid_payload(errors(changeset))}
  end

  # A partial update does not supply every field a `validate_required` names: those errors
  # are not the payload's fault. Any other error stays.
  defp relax(%{errors: errors} = changeset, :update, supplied) do
    kept =
      Enum.reject(errors, fn {field, {_message, options}} ->
        options[:validation] == :required and Atom.to_string(field) not in supplied
      end)

    if kept == errors, do: changeset, else: %{changeset | errors: kept, valid?: kept == []}
  end

  defp relax(changeset, _operation, _supplied), do: changeset

  # The final changes are the write intent: every changed field that is a persisted column
  # (and in `columns=`, when given) is written with its changeset value. `writable` gates only
  # client-supplied keys, already rejected (42501) before the changeset runs, so a change the
  # callback generates (`put_change/3`) is written even for a non-writable or redacted field.
  defp dump(config, changeset, allowed) do
    fields = for field <- Map.keys(changeset.changes), written?(config, field, allowed), do: field

    with {:ok, pairs} <- Result.map_ok(fields, &dump_field(config, changeset, &1)),
         do: {:ok, Map.new(pairs)}
  end

  defp written?(config, field, allowed) do
    case Map.fetch(config.field_sources, field) do
      {:ok, source} ->
        allowed == nil or MapSet.member?(allowed, source)

      :error ->
        false
    end
  end

  defp dump_field(config, changeset, field) do
    value = Ecto.Changeset.get_field(changeset, field)
    type = Map.fetch!(config.types, field)

    case dump_value(type, value) do
      {:ok, dumped} -> {:ok, {Map.fetch!(config.field_sources, field), dumped}}
      :error -> {:error, Error.invalid_payload("#{field}: is invalid")}
    end
  end

  # Binaries (and arrays of them) are hex text for `bytea`: JSON cannot carry arbitrary bytes.
  defp dump_value(:binary, value) when is_binary(value), do: {:ok, hex(value)}

  defp dump_value({:array, :binary}, values) when is_list(values),
    do: {:ok, Enum.map(values, &hex/1)}

  defp dump_value(type, value), do: Ecto.Type.embedded_dump(type, value, :json)

  defp hex(value) when is_binary(value), do: "\\x" <> Base.encode16(value, case: :lower)
  defp hex(other), do: other

  # One encode of every row, so a value Jason cannot encode is a 400, not a crash.
  defp encode(rows) do
    keys = rows |> Enum.flat_map(&Map.keys/1) |> Enum.uniq()
    {:ok, {:raw, Jason.encode!(rows), keys}}
  rescue
    _ in [Protocol.UndefinedError, Jason.EncodeError] ->
      {:error, Error.invalid_payload("payload: cannot be encoded as JSON")}
  end

  # "field: message, message; other: message", for `PostgrestError.details` (a string).
  defp errors(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, options} ->
      Enum.reduce(options, message, &interpolate/2)
    end)
    |> flatten_errors(nil)
    |> Enum.join("; ")
  end

  defp flatten_errors(errors, prefix) do
    Enum.flat_map(errors, fn
      {field, %{} = nested} ->
        flatten_errors(nested, join(prefix, field))

      {field, [%{} | _] = nested} ->
        Enum.flat_map(nested, &flatten_errors(&1, join(prefix, field)))

      {field, messages} ->
        ["#{join(prefix, field)}: #{Enum.join(messages, ", ")}"]
    end)
  end

  defp join(nil, field), do: to_string(field)
  defp join(prefix, field), do: "#{prefix}.#{field}"

  defp interpolate({key, value}, message)
       when is_binary(value) or is_number(value) or is_atom(value),
       do: String.replace(message, "%{#{key}}", to_string(value))

  defp interpolate(_option, message), do: message
end
