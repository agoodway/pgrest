defmodule PgRest.Compat.Functions do
  @moduledoc """
  Module-declared `PgRest.Function`s for the compat fixtures.
  """

  defmodule GetStatus do
    @moduledoc "Declares `public.get_status(name_param text)` of the Supabase fixture."
    use PgRest.Function,
      schema: "public",
      name: "get_status",
      params: [{"name_param", "text"}],
      returns: {:scalar, "user_status"},
      volatility: :immutable
  end

  @doc """
  The Supabase fixture functions a non-RLS (`mode: :app`) registry leaves out (`except:`):
  they read the role, JWT claims or request GUCs, which only RLS mode sets.
  """
  @spec supabase_excluded() :: [String.t()]
  def supabase_excluded, do: ~w(privileged_hello whoami request_info check_request)

  @doc """
  The `test` fixture functions the compat registry exposes (its explicit `only:` list).
  """
  @spec test_functions() :: [String.t()]
  def test_functions do
    ~w(getallprojects getproject setprojects getitemrange add_them sayhello noparamsproc
       unnamed_json_param named_json_param overloaded_same_args overloaded_enum_arg
       variadic_param single_out_param single_inout_param many_out_params ret_void callcounter
       make_project scoped_projects fabricated_projects reowned_projects sleep_for
       get_projects_and_guc_headers get_int_and_guc_headers bad_guc_headers_1 bad_guc_headers_2
       bad_guc_headers_3 set_cookie_twice send_body_status_403 send_bad_status guc_status
       status_then_raise guc_headers_raw guc_both_bad delete_items_returns_setof delete_items_returns_table
       delete_items_returns_void overloaded_unnamed_param raise_pt402 raise_sqlstate_test1
       raise_sqlstate_test2 raise_sqlstate_test3 raise_sqlstate_test4
       raise_sqlstate_invalid_json_message raise_sqlstate_invalid_json_details raise_sqlstate_missing_details UpperEcho typed_echo partially_unnamed raise_payload raise_state)
  end
end
