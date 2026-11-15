defmodule Mix.Tasks.Pgrest.Compat.Serve do
  @shortdoc "Serves the Supabase compat fixture on loopback for JS tests"
  @moduledoc """
  Rebuilds the existing compat fixtures and serves `PgRest.Compat.SupabaseRouter`.

      MIX_ENV=test mix pgrest.compat.serve [--port 54328]

  `PGREST_JS_PORT` supplies the default port. Binds only to `127.0.0.1`.
  Set `PGREST_COMPAT_JWT_SECRET` to match the test PostgREST service.
  """

  use Mix.Task

  alias PgRest.Compat.{Fixture, Scenario, SupabaseRouter}

  @requirements ["app.start"]

  @impl Mix.Task
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [port: :integer])

    if rest != [] or invalid != [],
      do: Mix.raise("usage: mix pgrest.compat.serve [--port 54328]")

    port = Keyword.get_lazy(opts, :port, &Fixture.js_port/0)
    :ok = Fixture.load!()

    children =
      Scenario.registries() ++ [{Bandit, plug: SupabaseRouter, ip: {127, 0, 0, 1}, port: port}]

    {:ok, _supervisor} = Supervisor.start_link(children, strategy: :one_for_one)
    Mix.shell().info("PgRest JS fixture: http://127.0.0.1:#{port}")
    Process.sleep(:infinity)
  end
end
