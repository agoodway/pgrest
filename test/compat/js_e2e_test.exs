defmodule PgRest.Compat.JsE2ETest do
  use ExUnit.Case, async: false

  alias PgRest.Compat.{Fixture, JWT, Scenario, SupabaseRouter}

  @moduletag :js
  @moduletag timeout: 120_000
  @js_dir Path.expand("../js", __DIR__)

  setup_all do
    Enum.each(Scenario.registries(), &start_supervised!/1)

    start_supervised!({Bandit, plug: SupabaseRouter, ip: {127, 0, 0, 1}, port: Fixture.js_port()})

    {:ok, urls: ["http://127.0.0.1:#{Fixture.js_port()}", Fixture.postgrest_url(:supabase)]}
  end

  test "Node signer matches the existing JWT helper" do
    claims = %{"role" => "authenticated", "sub" => "alice"}
    script = "import {sign} from './helpers.mjs'; console.log(sign(#{Jason.encode!(claims)}))"
    assert {output, 0} = System.cmd("node", ["--input-type=module", "-e", script], cd: @js_dir)
    assert String.trim(output) == JWT.sign(claims)
  end

  @tag :differential
  test "real client suite against PgRest then PostgREST", %{urls: urls} do
    run_pair(urls)
  end

  @tag :differential
  test "real client suite replays in reverse engine order", %{urls: urls} do
    run_pair(Enum.reverse(urls))
  end

  @tag :differential
  test "rollback advances sequences and reset restores client-generated ids", %{
    urls: [pgrest, upstream]
  } do
    reset_sequences()

    try do
      first = probe(pgrest)
      without_reset = probe(upstream)
      refute first == without_reset
      reset_sequences()
      assert first == probe(upstream)
      reset_sequences()
      assert first == probe(pgrest)
    after
      reset_sequences()
    end
  end

  defp run_pair(urls) do
    Enum.each(urls, fn url ->
      reset_sequences()
      assert {output, 0} = npm(["test"], url)
      assert output =~ ~r/(?:#|ℹ) tests [1-9][0-9]*/
      assert output =~ ~r/(?:#|ℹ) (?:fail|failures) 0/
    end)
  after
    reset_sequences()
  end

  defp probe(url) do
    assert {output, 0} = npm(["test", "--", "sequence_probe.test.mjs"], url)
    assert [_, id] = Regex.run(~r/sequence-probe-id=(\d+)/, output)
    String.to_integer(id)
  end

  defp npm(args, url) do
    System.cmd("npm", args, cd: @js_dir, env: [{"BASE_URL", url}], stderr_to_stdout: true)
  end

  defp reset_sequences, do: Fixture.reset_sequences!(Fixture.sequence_baseline(:supabase))
end
