# PgRest Demo

Interactive query explorer for [PgRest](../), the PostgREST-compatible REST API layer for Elixir

A Phoenix LiveView app that demonstrates PgRest with a seeded project/task database. Each example query runs live against the API using `@supabase/postgrest-js`, showing the client code, generated SQL, JSON response, and timing.

## What It Demonstrates

- **Filtering** — `eq`, `neq`, `gte`, `lt`, `is`, `ilike`, `in`, array `contains`
- **Ordering and pagination** — `order`, `limit`, `offset`
- **Field selection** — Choose which columns to return
- **Relationship embedding** — `has_many` and `belongs_to` preloads via `select=name,tasks(title)`
- **Inner joins** — `select=*,project!inner(name)` with association filters
- **Embedded filters and ordering** — Filter and sort nested records
- **Custom parameters** — App-specific `?search=` param declared with `custom_params: ["search"]` and handled by `handle_param/4`
- **Filtering your own Ecto queries** — `GET /ecto/tasks?status=in.(pending,in_progress)` and `or=(priority.eq.high,complexity.lt.3)` parse PostgREST filters with `PgRest.Grammar.Filter` and apply them with `PgRest.Ecto.Filter` (see `Demo.Tasks`), with no `PgRest.Plug` involved

## Prerequisites

- Elixir 1.15+
- PostgreSQL running locally
- Node.js (for frontend assets)

## Setup

```bash
# Install dependencies, create database, run migrations, seed data, build assets
mix setup
```

This runs `deps.get`, `ecto.setup` (create + migrate + seed 7 projects and 120 tasks), `assets.setup`, and `assets.build`.

The demo depends on the local PgRest checkout (`{:pgrest, path: ".."}`).

## Running

```bash
mix phx.server
```

Visit [localhost:4042](http://localhost:4042). Click any query example to execute it live.

## How It Works

The demo defines two PgRest resources:

- **Projects** — `name`, `status`, `budget`, `deadline`, with `has_many :tasks`
- **Tasks** — `title`, `status`, `priority`, `tags` (array), `complexity`, with `belongs_to :project`

Both are read-only (`allow: [:read]`) and declare `custom_params: ["search"]`, handled by `handle_param/4`. Tasks use `scope/2` to exclude soft-deleted records.

The API is mounted at `/api` via `PgRest.Plug`. The frontend uses `@supabase/postgrest-js` to build queries exactly as you would against a real PostgREST or Supabase instance. A debug plug captures the generated SQL via the `[:pgrest, :query, :stop]` telemetry event and returns it in a response header for display.

## Project Structure

```
demo/
  lib/demo/
    tasks.ex           # Ecto queries filtered with PgRest.Ecto.Filter
    projects/          # Project schema + PgRest resource
    tasks/             # Task schema + PgRest resource
  lib/demo_web/
    live/home_live.ex  # Interactive query explorer
    plugs/             # SqlDebug, ServerTiming, ReadOnlyApi
    router.ex          # /api → PgRest.Plug, /ecto/tasks → PgRest.Ecto.Filter
  priv/repo/
    seeds.exs          # 7 projects, 120 tasks
  assets/js/
    app.js             # postgrest-js hook, SQL formatting, syntax highlighting
```
