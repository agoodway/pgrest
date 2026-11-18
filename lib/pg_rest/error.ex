defmodule PgRest.Error do
  @moduledoc """
  A PostgREST-shaped error: HTTP status plus the `code`, `message`, `details` and
  `hint` body fields. `headers` are response headers the error carries: `PgRest.Responder`
  sends them without adding an authentication challenge. A headerless PgRest 401
  defaults to `www-authenticate: Bearer`; `custom_headers?: true` preserves an empty
  custom RAISE header map without that default.

  ## Differences from PostgREST

  Changeset validation errors return 400/23514 with string details; PostgREST has
  no application changesets.
  """

  defexception [
    :status,
    :code,
    :message,
    details: nil,
    hint: nil,
    headers: [],
    custom_headers?: false
  ]

  @type t :: %__MODULE__{
          status: pos_integer(),
          code: String.t(),
          message: String.t(),
          details: String.t() | [map()] | map() | nil,
          hint: String.t() | nil,
          headers: [{String.t(), String.t()}],
          custom_headers?: boolean()
        }

  @doc "Malformed response GUC (PGRST111 headers or PGRST112 status)."
  @spec response_guc(:headers | :status) :: t()
  def response_guc(:headers),
    do: %__MODULE__{
      status: 500,
      code: "PGRST111",
      message:
        "response.headers guc must be a JSON array composed of objects with a single key and a string value"
    }

  def response_guc(:status),
    do: %__MODULE__{
      status: 500,
      code: "PGRST112",
      message: "response.status guc must be a valid status code"
    }

  @doc """
  Builds a 400 `PGRST100` error, the code PostgREST uses for unparseable request text.
  """
  @spec parse_error(String.t(), String.t() | nil) :: t()
  def parse_error(message, details \\ nil),
    do: %__MODULE__{status: 400, code: "PGRST100", message: message, details: details}

  @doc """
  `42501` for a table or a function the request may not use: `permission denied for table
  <name>` or `permission denied for function <name>`, 401 for `:anon` and 403 otherwise (the
  responder adds `www-authenticate: Bearer` to a 401).
  """
  @spec permission_denied(:table | :function, String.t(), :anon | :authenticated) :: t()
  def permission_denied(kind, name, role \\ :anon) when kind in [:table, :function] do
    %__MODULE__{
      status: denied_status(role),
      code: "42501",
      message: "permission denied for #{kind} #{name}"
    }
  end

  @doc "A table denial for a resource/config and request context or resolved role."
  @spec table_denied(module() | map(), map() | :anon | :authenticated) :: t()
  def table_denied(%{table: table}, role) when is_atom(role),
    do: permission_denied(:table, table, role)

  def table_denied(%{table: _} = config, context),
    do: table_denied(config, PgRest.Auth.role(context))

  def table_denied(resource, context), do: table_denied(resource.__pgrest_config__(), context)

  defp denied_status(:anon), do: 401
  defp denied_status(_authenticated), do: 403

  @doc "PostgREST's `42703` for a column the table does not have."
  @spec unknown_column(String.t(), String.t(), String.t() | nil) :: t()
  def unknown_column(table_alias, column, hint \\ nil) do
    %__MODULE__{
      status: 400,
      code: "42703",
      message: "column #{table_alias}.#{column} does not exist",
      hint: hint
    }
  end

  @doc """
  `22P02` for a filter value the column's type rejects, raised before the query reaches
  Postgres (`PgRest.Ecto.Filter` casts values with the Ecto field type).
  """
  @spec invalid_input(String.t(), term()) :: t()
  def invalid_input(column, value) do
    %__MODULE__{
      status: 400,
      code: "22P02",
      message: ~s|invalid input syntax for column "#{column}": #{shown_value(value)}|
    }
  end

  defp shown_value(value) when is_binary(value), do: ~s|"#{value}"|
  defp shown_value(value), do: inspect(value)

  @doc "Postgres' own `42703` for a bare column name (an `on_conflict=` target)."
  @spec undefined_column(String.t()) :: t()
  def undefined_column(column),
    do: %__MODULE__{status: 400, code: "42703", message: ~s|column "#{column}" does not exist|}

  @doc "`PGRST108`: an embedded parameter names an embed that is not in the select."
  @spec not_embedded(String.t()) :: t()
  def not_embedded(name) do
    %__MODULE__{
      status: 400,
      code: "PGRST108",
      message: "'#{name}' is not an embedded resource in this request",
      hint: "Verify that '#{name}' is included in the 'select' query parameter."
    }
  end

  @doc "`PGRST107`: none of the `Accept` media types is supported."
  @spec unsupported_media([String.t()]) :: t()
  def unsupported_media(types) do
    %__MODULE__{
      status: 406,
      code: "PGRST107",
      message: "None of these media types are available: " <> Enum.join(types, ", ")
    }
  end

  @doc "`PGRST116`: a single object was requested and the result has `count` rows."
  @spec single_object(non_neg_integer()) :: t()
  def single_object(count) do
    %__MODULE__{
      status: 406,
      code: "PGRST116",
      message: "Cannot coerce the result to a single JSON object",
      details: "The result contains #{count} rows"
    }
  end

  @doc "`PGRST103`: the requested offset is past the known total."
  @spec offset_out_of_bounds(non_neg_integer(), non_neg_integer()) :: t()
  def offset_out_of_bounds(offset, total) do
    %__MODULE__{
      status: 416,
      code: "PGRST103",
      message: "Requested range not satisfiable",
      details: "An offset of #{offset} was requested, but there are only #{total} rows."
    }
  end

  @doc "`PGRST125`: the path is not `/<table>`."
  @spec invalid_path() :: t()
  def invalid_path,
    do: %__MODULE__{
      status: 404,
      code: "PGRST125",
      message: "Invalid path specified in request URL"
    }

  @doc """
  `PGRST202`: no function matches the request (404). `keys` are the argument names the request
  carries; `post?` adds the single-unnamed-parameter alternative to the details.
  """
  @spec function_not_found(String.t(), String.t(), [String.t()], boolean(), String.t() | nil) ::
          t()
  def function_not_found(schema, name, keys, post?, hint) do
    qualified = "#{schema}.#{name}"

    %__MODULE__{
      status: 404,
      code: "PGRST202",
      message: "Could not find the function #{qualified}#{signature(keys)} in the schema cache",
      details:
        "Searched for the function #{qualified}#{searched(keys)}" <>
          if(post?, do: " or with a single unnamed json/jsonb parameter", else: "") <>
          ", but no matches were found in the schema cache.",
      hint: hint
    }
  end

  defp signature([]), do: " without parameters"
  defp signature(keys), do: "(#{Enum.join(keys, ", ")})"

  defp searched([]), do: " without parameters"
  defp searched([key]), do: " with parameter #{key}"
  defp searched(keys), do: " with parameters #{Enum.join(keys, ", ")}"

  @doc """
  `PGRST202` for a POST whose body is not JSON: only a function with one unnamed parameter of
  `type` (`text`, `xml` or `bytea`) can take it, so no argument names are reported.
  """
  @spec function_not_found_unnamed(String.t(), String.t(), String.t()) :: t()
  def function_not_found_unnamed(schema, name, type) do
    qualified = "#{schema}.#{name}"

    %__MODULE__{
      status: 404,
      code: "PGRST202",
      message: "Could not find the function #{qualified} in the schema cache",
      details:
        "Searched for the function #{qualified} with a single unnamed #{type} parameter, " <>
          "but no matches were found in the schema cache."
    }
  end

  @doc """
  `PGRST203`: several functions match equally well (300). `candidates` are the `schema.name(arg =>
  type, ...)` texts.
  """
  @spec ambiguous_function([String.t()]) :: t()
  def ambiguous_function(candidates) do
    %__MODULE__{
      status: 300,
      code: "PGRST203",
      message:
        "Could not choose the best candidate function between: " <> Enum.join(candidates, ", "),
      hint:
        "Try renaming the parameters or the function itself in the database so function " <>
          "overloading can be resolved"
    }
  end

  @doc "`PGRST117`: the HTTP method is not supported."
  @spec unsupported_method(String.t()) :: t()
  def unsupported_method(method),
    do: %__MODULE__{status: 405, code: "PGRST117", message: "Unsupported HTTP method: #{method}"}

  @doc "`PGRST101`: an RPC request with a method other than GET, HEAD or POST (405)."
  @spec rpc_method_not_allowed(String.t()) :: t()
  def rpc_method_not_allowed(method),
    do: %__MODULE__{
      status: 405,
      code: "PGRST101",
      message: "Cannot use the #{method} method on RPC"
    }

  @doc """
  `PGRST200`: no relationship from `parent` to the embed `name` in `schema`. `using` is the
  request's embed hint, `hint` the suggestion (both may be `nil`).
  """
  @spec no_relationship(String.t(), String.t(), String.t(), String.t() | nil, String.t() | nil) ::
          t()
  def no_relationship(schema, parent, name, using \\ nil, hint \\ nil) do
    using = if using, do: "' using the hint '#{using}", else: ""

    %__MODULE__{
      status: 400,
      code: "PGRST200",
      message:
        "Could not find a relationship between '#{parent}' and '#{name}' in the schema cache",
      details:
        "Searched for a foreign key relationship between '#{parent}' and '#{name}#{using}' " <>
          "in the schema '#{schema}', but no matches were found.",
      hint: hint
    }
  end

  @doc "`PGRST106`: an `Accept-Profile`/`Content-Profile` naming a schema that is not exposed (406)."
  @spec invalid_schema(String.t(), [String.t()]) :: t()
  def invalid_schema(schema, exposed) do
    %__MODULE__{
      status: 406,
      code: "PGRST106",
      message: "Invalid schema: #{schema}",
      hint: "Only the following schemas are exposed: " <> Enum.join(exposed, ", ")
    }
  end

  @doc "`PGRST002`: the schema cache (the registry snapshot) is not available yet (503)."
  @spec schema_cache_not_ready() :: t()
  def schema_cache_not_ready do
    %__MODULE__{
      status: 503,
      code: "PGRST002",
      message: "Could not query the database for the schema cache. Retrying."
    }
  end

  @doc "`PGRST205`: no such table in the schema cache."
  @spec table_not_found(String.t(), String.t(), String.t() | nil) :: t()
  def table_not_found(schema, table, hint \\ nil) do
    %__MODULE__{
      status: 404,
      code: "PGRST205",
      message: "Could not find the table '#{schema}.#{table}' in the schema cache",
      hint: hint
    }
  end

  @doc "`PGRST204`: a payload or `columns=` name is not a column of the table."
  @spec column_not_found(String.t(), String.t()) :: t()
  def column_not_found(table, column) do
    %__MODULE__{
      status: 400,
      code: "PGRST204",
      message: "Could not find the '#{column}' column of '#{table}' in the schema cache"
    }
  end

  @doc "`PGRST102`: the rows of a bulk payload do not all have the same keys."
  @spec keys_must_match() :: t()
  def keys_must_match,
    do: %__MODULE__{status: 400, code: "PGRST102", message: "All object keys must match"}

  @doc "A bulk payload with more rows than `max_bulk_rows` (413, Postgres `54000`)."
  @spec too_many_rows() :: t()
  def too_many_rows,
    do: %__MODULE__{status: 413, code: "54000", message: "payload exceeds max_bulk_rows"}

  @doc """
  A 400 `23514` for a payload the resource's `changeset/3` (or the column types) rejects, as
  a Postgres check violation would be. `details` is a string (`field: message; ...`), the
  type `PostgrestError.details` has. PgRest only: PostgREST has no changesets.
  """
  @spec invalid_payload(String.t()) :: t()
  def invalid_payload(details),
    do: %__MODULE__{status: 400, code: "23514", message: "invalid payload", details: details}

  @doc """
  `21000`: a `PATCH` or `DELETE` without a filter while `require_filters_for_mutations` is on.
  The status, code and message are those of Supabase's `pg-safeupdate`.
  """
  @spec where_required(:update | :delete) :: t()
  def where_required(kind) do
    verb = kind |> Atom.to_string() |> String.upcase()
    %__MODULE__{status: 400, code: "21000", message: "#{verb} requires a WHERE clause"}
  end

  @doc "`PGRST102`: a `PATCH` payload that is an array of more than one object. A documented difference:
  PostgREST applies one of the objects arbitrarily."
  @spec single_patch_object() :: t()
  def single_patch_object, do: multiple_objects("PATCH takes one object, not an array of several")

  @doc "`PGRST123`: an aggregate in `select=` while aggregates are disabled."
  @spec aggregates_not_allowed() :: t()
  def aggregates_not_allowed,
    do: %__MODULE__{
      status: 400,
      code: "PGRST123",
      message: "Use of aggregate functions is not allowed"
    }

  @doc """
  `PGRST127`: an aggregate inside a spread that cannot hoist it: a one-to-many or many-to-many
  spread (as PostgREST), or a spread over a resource with `after_load/2`, whose columns are merged
  after the query (PgRest only).
  """
  @spec spread_aggregate_not_implemented(:to_many | :after_load) :: t()
  def spread_aggregate_not_implemented(kind),
    do: %__MODULE__{
      status: 400,
      code: "PGRST127",
      message: "Feature not implemented",
      details: "Aggregates are not implemented for #{spread_kind(kind)}."
    }

  defp spread_kind(:to_many), do: "one-to-many or many-to-many spreads"
  defp spread_kind(:after_load), do: "spreads of resources with after_load/2"

  @doc "`PGRST118`: `order=<relation>(<column>)` on an embed that is not to-one."
  @spec related_order_not_possible(String.t(), String.t()) :: t()
  def related_order_not_possible(table, relation) do
    %__MODULE__{
      status: 400,
      code: "PGRST118",
      message: "A related order on '#{relation}' is not possible",
      details: "'#{table}' and '#{relation}' do not form a many-to-one or one-to-one relationship"
    }
  end

  @doc "`PGRST102`: a request body that is not JSON."
  @spec invalid_json() :: t()
  def invalid_json,
    do: %__MODULE__{status: 400, code: "PGRST102", message: "Empty or invalid json"}

  @doc "`PGRST102`: the request body could not be read."
  @spec unreadable_body() :: t()
  def unreadable_body,
    do: %__MODULE__{status: 400, code: "PGRST102", message: "Could not read the request body"}

  @doc "A body larger than `max_body_bytes` (413, Postgres `54000`)."
  @spec body_too_large() :: t()
  def body_too_large,
    do: %__MODULE__{status: 413, code: "54000", message: "request body exceeds max_body_bytes"}

  @doc "`22023`: Postgres' own message when `columns=` lets a non-object element through."
  @spec not_objects() :: t()
  def not_objects do
    %__MODULE__{
      status: 400,
      code: "22023",
      message: "argument of json_to_recordset must be an array of objects"
    }
  end

  @doc "`PGRST103`: an unsatisfiable `Range` header or a negative `limit`."
  @spec invalid_range(String.t()) :: t()
  def invalid_range(details) do
    %__MODULE__{
      status: 416,
      code: "PGRST103",
      message: "Requested range not satisfiable",
      details: details
    }
  end

  @doc "`PGRST114`: `limit`/`offset` on a `PUT`."
  @spec put_limit_not_allowed() :: t()
  def put_limit_not_allowed do
    %__MODULE__{
      status: 400,
      code: "PGRST114",
      message: "limit/offset querystring parameters are not allowed for PUT"
    }
  end

  @doc "`PGRST105`: a `PUT` whose filters are not exactly an `eq` on every primary key column (405)."
  @spec put_filters_not_key() :: t()
  def put_filters_not_key do
    %__MODULE__{
      status: 405,
      code: "PGRST105",
      message: "Filters must include all and only primary key columns with 'eq' operators"
    }
  end

  @doc "`PGRST115`: no payload row of a `PUT` has the URL's primary key values."
  @spec put_payload_mismatch() :: t()
  def put_payload_mismatch do
    %__MODULE__{
      status: 400,
      code: "PGRST115",
      message: "Payload values do not match URL in primary key column(s)"
    }
  end

  @doc "`PGRST102`: a `PUT` payload with several objects that match the URL's key. A documented difference: PostgREST fails with a 500 `21000`."
  @spec single_put_object() :: t()
  def single_put_object,
    do: multiple_objects("PUT takes one row, but several payload objects match the URL")

  defp multiple_objects(message),
    do: %__MODULE__{status: 400, code: "PGRST102", message: message}

  @doc "`PGRST000`: PostgREST's 503 for a failed database connection; the driver's text is not sent."
  @spec connection_error() :: t()
  def connection_error,
    do: %__MODULE__{status: 503, code: "PGRST000", message: "Database connection error."}

  @doc "`PGRST003`: no pool connection within the queue timeout (504)."
  @spec pool_timeout() :: t()
  def pool_timeout do
    %__MODULE__{
      status: 504,
      code: "PGRST003",
      message: "Timed out acquiring connection from connection pool."
    }
  end

  @doc "`PGRST122`: `handling=strict` and `tokens` are not valid preferences."
  @spec invalid_preferences([String.t()]) :: t()
  def invalid_preferences(tokens) do
    %__MODULE__{
      status: 400,
      code: "PGRST122",
      message: "Invalid preferences given with handling=strict",
      details: "Invalid preferences: " <> Enum.join(tokens, ", ")
    }
  end

  @doc "`PGRST124`: `handling=strict` and the statement affected more than `max-affected` rows."
  @spec max_affected_exceeded(non_neg_integer()) :: t()
  def max_affected_exceeded(count) do
    %__MODULE__{
      status: 400,
      code: "PGRST124",
      message: "Query result exceeds max-affected preference constraint",
      details: "The query affects #{count} rows"
    }
  end

  @doc """
  `PGRST128`: `handling=strict` with `max-affected` on a function that does not return a set.
  """
  @spec max_affected_rpc() :: t()
  def max_affected_rpc do
    %__MODULE__{
      status: 400,
      code: "PGRST128",
      message:
        "Function must return SETOF or TABLE when max-affected preference is used with handling=strict"
    }
  end

  @doc "A generic 500 for a configuration problem; the cause is logged, never sent."
  @spec internal() :: t()
  def internal, do: %__MODULE__{status: 500, code: "PGRSTX00", message: "Internal server error"}

  @doc "The write check failed: a written row is outside the resource's scope."
  @spec check_violation(String.t(), :anon | :authenticated) :: t()
  def check_violation(table, role \\ :anon) do
    %__MODULE__{
      status: denied_status(role),
      code: "42501",
      message: ~s|new row violates row-level security policy for table "#{table}"|
    }
  end

  @doc """
  A 401 for a token that cannot be used: `PGRST301` (`:decode`, the token is malformed or its
  signature is wrong) or `PGRST303` (`:claims`, a claim is invalid), with PostgREST's
  `www-authenticate: Bearer error="invalid_token", error_description="<message>"`.
  """
  @spec invalid_token(:decode | :claims, String.t(), String.t() | nil) :: t()
  def invalid_token(kind, message, details \\ nil) do
    %__MODULE__{
      status: 401,
      code: if(kind == :decode, do: "PGRST301", else: "PGRST303"),
      message: message,
      details: details,
      headers: [
        {"www-authenticate", ~s|Bearer error="invalid_token", error_description="#{message}"|}
      ]
    }
  end

  @doc "PostgREST's 401 `PGRST302`: a request without a token where anonymous access is off."
  @spec token_required() :: t()
  def token_required,
    do: %__MODULE__{status: 401, code: "PGRST302", message: "Anonymous access is disabled"}

  @doc "Postgres' `22023` for a role that does not exist, which PostgREST answers with a 401."
  @spec unknown_role(String.t()) :: t()
  def unknown_role(role),
    do: %__MODULE__{status: 401, code: "22023", message: ~s|role "#{role}" does not exist|}

  @doc """
  Returns the JSON body map. All four keys are always present; `nil` encodes as
  JSON `null`.
  """
  @spec to_body(t()) :: %{String.t() => String.t() | [map()] | map() | nil}
  def to_body(%__MODULE__{} = error) do
    %{
      "code" => error.code,
      "message" => error.message,
      "details" => error.details,
      "hint" => error.hint
    }
  end
end
