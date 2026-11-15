# Scope-mode parity with the RLS fixture; no request-GUC scenarios.
{rls, _} = Code.eval_file(Path.join(__DIR__, "rls.exs"))

base =
  rls
  |> Enum.take(13)
  |> Enum.map(fn scenario ->
    scenario
    |> Map.put(:fixture, :supabase_scope)
    |> Map.update!(:id, &String.replace_prefix(&1, "rls/", "authorization/"))
  end)

alice =
  {"authorization",
   "Bearer " <> PgRest.Compat.JWT.sign(%{"role" => "authenticated", "sub" => "alice"})}

base ++
  for {name, body} <- [
        {"check-details", %{owner: "alice", slug: "long-body", body: String.duplicate("x", 101)}},
        {"unique-details", %{owner: "alice", slug: "a1", body: "duplicate"}}
      ] do
    %{
      id: "authorization/" <> name,
      fixture: :supabase_scope,
      method: "POST",
      path: "/rls_notes",
      headers: [alice, {"prefer", "tx=rollback"}],
      body: body,
      stateful: true
    }
  end
