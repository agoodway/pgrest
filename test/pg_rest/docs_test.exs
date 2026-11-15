defmodule PgRest.DocsTest do
  use ExUnit.Case, async: true

  @guide "docs/guides/upgrading-0.1-to-0.2.md"

  describe "upgrade guide" do
    test "opens with the security note right after the title" do
      headings =
        @guide
        |> File.read!()
        |> String.split("\n")
        |> Enum.filter(&String.starts_with?(&1, "#"))

      assert [
               "# Upgrading from 0.1 to 0.2",
               "## Security note" <> _ | _
             ] = headings
    end
  end

  describe "user-facing docs" do
    test "carry no superuser anon role, credentials or JWT secrets" do
      files = ["README.md", "CHANGELOG.md" | Path.wildcard("docs/guides/*.md")]

      for file <- files, text = File.read!(file) do
        refute text =~ "PGRST_DB_ANON_ROLE=postgres", "#{file} shows a superuser anon role"
        refute text =~ "postgres:postgres@", "#{file} shows a password"
        refute text =~ ~r/secret:\s*["'~]/, "#{file} shows a secret literal"
        refute text =~ "reallyreally", "#{file} shows the test harness JWT secret"
      end
    end
  end
end
