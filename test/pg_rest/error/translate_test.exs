defmodule PgRest.Error.TranslateTest do
  use ExUnit.Case, async: true

  alias PgRest.Error
  alias PgRest.Error.Translate

  test "PT699 preserves a nonstandard three-digit status" do
    exception = %Postgrex.Error{postgres: %{pg_code: "PT699", message: "custom state"}}
    assert %Error{status: 699, code: "PT699"} = Translate.from_exception(exception, :anon)
  end

  test "PT402 carries the Postgres fields" do
    exception = %Postgrex.Error{
      postgres: %{
        pg_code: "PT402",
        message: "Payment Required",
        detail: "Quota exceeded",
        hint: "Upgrade your plan"
      }
    }

    assert %Error{
             status: 402,
             code: "PT402",
             message: "Payment Required",
             details: "Quota exceeded",
             hint: "Upgrade your plan"
           } = Translate.from_exception(exception, :anon)
  end

  test "PGRST decodes status, body and custom headers" do
    exception = %Postgrex.Error{
      postgres: %{
        pg_code: "PGRST",
        message: ~s|{"code":"123","message":"ABC","details":"DEF","hint":"XYZ"}|,
        detail: ~s|{"status":402,"headers":{"X-Powered-By":"Nerd Rage"}}|
      }
    }

    assert %Error{
             status: 402,
             code: "123",
             message: "ABC",
             details: "DEF",
             hint: "XYZ",
             headers: [{"X-Powered-By", "Nerd Rage"}]
           } = Translate.from_exception(exception, :anon)
  end

  test "invalid PGRST message returns PGRST121" do
    exception = %Postgrex.Error{
      postgres: %{pg_code: "PGRST", message: "INVALID", detail: ~s|{"status":402,"headers":{}}|}
    }

    assert %Error{
             status: 500,
             code: "PGRST121",
             details: "Invalid JSON value for MESSAGE: 'INVALID'"
           } = Translate.from_exception(exception, :anon)
  end
end
