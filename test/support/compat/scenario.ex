defmodule PgRest.Compat.Scenario do
  @moduledoc """
  Golden scenarios: loading, running against PgRest or live PostgREST, and the
  recorded-expectation format.

  A scenario file `test/compat/scenarios/<area>.exs` evaluates to a list of maps
  with these keys (all but `:id` optional):

    * `:id` - `"<area>/<name>"`, unique
    * `:method` (`"GET"`), `:path`, `:headers` (`[{name, value}]`), `:body`
      (`nil`, a binary, or a term sent as JSON)
    * `:sort` - compare top-level arrays order-insensitively
    * `:response_headers` - lowercase names of the custom response headers the scenario
      asserts (`["x-test", "set-cookie"]`, default `[]`). They are recorded and compared in
      addition to the semantic allowlist (`PgRest.Compat.Compare.diff/3` `headers:`). Named
      apart from `:headers`, which are the request's.
    * `:plug_opts` - merged into the `PgRest.Plug` options
    * `:only` - `:both` (default) or `:pgrest`; `:pgrest` scenarios carry an inline
      `expect: %{status:, headers:, body:}`
    * `:server` - `:default` or `:limits`; `:limits` runs against the limits
      PostgREST and merges `max_limit: 2, aggregates: false` into the PgRest options. Only valid with
      `fixture: :test`
    * `:fixture` - `:test` (default), `:supabase` or `:supabase_scope`. It selects the
      PgRest router, the PostgREST server and the sequence baseline of the stateful
      protocol: `:test` is `PgRest.Compat.Router` / `pgrest_compat`, `:supabase` is
      `PgRest.Compat.SupabaseRouter` / `pgrest_supabase`, and `:supabase_scope` is
      `PgRest.Compat.SupabaseScopeRouter` against the same PostgREST and baseline as
      `:supabase`
    * `:compare` - `:exact` (default) or `:plan`; `:plan` checks the shape of a query
      plan instead of its text (see `PgRest.Compat.Compare.diff/3`)
    * `:stateful` - required for any method but GET/HEAD/OPTIONS, which must also
      send `Prefer: tx=rollback`. A `POST /rpc/...` is the exception: it needs neither, and
      gets `Prefer: tx=rollback` added unless it is explicitly `stateful: true`
      with `Prefer: tx=commit`. Commit cases must leave fixture data unchanged (for
      example, an error that rolls back); sequence resets do not restore committed rows

  Responses are `%{status:, headers: %{name => value | [value]}, body: binary}` (a repeated
  header is the list of its values in wire order). Recorded
  files (`test/compat/expected/<area>.json`) store `%{id => %{"status", "headers",
  "body"}}` where `body` is `nil` when empty, the decoded term for JSON content
  types (a JSON `null` body as `{"$json": null}`), and the raw string otherwise.
  """

  alias PgRest.Compat.{Compare, Fixture, Functions, Router, SupabaseRouter}

  @compat_dir Path.expand("../../compat", __DIR__)
  @scenario_dir Path.join(@compat_dir, "scenarios")
  @expected_dir Path.join(@compat_dir, "expected")
  @pending_file Path.join(@compat_dir, "pending.txt")

  @defaults %{
    method: "GET",
    path: "/",
    headers: [],
    body: nil,
    sort: false,
    response_headers: [],
    plug_opts: [],
    only: :both,
    server: :default,
    fixture: :test,
    compare: :exact,
    stateful: false
  }
  @known_keys [:id, :expect | Map.keys(@defaults)]
  @read_methods ~w(GET HEAD OPTIONS)
  @req_methods %{
    "GET" => :get,
    "HEAD" => :head,
    "OPTIONS" => :options,
    "POST" => :post,
    "PATCH" => :patch,
    "PUT" => :put,
    "DELETE" => :delete
  }
  # The limits PostgREST also runs with `db-aggregates-enabled = false`.
  @limits_plug_opts [max_limit: 2, aggregates: false]
  @compares [:exact, :plan]
  @routers %{
    test: Router,
    supabase: SupabaseRouter,
    supabase_scope: PgRest.Compat.SupabaseScopeRouter
  }
  @fixtures Map.keys(@routers)
  # The PostgREST server and the sequence-baseline database of each fixture; `:test` keeps
  # the scenario's own `:server` (`:default` or `:limits`).
  @postgrest_servers %{supabase: :supabase, supabase_scope: :supabase}
  @baseline_fixtures %{test: :test, supabase: :supabase, supabase_scope: :supabase}

  # How a recording stores a JSON body that is `null`; `nil` means an empty body.
  @json_null %{"$json" => nil}

  @type t :: map()
  @type response :: Compare.response()

  @doc """
  Child specs of the registries the compat routers serve: the default `PgRest.Registry` over
  the `test` fixture and `PgRest.Compat.SupabaseRegistry` over the Supabase fixture
  (`public` first, then `personal`, as `PGRST_DB_SCHEMAS`). The `test` registry introspects
  the ported fixture functions (`PgRest.Compat.Functions.test_functions/0`, an explicit
  `only:` list); the Supabase registry introspects every function in `mode: :rls`, for the
  RLS-mode `PgRest.Compat.SupabaseRouter`.
  """
  @spec registries() :: [{module(), keyword()}]
  def registries do
    [
      {PgRest.Registry,
       modules: PgRest.Compat.Resources.all(),
       introspect: [repo: PgRest.Compat.Repo, only: Functions.test_functions()]},
      {PgRest.Registry,
       name: PgRest.Compat.SupabaseRegistry,
       modules: PgRest.Compat.Supabase.Resources.all(),
       schemas: ["public", "personal"],
       introspect: [repo: PgRest.Compat.SupabaseRepo, mode: :rls]},
      {PgRest.Registry,
       name: PgRest.Compat.SupabaseScopeRegistry,
       schemas: ["public", "personal"],
       modules: [PgRest.Compat.SupabaseScope.RlsNote, PgRest.Compat.SupabaseScope.PrivateDoc],
       introspect: [
         repo: PgRest.Compat.SupabaseRepo,
         mode: :app,
         authorization: PgRest.Compat.SupabaseScopeAuthorization
       ]}
    ]
  end

  @doc "Area names, one per scenario file."
  @spec areas() :: [String.t()]
  def areas do
    @scenario_dir
    |> Path.join("*.exs")
    |> Path.wildcard()
    |> Enum.map(&Path.basename(&1, ".exs"))
    |> Enum.sort()
  end

  @doc "Loads and validates the scenarios of one area."
  @spec load(String.t()) :: [t()]
  def load(area) do
    {scenarios, _binding} = @scenario_dir |> Path.join("#{area}.exs") |> Code.eval_file()

    build!(scenarios, area)
  end

  @doc false
  @spec build!([map()], String.t()) :: [t()]
  def build!(scenarios, area) do
    scenarios = Enum.map(scenarios, &normalize!(&1, area))
    ids = Enum.map(scenarios, & &1.id)

    if ids != Enum.uniq(ids), do: raise(ArgumentError, "duplicate scenario ids in area #{area}")

    scenarios
  end

  @doc "Scenario ids PgRest cannot serve yet (`test/compat/pending.txt`)."
  @spec pending() :: [String.t()]
  def pending do
    case File.read(@pending_file) do
      {:ok, text} ->
        text
        |> String.split("\n", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
        |> Enum.uniq()

      {:error, :enoent} ->
        []
    end
  end

  @doc "Path of the recorded expectations of an area."
  @spec expected_path(String.t()) :: String.t()
  def expected_path(area), do: Path.join(@expected_dir, "#{area}.json")

  @doc "Reads the recorded expectations of an area as `%{id => stored}`."
  @spec read_expected(String.t()) :: %{String.t() => map()}
  def read_expected(area) do
    path = expected_path(area)

    case File.read(path) do
      {:ok, json} ->
        Jason.decode!(json)

      {:error, _} ->
        raise "no recorded expectations at #{path}; run `MIX_ENV=test mix pgrest.compat.record #{area}`"
    end
  end

  @doc "The expected response of a scenario, as a wire response."
  @spec expected_response(t(), %{String.t() => map()}) :: response()
  def expected_response(%{only: :pgrest, expect: expect}, _recorded) do
    from_stored(%{
      "status" => expect.status,
      "headers" => expect |> Map.get(:headers, %{}) |> downcase_keys(),
      "body" => Map.get(expect, :body)
    })
  end

  def expected_response(%{id: id}, recorded) do
    case Map.fetch(recorded, id) do
      {:ok, stored} -> from_stored(stored)
      :error -> raise "scenario #{id} has no recorded expectation; re-run the recorder"
    end
  end

  defp downcase_keys(headers),
    do: Map.new(headers, fn {name, value} -> {String.downcase(name), value} end)

  @doc "Converts a wire response into the recorded form; `extra_headers` are a scenario's `:response_headers`."
  @spec to_stored(response(), [String.t()]) :: map()
  def to_stored(%{status: status, headers: headers, body: body}, extra_headers \\ []) do
    %{
      "status" => status,
      "headers" => Map.take(headers, Compare.semantic_headers() ++ extra_headers),
      "body" => stored_body(headers, body)
    }
  end

  defp stored_body(_headers, ""), do: nil

  defp stored_body(headers, body) do
    if Compare.json_content_type?(headers), do: json_body(Jason.decode!(body)), else: body
  end

  # A JSON `null` body (an RPC returning NULL) must not read back as an empty one.
  defp json_body(nil), do: @json_null
  defp json_body(decoded), do: decoded

  defp from_stored(%{"status" => status, "headers" => headers, "body" => body}) do
    %{status: status, headers: headers, body: wire_body(headers, body)}
  end

  defp wire_body(_headers, nil), do: ""
  defp wire_body(_headers, @json_null), do: "null"

  defp wire_body(headers, body) do
    if Compare.json_content_type?(headers), do: Jason.encode!(body), else: body
  end

  @doc "Runs a scenario in-process against the router of its fixture."
  @spec run_pgrest(t()) :: response()
  def run_pgrest(scenario) do
    {headers, body} = request_parts(scenario)

    conn =
      scenario.method
      |> Plug.Test.conn(scenario.path, body)
      |> Plug.Conn.put_private(:pgrest_compat_plug_opts, pgrest_plug_opts(scenario))

    # Appended, not replaced: a request may repeat a header (two `Prefer` lines).
    conn =
      Enum.reduce(headers, conn, fn {k, v}, acc ->
        %{acc | req_headers: acc.req_headers ++ [{String.downcase(k), v}]}
      end)

    router = Map.fetch!(@routers, scenario.fixture)
    conn = router.call(conn, router.init([]))

    if conn.state != :sent, do: raise("PgRest did not send a response for #{scenario.id}")

    %{
      status: conn.status,
      headers: header_map(conn.resp_headers),
      body: IO.iodata_to_binary(conn.resp_body)
    }
  end

  @doc "Runs a scenario against live PostgREST."
  @spec run_postgrest(t()) :: response()
  def run_postgrest(scenario) do
    {headers, body} = request_parts(scenario)

    response =
      Req.request!(
        method: Map.fetch!(@req_methods, scenario.method),
        url: Fixture.postgrest_url(postgrest_server(scenario)) <> scenario.path,
        headers: headers,
        body: body,
        decode_body: false,
        compressed: false,
        retry: false,
        redirect: false
      )

    %{
      status: response.status,
      headers: header_map(response.headers),
      body: IO.iodata_to_binary(response.body)
    }
  end

  @doc "The sequence baseline of a scenario's fixture database."
  @spec baseline_for(t()) :: Fixture.baseline()
  def baseline_for(%{fixture: fixture}),
    do: @baseline_fixtures |> Map.fetch!(fixture) |> Fixture.sequence_baseline()

  @doc """
  Runs a scenario against one engine between two sequence resets of its fixture's
  database, so rolled-back writes leave no sequence drift. The trailing reset runs even
  when the run raises. The engine is `:pgrest`, `:postgrest` or a one-argument runner.
  """
  @spec run_isolated(:pgrest | :postgrest | (t() -> response()), t()) :: response()
  def run_isolated(engine, scenario) do
    baseline = baseline_for(scenario)
    Fixture.reset_sequences!(baseline)

    try do
      run_engine(engine, scenario)
    after
      Fixture.reset_sequences!(baseline)
    end
  end

  @doc "Runs a scenario against each engine in `order`, isolated from one another."
  @spec run_both(t(), [:pgrest | :postgrest]) :: %{atom() => response()}
  def run_both(scenario, order \\ [:pgrest, :postgrest]) do
    Map.new(order, &{&1, run_isolated(&1, scenario)})
  end

  @doc """
  The scenarios of an area paired with their expected responses, as
  `{scenario, expected}`. `stateful?` selects the stateful or the stateless half.
  """
  @spec recorded_scenarios(String.t(), boolean()) :: [{t(), response()}]
  def recorded_scenarios(area, stateful?) do
    recorded = read_expected(area)

    for scenario <- load(area), scenario.stateful == stateful? do
      {scenario, expected_response(scenario, recorded)}
    end
  end

  @doc "Runs a scenario against live PostgREST, isolated when it is stateful."
  @spec run_live(t()) :: response()
  def run_live(%{stateful: true} = scenario), do: run_isolated(:postgrest, scenario)
  def run_live(scenario), do: run_postgrest(scenario)

  @doc """
  Runs a scenario against PgRest and PostgREST and returns `{pgrest, postgrest}`.

  `only: :pgrest` scenarios pair PgRest with their inline expectation instead.
  """
  @spec run_pair(t()) :: {response(), response()}
  def run_pair(scenario) do
    cond do
      scenario.only == :pgrest ->
        {run_pgrest(scenario), expected_response(scenario, %{})}

      scenario.stateful ->
        %{pgrest: pgrest, postgrest: postgrest} = run_both(scenario)
        {pgrest, postgrest}

      true ->
        {run_pgrest(scenario), run_postgrest(scenario)}
    end
  end

  @doc "Runs a scenario against one engine."
  @spec run_engine(:pgrest | :postgrest | (t() -> response()), t()) :: response()
  def run_engine(:pgrest, scenario), do: run_pgrest(scenario)
  def run_engine(:postgrest, scenario), do: run_postgrest(scenario)
  def run_engine(runner, scenario) when is_function(runner, 1), do: runner.(scenario)

  defp postgrest_server(%{fixture: :test, server: server}), do: server
  defp postgrest_server(%{fixture: fixture}), do: Map.fetch!(@postgrest_servers, fixture)

  defp pgrest_plug_opts(%{server: :limits, plug_opts: opts}),
    do: Keyword.merge(opts, @limits_plug_opts)

  defp pgrest_plug_opts(%{plug_opts: opts}), do: opts

  defp request_parts(%{headers: headers, body: body}) do
    headers = Enum.map(headers, fn {k, v} -> {String.downcase(k), v} end)

    case body do
      nil -> {headers, nil}
      binary when is_binary(binary) -> {headers, binary}
      term -> {put_default_content_type(headers), Jason.encode!(term)}
    end
  end

  defp put_default_content_type(headers) do
    if List.keymember?(headers, "content-type", 0),
      do: headers,
      else: [{"content-type", "application/json"} | headers]
  end

  # A name to its value, or to the ordered list of its values when it is repeated (two
  # `Set-Cookie`s), so a merged `"a, b"` is not mistaken for two headers.
  defp header_map(headers) do
    headers
    |> Enum.flat_map(fn {name, values} ->
      Enum.map(List.wrap(values), &{String.downcase(name), &1})
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn
      {name, [value]} -> {name, value}
      {name, values} -> {name, values}
    end)
  end

  defp normalize!(scenario, area) do
    case Map.keys(scenario) -- @known_keys do
      [] -> :ok
      unknown -> raise ArgumentError, "unknown scenario keys #{inspect(unknown)}"
    end

    scenario = @defaults |> Map.merge(scenario) |> rpc_rollback()
    validate!(scenario, area)
    scenario
  end

  defp validate!(%{id: <<_::binary>> = id} = scenario, area) do
    check!(
      String.starts_with?(id, area <> "/"),
      "scenario id #{inspect(id)} must start with \"#{area}/\""
    )

    validate_method!(scenario)
    validate_fixture!(scenario)
    validate_compare!(scenario)
    validate_only!(scenario)
    validate_mutation!(scenario)
  end

  defp validate!(_scenario, area), do: raise(ArgumentError, "scenario in #{area} has no :id")

  defp validate_method!(%{method: method}) when is_map_key(@req_methods, method), do: :ok

  defp validate_method!(%{id: id, method: method}),
    do: raise(ArgumentError, "#{id}: unknown method #{inspect(method)}")

  defp validate_fixture!(%{id: id, fixture: fixture}) when fixture not in @fixtures,
    do: raise(ArgumentError, "#{id}: unknown fixture #{inspect(fixture)}")

  defp validate_fixture!(%{id: id, server: :limits, fixture: fixture}) when fixture != :test,
    do: raise(ArgumentError, "#{id}: `server: :limits` needs `fixture: :test`")

  defp validate_fixture!(_scenario), do: :ok

  defp validate_compare!(%{id: id, compare: compare}) when compare not in @compares,
    do: raise(ArgumentError, "#{id}: unknown compare mode #{inspect(compare)}")

  defp validate_compare!(_scenario), do: :ok

  defp validate_only!(%{only: :pgrest, expect: %{status: _} = expect, id: id}),
    do: validate_expect!(expect, id)

  defp validate_only!(%{only: :both} = s) when not is_map_key(s, :expect), do: :ok

  defp validate_only!(%{id: id}),
    do: raise(ArgumentError, "#{id}: `only: :pgrest` needs `expect:` (and `:both` forbids it)")

  defp validate_expect!(expect, id) do
    headers = Map.get(expect, :headers, %{})

    check!(
      is_map(headers) and Enum.all?(Map.keys(headers), &is_binary/1),
      "#{id}: expect headers must be a map with string keys"
    )

    body = Map.get(expect, :body)

    check!(
      is_nil(body) or is_binary(body) or json_content_type?(headers),
      "#{id}: a term body in expect needs a JSON content-type header"
    )
  end

  defp json_content_type?(headers) do
    headers
    |> Map.new(fn {name, value} -> {String.downcase(name), value} end)
    |> Compare.json_content_type?()
  end

  defp validate_mutation!(%{method: method}) when method in @read_methods, do: :ok

  # `rpc_rollback/1` already added `Prefer: tx=rollback`.
  defp validate_mutation!(%{method: "POST", path: "/rpc/" <> _function, stateful: false}),
    do: :ok

  defp validate_mutation!(
         %{method: "POST", path: "/rpc/" <> _function, stateful: true, headers: headers} =
           scenario
       ) do
    if Enum.any?(headers, fn {name, value} ->
         String.downcase(name) == "prefer" and
           "tx=commit" in String.split(value, [",", " "], trim: true)
       end),
       do: :ok,
       else: validate_rollback!(scenario)
  end

  defp validate_mutation!(%{stateful: true} = scenario), do: validate_rollback!(scenario)

  defp validate_mutation!(%{id: id}),
    do: raise(ArgumentError, "#{id}: mutating scenarios must set `stateful: true`")

  defp validate_rollback!(%{id: id, headers: headers}) do
    check!(
      Enum.any?(headers, &rollback_header?/1),
      "#{id}: mutating scenarios must send `Prefer: tx=rollback`"
    )
  end

  # A stateless POST to /rpc runs the function, so every such scenario rolls back (both PostgREST servers
  # and the compat routers allow `tx=rollback`): none can change the shared fixture, whatever the
  # function's volatility. A stateless one needs no `stateful: true` for that.
  defp rpc_rollback(%{method: "POST", path: "/rpc/" <> _function, stateful: false} = scenario) do
    Map.update!(scenario, :headers, fn headers ->
      if Enum.any?(headers, &rollback_header?/1),
        do: headers,
        else: headers ++ [{"prefer", "tx=rollback"}]
    end)
  end

  defp rpc_rollback(scenario), do: scenario

  defp rollback_header?({name, value}),
    do: String.downcase(name) == "prefer" and String.contains?(value, "tx=rollback")

  defp check!(true, _message), do: :ok
  defp check!(false, message), do: raise(ArgumentError, message)
end
