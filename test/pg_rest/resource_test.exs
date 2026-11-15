defmodule PgRest.ResourceTest do
  use ExUnit.Case
  import Ecto.Query

  alias PgRest.Compat.Resources.{Accounts, Items}

  alias PgRest.ResourceTest.{
    AccountsOwnChangeset,
    AccountsReadHashed,
    AccountsWriteEmail,
    ScopedNoPk
  }

  alias PgRest.Test.{NoDeleteOrder, Order, Product, ReadOnlyProduct}

  describe "__pgrest_resource__/0" do
    test "returns true for resource modules" do
      assert Order.__pgrest_resource__() == true
      assert Product.__pgrest_resource__() == true
    end
  end

  describe "__pgrest_config__/0" do
    test "returns config with module, table, fields" do
      config = Order.__pgrest_config__()

      assert config.module == Order
      assert config.table == "orders"
      assert :reference in config.fields
      assert :status in config.fields
      assert :total in config.fields
      assert config.primary_key == [:id]
    end

    test "non-resource modules don't have pgrest functions" do
      refute function_exported?(PgRest.Test.NonResource, :__pgrest_resource__, 0)
    end
  end

  describe "default callbacks" do
    test "scope/2 returns query unchanged by default" do
      query = Product
      assert Product.scope(query, %{}) == query
    end

    test "handle_param/4 returns query unchanged by default" do
      query = Product
      assert Product.handle_param("foo", "bar", query, %{}) == query
    end

    test "changeset/3 returns a changeset by default" do
      cs = Product.changeset(%Product{}, %{name: "test"}, %{})
      assert %Ecto.Changeset{} = cs
    end

    test "after_load/2 returns record unchanged by default" do
      record = %Product{name: "test"}
      assert Product.after_load(record, %{}) == record
    end
  end

  describe "overridden callbacks" do
    test "scope/2 can be overridden" do
      query = Order |> from(as: :order)
      scoped = Order.scope(query, %{tenant_id: 42})
      assert %Ecto.Query{} = scoped
    end
  end

  describe "allow option" do
    test "default allow is :all in config" do
      config = Product.__pgrest_config__()
      assert config.allow == :all
    end

    test "restricted allow stored correctly in config" do
      config = ReadOnlyProduct.__pgrest_config__()
      assert config.allow == [:read]

      config = NoDeleteOrder.__pgrest_config__()
      assert config.allow == [:read, :create, :update]
    end

    test "compile-time validation rejects invalid operations" do
      assert_raise ArgumentError, ~r/invalid operations in :allow option/, fn ->
        Code.compile_string("""
        defmodule PgRest.Test.InvalidOps do
          use Ecto.Schema
          use PgRest.Resource, allow: [:read, :invalid_op]

          schema "test" do
            field(:name, :string)
          end
        end
        """)
      end
    end

    test "compile-time validation rejects non-list/non-:all values" do
      assert_raise ArgumentError, ~r/invalid :allow option/, fn ->
        Code.compile_string("""
        defmodule PgRest.Test.InvalidAllow do
          use Ecto.Schema
          use PgRest.Resource, allow: "read"

          schema "test" do
            field(:name, :string)
          end
        end
        """)
      end
    end

    test "compile-time validation rejects empty list" do
      assert_raise ArgumentError, ~r/:allow option cannot be an empty list/, fn ->
        Code.compile_string("""
        defmodule PgRest.Test.EmptyAllow do
          use Ecto.Schema
          use PgRest.Resource, allow: []

          schema "test" do
            field(:name, :string)
          end
        end
        """)
      end
    end

    test "explicit :all is accepted" do
      config = Order.__pgrest_config__()
      assert config.allow == :all
    end
  end

  describe "new options and compile-time flags" do
    test "defaults" do
      config = Product.__pgrest_config__()

      assert config.custom_params == []
      assert config.after_load == false
      assert config.unique_key == nil
      assert config.relationships == []
      assert config.schema == "public"
      assert config.field_sources.name == "name"
      assert config.types.name == :string
    end

    test "schema comes from @schema_prefix" do
      assert Accounts.__pgrest_config__().schema == "test"
    end

    test "options are stored in config" do
      config = ScopedNoPk.__pgrest_config__()

      assert config.custom_params == ["q"]
      assert config.after_load == true
      assert config.unique_key == [:name]
    end

    test "custom_scope? is true only when the module defines scope/2" do
      assert Order.__pgrest_config__().custom_scope? == true
      assert Product.__pgrest_config__().custom_scope? == false
      assert Product.scope(Product, %{}) == Product
    end

    test "custom_changeset? is true only when the module defines changeset/3" do
      assert AccountsOwnChangeset.__pgrest_config__().custom_changeset? == true
      assert Accounts.__pgrest_config__().custom_changeset? == false
    end

    test "readable excludes redact fields unless listed explicitly" do
      assert "hashed_password" not in Accounts.__pgrest_config__().readable
      assert "email" in Accounts.__pgrest_config__().readable
      assert "hashed_password" in AccountsReadHashed.__pgrest_config__().readable

      assert MapSet.new(["id", "email", "hashed_password"]) ==
               AccountsReadHashed.__pgrest_config__().readable
    end

    test "default writable is every field except redact fields (primary keys included)" do
      assert Accounts.__pgrest_config__().writable ==
               MapSet.new(["id", "email", "role", "owner_id"])
    end

    test "restricted_columns? is true for accounts and false for items" do
      assert Accounts.__pgrest_config__().restricted_columns? == true
      assert Items.__pgrest_config__().restricted_columns? == false
    end

    test "default changeset ignores a supplied redact field" do
      cs = Accounts.changeset(struct(Accounts), %{email: "a@b.c", hashed_password: "x"}, %{})

      assert cs.changes == %{email: "a@b.c"}
    end

    test "default changeset casts the writable set only" do
      cs =
        AccountsWriteEmail.changeset(
          struct(AccountsWriteEmail),
          %{email: "a@b.c", role: "admin"},
          %{}
        )

      assert cs.changes == %{email: "a@b.c"}
    end

    test "unknown readable and writable field names fail compilation" do
      for opt <- ["readable: [:nope]", "writable: [:id, :nope]"] do
        assert_raise ArgumentError, ~r/nope/, fn ->
          Code.compile_string("""
          defmodule PgRest.Test.BadColumns#{System.unique_integer([:positive])} do
            use Ecto.Schema
            use PgRest.Resource, #{opt}

            schema "accounts" do
              field(:email, :string)
            end
          end
          """)
        end
      end
    end

    test "invalid option values are rejected" do
      assert_raise ArgumentError, ~r/:readable/, fn ->
        Code.compile_string("""
        defmodule PgRest.Test.BadReadable do
          use Ecto.Schema
          use PgRest.Resource, readable: "all"
          schema "test" do
            field(:name, :string)
          end
        end
        """)
      end
    end
  end

  describe "relationships and unique_key validation" do
    defp compile_with(opts) do
      Code.compile_string("""
      defmodule PgRest.Test.RelValidation#{System.unique_integer([:positive])} do
        use Ecto.Schema
        use PgRest.Resource, #{opts}

        schema "accounts" do
          field(:email, :string)
          belongs_to(:owner, PgRest.Test.Order)
        end
      end
      """)
    end

    test "unknown association key" do
      assert_raise ArgumentError, ~r/neither an association/, fn ->
        compile_with("relationships: [nope: [constraint: \"x\"]]")
      end
    end

    test "unknown override key" do
      assert_raise ArgumentError, ~r/unknown keys/, fn ->
        compile_with("relationships: [owner: [x: 1]]")
      end
    end

    test "unknown kind" do
      assert_raise ArgumentError, ~r/unknown kind :sideways/, fn ->
        compile_with("relationships: [r: [kind: :sideways]]")
      end
    end

    test "missing required keys" do
      assert_raise ArgumentError, ~r/missing required keys \[:columns, :constraint\]/, fn ->
        compile_with("relationships: [r: [kind: :m2o, target: String]]")
      end

      assert_raise ArgumentError, ~r/missing required keys \[:junction\]/, fn ->
        compile_with("relationships: [r: [kind: :m2m, target: String]]")
      end

      assert_raise ArgumentError, ~r/missing required keys \[:constraints\]/, fn ->
        compile_with(
          ~s(relationships: [r: [kind: :m2m, target: String, junction: [table: "j", schema: "s", source_columns: [], target_columns: []]]])
        )
      end
    end

    test "unknown unique_key field" do
      assert_raise ArgumentError, ~r/:unique_key.*nope/, fn ->
        compile_with("unique_key: [:nope]")
      end
    end

    test "explicit declarations reject unknown keys" do
      assert_raise ArgumentError, ~r/unknown keys \[:constriant\]/, fn ->
        compile_with(
          ~s(relationships: [r: [kind: :m2o, target: String, columns: [], constraint: "x", constriant: "y"]])
        )
      end
    end

    test "a non-keyword junction is a clear error" do
      assert_raise ArgumentError, ~r/:junction must be a keyword list/, fn ->
        compile_with(~s(relationships: [r: [kind: :m2m, target: String, junction: "j"]]))
      end

      assert_raise ArgumentError, ~r/:junction must be a keyword list/, fn ->
        compile_with(~s(relationships: [r: [kind: :m2m, target: String, junction: [1, 2]]]))
      end
    end

    test "a non-keyword relationship entry is a clear error" do
      assert_raise ArgumentError, ~r/keyword list of keyword lists/, fn ->
        compile_with(~s(relationships: [r: :m2m]))
      end

      assert_raise ArgumentError, ~r/keyword list of keyword lists/, fn ->
        compile_with(~s(relationships: [r: [1, 2]]))
      end
    end
  end
end
