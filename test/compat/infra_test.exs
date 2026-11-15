defmodule PgRest.Compat.InfraTest do
  use ExUnit.Case, async: true

  alias PgRest.Compat.{Fixture, Repo}

  @root Path.expand("../..", __DIR__)
  @list_item ~r/^\s*-\s*/
  @ports_key ~r/^\s*ports:\s*$/

  test "compat db is loaded and reachable" do
    assert %{rows: [[1]]} = Repo.query!("select 1 from test.items limit 1")
  end

  @tag :differential
  test "postgrest serves the fixture" do
    assert %{status: 200} = Req.get!(Fixture.postgrest_url() <> "/items?limit=1")

    assert %{status: 200} =
             Req.get!(Fixture.postgrest_url(:limits) <> "/items?limit=1")
  end

  describe "hygiene" do
    test "docker-compose binds loopback only, has no restart policy, and is labelled" do
      lines = @root |> Path.join("docker-compose.yml") |> File.read!() |> String.split("\n")

      assert hd(lines) =~ "TEST HARNESS ONLY"
      refute Enum.any?(lines, &(&1 =~ ~r/^\s*restart:/))

      ports = port_entries(lines)
      assert ports != []
      assert Enum.all?(ports, &String.starts_with?(&1, "127.0.0.1:"))
    end

    test "the pg-safeupdate Dockerfile pins a full commit sha" do
      dockerfile = @root |> Path.join("docker/pg-safeupdate.Dockerfile") |> File.read!()

      assert [_, ref] = Regex.run(~r/^ARG PG_SAFEUPDATE_REF=(\S+)$/m, dockerfile)
      assert ref =~ ~r/^[0-9a-f]{40}$/
    end

    test "every workflow action is pinned to a commit sha" do
      uses =
        for file <- Path.wildcard(Path.join(@root, ".github/workflows/*.yml")),
            line <- file |> File.read!() |> String.split("\n"),
            [_, ref] <- [Regex.run(~r/^\s*(?:-\s+)?uses:\s*(\S+)/, line)],
            do: ref

      assert uses != []
      assert Enum.all?(uses, &(&1 =~ ~r/@[0-9a-f]{40}$/))
    end

    test "JS runner is serial and workflow installs disable lifecycle scripts" do
      package = @root |> Path.join("test/js/package.json") |> File.read!() |> Jason.decode!()
      assert package["scripts"]["test"] == "node --test --test-concurrency=1"

      installs =
        for file <- Path.wildcard(Path.join(@root, ".github/workflows/*.yml")),
            line <- file |> File.read!() |> String.split("\n"),
            String.contains?(line, "npm ci"),
            do: line

      assert installs != []
      assert Enum.all?(installs, &String.contains?(&1, "--ignore-scripts"))
    end

    test "nimble_parsec is a compile-time-only dependency" do
      dep = List.keyfind(Mix.Project.config()[:deps], :nimble_parsec, 0)
      assert {:nimble_parsec, _req, opts} = dep
      assert opts[:runtime] == false
    end
  end

  defp port_entries(lines) do
    {entries, _in_ports?} =
      Enum.reduce(lines, {[], false}, fn line, {acc, in_ports?} ->
        cond do
          line =~ @ports_key -> {acc, true}
          in_ports? and line =~ @list_item -> {[strip_entry(line) | acc], true}
          true -> {acc, false}
        end
      end)

    Enum.reverse(entries)
  end

  defp strip_entry(line), do: line |> String.replace(@list_item, "") |> String.trim("\"")
end
