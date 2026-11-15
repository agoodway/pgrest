defmodule PgRest.RepoCallsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias PgRest.Compat.{Repo, Resources}
  alias PgRest.Test.TelemetryProbe

  @sentinel "SENTINEL-7f3a"

  setup do
    start_supervised!({PgRest.Registry, modules: Resources.all()})
    :ok
  end

  defp call(path, headers \\ []) do
    conn =
      Enum.reduce(headers, Plug.Test.conn("GET", path), fn {k, v}, c ->
        Plug.Conn.put_req_header(c, k, v)
      end)

    PgRest.Plug.call(conn, PgRest.Plug.init(repo: Repo))
  end

  test "filter values reach neither repo query events nor the log" do
    TelemetryProbe.attach([:pg_rest, :compat, :repo, :query])

    log =
      capture_log([level: :debug], fn ->
        assert %{status: 200} = call("/clients?name=eq.#{@sentinel}&select=id,name")

        assert %{status: 200} =
                 call("/clients?or=(name.eq.#{@sentinel},id.eq.1)", [{"prefer", "count=exact"}])

        assert %{status: status} =
                 call("/clients?name=eq.#{@sentinel}", [{"prefer", "count=planned"}])

        assert status in [200, 206]
      end)

    events = TelemetryProbe.drain()
    refute inspect(events) =~ @sentinel
    refute log =~ @sentinel
  end

  test "any repo query event PgRest produces is marked pgrest: true" do
    TelemetryProbe.attach([:pg_rest, :compat, :repo, :query])
    assert %{status: 200} = call("/clients?select=id")

    events = TelemetryProbe.drain()
    assert events != []

    for {_event, _measurements, meta} <- events do
      assert meta.options[:pgrest] == true
    end
  end

  test "PgRest's own query span replaces them, without parameter values" do
    TelemetryProbe.attach([:pgrest, :query, :stop])
    assert %{status: 200} = call("/clients?name=eq.#{@sentinel}")

    events = TelemetryProbe.drain()
    assert Enum.any?(events, fn {_e, _m, meta} -> meta.params_count == 1 end)
    refute inspect(events) =~ @sentinel
  end
end
