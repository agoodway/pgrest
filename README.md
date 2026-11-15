# PgRest

[![Hex.pm](https://img.shields.io/hexpm/v/pgrest.svg)](https://hex.pm/packages/pgrest)
[![Hex Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/pgrest)
[![License](https://img.shields.io/hexpm/l/pgrest.svg)](https://github.com/agoodway/pgrest/blob/main/LICENSE)

> A PostgREST-compatible REST API powered by Elixir and Ecto, differential-tested against PostgREST v14.

PgRest serves the PostgREST HTTP API that `@supabase/postgrest-js` speaks, from
your own Phoenix or Plug app. Your Ecto schemas are the contract: each request
is parsed into an AST and compiled to one parameterized SQL statement per read,
with your `scope/2` callbacks (tenancy, soft deletes) applied to the root and
every embed. It is a Plug that runs in your BEAM process on your Ecto repo; there
is no sidecar service. Compatibility is measured, not assumed: a differential
suite replays scenarios against a pinned PostgREST.

Requires Elixir 1.19+, PostgreSQL with an Ecto repository and a Plug-based
application.

## Installation

Add `pgrest` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:pgrest, "~> 0.2.0"}
  ]
end
```

Then fetch dependencies:

```bash
mix deps.get
```

## Quick Start

### 1. Define a resource

```elixir
defmodule MyApp.API.Tasks do
  use Ecto.Schema
  use PgRest.Resource, custom_params: ["search"]
  import Ecto.Query

  schema "tasks" do
    field :title, :string
    field :status, :string
    field :due_date, :date
    field :deleted_at, :utc_datetime
    field :internal_notes, :string, redact: true
    belongs_to :project, MyApp.API.Projects
    timestamps()
  end

  # Optional: always-applied query scope (tenant isolation, soft deletes)
  @impl PgRest.Resource
  def scope(query, _context), do: where(query, [t], is_nil(t.deleted_at))

  # Optional: custom URL params (?search=foo), declared in `use` above
  @impl PgRest.Resource
  def handle_param("search", value, query, _context) do
    where(query, [t], ilike(t.title, ^"%#{value}%"))
  end

  def handle_param(_, _, query, _), do: query
end
```

### 2. Start the registry

```elixir
children = [
  MyApp.Repo,
  {PgRest.Registry, otp_app: :my_app}
]
```

### 3. Mount the plug

```elixir
# Phoenix router
forward "/api", PgRest.Plug, repo: MyApp.Repo

# Plug.Router
forward "/api", to: PgRest.Plug, init_opts: [repo: MyApp.Repo]
```

### 4. Query with any PostgREST client

```javascript
import { PostgrestClient } from '@supabase/postgrest-js'

const api = new PostgrestClient('http://localhost:4000/api')

const { data } = await api
  .from('tasks')
  .select('title,status,project(name)')
  .eq('status', 'pending')
  .order('due_date', { ascending: true })
  .limit(10)
```

Or with plain HTTP:

```
GET /api/tasks?status=eq.pending&select=title,status,project(name)&order=due_date.asc&limit=10
```

## Demo

[`demo/`](https://github.com/agoodway/pgrest/tree/main/demo) is a Phoenix
LiveView query explorer. It runs example queries against seeded data with
`@supabase/postgrest-js` and shows the client code, generated SQL, response and
timing for each.

```bash
bin/pgrest start      # Hivemind, serves localhost:4042
bin/pgrest stop
bin/pgrest console    # remote shell into the demo node
```

Or without Hivemind: `cd demo && mix setup && mix phx.server`.

## Documentation

- [Configuration](docs/guides/configuration.md): plug options, registry, body parsing, statement timeout, repo logging
- [Resources](docs/guides/resources.md): resource options, `allow:`, schema prefixes, column exposure, security notes
- [Functions and RPC](docs/guides/rpc.md): declarations, introspection, scoped results and response overrides
- [Authorization and RLS](docs/guides/authorization-and-rls.md): policies, roles and security boundaries
- [Compatibility](docs/guides/compatibility.md): supported operations, request pipeline, known differences from PostgREST
- [Telemetry](docs/guides/telemetry.md): events and metadata
- [Testing](docs/guides/testing.md): the docker compose test harness
- [Upgrading from 0.1 to 0.2](docs/guides/upgrading-0.1-to-0.2.md)
- [CHANGELOG](CHANGELOG.md)
- [HexDocs](https://hexdocs.pm/pgrest) for the API reference

## Development

```bash
docker compose up -d db
mix test
mix quality
```

## License

MIT
