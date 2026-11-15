# Schema profiles (Accept-Profile / Content-Profile), ported from PostgREST's
# MultipleSchemaSpec onto the Supabase fixture's `public` and `personal` schemas.
rb = {"Prefer", "return=representation, tx=rollback"}

[
  %{
    id: "profiles/users-default-schema",
    fixture: :supabase,
    path: "/users?select=username&order=username"
  },
  %{
    id: "profiles/users-accept-public",
    fixture: :supabase,
    path: "/users?select=username&order=username",
    headers: [{"Accept-Profile", "public"}]
  },
  %{
    id: "profiles/users-accept-personal",
    fixture: :supabase,
    path: "/users?select=username&order=username",
    headers: [{"Accept-Profile", "personal"}]
  },
  %{
    id: "profiles/accept-unknown-schema",
    fixture: :supabase,
    path: "/users",
    headers: [{"Accept-Profile", "unknown"}]
  },
  %{
    id: "profiles/table-not-in-schema",
    fixture: :supabase,
    path: "/channels",
    headers: [{"Accept-Profile", "personal"}]
  },
  %{
    id: "profiles/insert-content-personal",
    fixture: :supabase,
    method: "POST",
    path: "/users?select=username",
    headers: [{"Content-Profile", "personal"}, rb],
    body: %{"username" => "profiled", "status" => "ONLINE"},
    stateful: true
  },
  %{
    id: "profiles/insert-accept-profile-ignored",
    fixture: :supabase,
    method: "POST",
    path: "/users?select=username",
    headers: [{"Accept-Profile", "personal"}, rb],
    body: %{"username" => "profiled"},
    stateful: true
  },
  %{
    id: "profiles/insert-content-unknown",
    fixture: :supabase,
    method: "POST",
    path: "/users?select=username",
    headers: [{"Content-Profile", "unknown"}, rb],
    body: %{"username" => "profiled"},
    stateful: true
  },
  %{
    id: "profiles/head-accept-personal",
    fixture: :supabase,
    method: "HEAD",
    path: "/users?select=username",
    headers: [{"Accept-Profile", "personal"}]
  },
  %{
    id: "profiles/update-content-personal",
    fixture: :supabase,
    method: "PATCH",
    path: "/users?username=eq.leroyjenkins&select=username,status",
    headers: [{"Content-Profile", "personal"}, rb],
    body: %{"status" => "OFFLINE"},
    stateful: true
  },
  %{
    id: "profiles/delete-content-personal",
    fixture: :supabase,
    method: "DELETE",
    path: "/user_notes?id=eq.2&select=note",
    headers: [{"Content-Profile", "personal"}, rb],
    stateful: true
  },
  %{
    id: "profiles/delete-content-unknown",
    fixture: :supabase,
    method: "DELETE",
    path: "/user_notes?id=eq.2",
    headers: [{"Content-Profile", "unknown"}, rb],
    stateful: true
  },
  %{
    id: "profiles/cross-schema-embed",
    fixture: :supabase,
    path: "/user_notes?select=note,users!user_notes_author_fkey(username)",
    headers: [{"Accept-Profile", "personal"}]
  },
  %{
    id: "profiles/same-schema-embed",
    fixture: :supabase,
    path: "/user_notes?select=note,users!user_notes_personal_author_fkey(username)&order=id",
    headers: [{"Accept-Profile", "personal"}]
  },
  %{
    id: "profiles/embed-into-other-schema",
    fixture: :supabase,
    path: "/users?select=username,user_notes(note)&order=username"
  },
  %{
    id: "profiles/single-schema-accept",
    path: "/items?id=eq.1",
    headers: [{"Accept-Profile", "test"}]
  },
  %{
    id: "profiles/single-schema-unknown",
    path: "/items?id=eq.1",
    headers: [{"Accept-Profile", "nope"}]
  }
]
