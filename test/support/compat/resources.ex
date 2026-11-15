defmodule PgRest.Compat.Resources do
  @moduledoc """
  Ecto resource modules for every table in the compat fixture schema `test`.

  Composite foreign keys have no `belongs_to` (Ecto reflects one key per association);
  they are declared with the `relationships:` option. Constraint names that differ from
  the `<table>_<column>_fkey` default are overridden the same way.
  """

  @modules Enum.map(
             ~w(Sponsors Competitors ForeignItems NullableKeyView Unicode Items ComplexItems Clients Projects Tasks Users UsersTasks Comments Files TouchedFiles Students StudentsInfo Country Capital FamilyTree Managers Organizations Addresses Orders Entities ChildEntities GrandchildEntities Tsearch Ranges CompoundPk NoPk Employees OnlyPk UnitTest WebContent CarBrands CarModels Timestamps TiobePls AmbigA AmbigB AmbigAb NullableFkParent NullableFkChild CsvEdge CsvEdgeCases DefaultsDemo TypeCases Accounts SafeUpdateItems SafeDeleteItems UnsafeUpdateItems UnsafeDeleteItems Stuff LocTest PgrestAfterLoc PutGuc PutNumeric Trash TrashDetails ProjectInvoices BudgetCategories BudgetExpenses Factories ProcessCategories Processes ProcessCosts Supervisors ProcessSupervisor FactoryBuildings)a,
             &Module.concat(__MODULE__, &1)
           )

  @doc "Every compat resource module."
  @spec all() :: [module()]
  def all, do: @modules

  defmodule Raw do
    @moduledoc """
    Passthrough Ecto type for Postgres types Ecto has no native type for
    (`tsvector`, `int4range`). Values are whatever Postgrex returns.
    """
    use Ecto.Type

    @impl Ecto.Type
    def type, do: :any

    @impl Ecto.Type
    def cast(value), do: {:ok, value}

    @impl Ecto.Type
    def load(value), do: {:ok, value}

    @impl Ecto.Type
    def dump(value), do: {:ok, value}
  end

  defmodule Sponsors do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource

    @schema_prefix "test"
    schema "sponsors" do
      has_many(:competitors, PgRest.Compat.Resources.Competitors, foreign_key: :sponsor_id)
    end
  end

  defmodule Competitors do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource

    @schema_prefix "test"
    schema "competitors" do
      field(:full_name, :string)
      belongs_to(:sponsor, PgRest.Compat.Resources.Sponsors)
    end
  end

  defmodule ForeignItems do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource

    @schema_prefix "test"
    schema "sweep_foreign_items" do
    end
  end

  defmodule NullableKeyView do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource

    @primary_key false
    @schema_prefix "test"
    schema "test_null_pk_competitors_sponsors" do
      field(:id, :integer, primary_key: true)
      field(:sponsor_id, :integer, primary_key: true)
    end
  end

  defmodule Unicode do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource

    @schema_prefix "test"
    @primary_key {:هویت, :integer, autogenerate: false}
    schema "موارد" do
    end
  end

  defmodule Items do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource

    @schema_prefix "test"
    schema "items" do
    end
  end

  defmodule ComplexItems do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource

    @primary_key {:id, :id, autogenerate: false}
    @schema_prefix "test"
    schema "complex_items" do
      field(:name, :string)
      field(:settings, :map)
      field(:arr_data, {:array, :integer})
      field(:"field-with_sep", :integer, default: 1)
      field(:tags, {:array, :string})
    end
  end

  defmodule Clients do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource, relationships: [projects: [constraint: "client"]]

    @primary_key {:id, :integer, autogenerate: false}
    @schema_prefix "test"
    schema "clients" do
      field(:name, :string)
      has_many(:projects, PgRest.Compat.Resources.Projects, foreign_key: :client_id)
    end
  end

  defmodule Projects do
    @moduledoc false
    use Ecto.Schema

    use PgRest.Resource,
      relationships: [client: [constraint: "client"], tasks: [constraint: "project"]]

    @primary_key {:id, :integer, autogenerate: false}
    @schema_prefix "test"
    schema "projects" do
      field(:name, :string)
      belongs_to(:client, PgRest.Compat.Resources.Clients, type: :integer)
      has_many(:tasks, PgRest.Compat.Resources.Tasks, foreign_key: :project_id)
    end
  end

  defmodule Tasks do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource, relationships: [project: [constraint: "project"]]

    @primary_key {:id, :integer, autogenerate: false}
    @schema_prefix "test"
    schema "tasks" do
      field(:name, :string)
      belongs_to(:project, PgRest.Compat.Resources.Projects, type: :integer)

      many_to_many(:users, PgRest.Compat.Resources.Users,
        join_through: "users_tasks",
        join_keys: [task_id: :id, user_id: :id]
      )
    end
  end

  defmodule Users do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource, relationships: [comments: [constraint: "user"]]

    @primary_key {:id, :integer, autogenerate: false}
    @schema_prefix "test"
    schema "users" do
      field(:name, :string)
      has_many(:comments, PgRest.Compat.Resources.Comments, foreign_key: :commenter_id)

      many_to_many(:tasks, PgRest.Compat.Resources.Tasks,
        join_through: "users_tasks",
        join_keys: [user_id: :id, task_id: :id]
      )
    end
  end

  defmodule UsersTasks do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource
    @primary_key false
    @schema_prefix "test"
    schema "users_tasks" do
      belongs_to(:user, PgRest.Compat.Resources.Users, type: :integer, primary_key: true)
      belongs_to(:task, PgRest.Compat.Resources.Tasks, type: :integer, primary_key: true)
    end
  end

  defmodule Comments do
    @moduledoc false
    use Ecto.Schema

    use PgRest.Resource,
      relationships: [
        commenter: [constraint: "user"],
        users_tasks: [
          kind: :m2o,
          target: PgRest.Compat.Resources.UsersTasks,
          columns: [{"task_id", "task_id"}, {"user_id", "user_id"}],
          constraint: "comments_task_id_fkey"
        ]
      ]

    @primary_key {:id, :integer, autogenerate: false}
    @schema_prefix "test"
    schema "comments" do
      field(:user_id, :integer)
      field(:content, :string)
      belongs_to(:commenter, PgRest.Compat.Resources.Users, type: :integer)
      field(:task_id, :integer)
    end
  end

  defmodule Files do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource

    @primary_key false
    @schema_prefix "test"
    schema "files" do
      field(:project_id, :integer, primary_key: true)
      field(:filename, :string, primary_key: true)
      field(:content, :string)
    end
  end

  defmodule TouchedFiles do
    @moduledoc false
    use Ecto.Schema

    use PgRest.Resource,
      relationships: [
        users_tasks: [
          kind: :m2o,
          target: PgRest.Compat.Resources.UsersTasks,
          columns: [{"user_id", "user_id"}, {"task_id", "task_id"}],
          constraint: "fk_users_tasks"
        ],
        files: [
          kind: :m2o,
          target: PgRest.Compat.Resources.Files,
          columns: [{"project_id", "project_id"}, {"filename", "filename"}],
          constraint: "fk_upload"
        ]
      ]

    @primary_key false
    @schema_prefix "test"
    schema "touched_files" do
      field(:user_id, :integer, primary_key: true)
      field(:task_id, :integer, primary_key: true)
      field(:project_id, :integer, primary_key: true)
      field(:filename, :string, primary_key: true)
    end
  end

  defmodule Students do
    @moduledoc false
    use Ecto.Schema

    use PgRest.Resource,
      relationships: [
        students_info: [
          kind: :o2o,
          target: PgRest.Compat.Resources.StudentsInfo,
          columns: [{"code", "code"}, {"id", "id"}],
          constraint: "students_info_code_id_fkey"
        ]
      ]

    @primary_key false
    @schema_prefix "test"
    schema "students" do
      field(:id, :integer, primary_key: true)
      field(:code, :string, primary_key: true)
      field(:name, :string)
    end
  end

  defmodule StudentsInfo do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource

    @primary_key false
    @schema_prefix "test"
    schema "students_info" do
      field(:id, :integer, primary_key: true)
      field(:code, :string, primary_key: true)
      field(:address, :string)
    end
  end

  defmodule Country do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource

    @primary_key {:id, :integer, autogenerate: false}
    @schema_prefix "test"
    schema "country" do
      field(:name, :string)
      has_one(:capital, PgRest.Compat.Resources.Capital, foreign_key: :country_id)
    end
  end

  defmodule Capital do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource, relationships: [country: [cardinality: :one_to_one]]

    @primary_key {:id, :integer, autogenerate: false}
    @schema_prefix "test"
    schema "capital" do
      field(:name, :string)
      belongs_to(:country, PgRest.Compat.Resources.Country, type: :integer)
    end
  end

  defmodule FamilyTree do
    @moduledoc false
    use Ecto.Schema

    use PgRest.Resource,
      relationships: [parent_node: [constraint: "pptr"], children: [constraint: "pptr"]]

    @primary_key {:id, :string, autogenerate: false}
    @schema_prefix "test"
    schema "family_tree" do
      field(:name, :string)

      belongs_to(:parent_node, PgRest.Compat.Resources.FamilyTree,
        foreign_key: :parent,
        type: :string
      )

      has_many(:children, PgRest.Compat.Resources.FamilyTree, foreign_key: :parent)
    end
  end

  defmodule Managers do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource, relationships: [organizations: [constraint: "manager"]]

    @primary_key {:id, :integer, autogenerate: false}
    @schema_prefix "test"
    schema "managers" do
      field(:name, :string)
      has_many(:organizations, PgRest.Compat.Resources.Organizations, foreign_key: :manager_id)
    end
  end

  defmodule Organizations do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource, relationships: [manager: [constraint: "manager"]]

    @primary_key {:id, :integer, autogenerate: false}
    @schema_prefix "test"
    schema "organizations" do
      field(:name, :string)

      belongs_to(:referee_org, PgRest.Compat.Resources.Organizations,
        foreign_key: :referee,
        type: :integer
      )

      belongs_to(:auditor_org, PgRest.Compat.Resources.Organizations,
        foreign_key: :auditor,
        type: :integer
      )

      belongs_to(:manager, PgRest.Compat.Resources.Managers, type: :integer)
    end
  end

  defmodule Addresses do
    @moduledoc false
    use Ecto.Schema

    use PgRest.Resource,
      relationships: [
        billing_orders: [constraint: "billing"],
        shipping_orders: [constraint: "shipping"]
      ]

    @primary_key {:id, :integer, autogenerate: false}
    @schema_prefix "test"
    schema "addresses" do
      field(:address, :string)
      has_many(:billing_orders, PgRest.Compat.Resources.Orders, foreign_key: :billing_address_id)

      has_many(:shipping_orders, PgRest.Compat.Resources.Orders,
        foreign_key: :shipping_address_id
      )
    end
  end

  defmodule Orders do
    @moduledoc false
    use Ecto.Schema

    use PgRest.Resource,
      relationships: [
        billing_address: [constraint: "billing"],
        shipping_address: [constraint: "shipping"]
      ]

    @primary_key {:id, :integer, autogenerate: false}
    @schema_prefix "test"
    schema "orders" do
      field(:name, :string)
      belongs_to(:billing_address, PgRest.Compat.Resources.Addresses, type: :integer)
      belongs_to(:shipping_address, PgRest.Compat.Resources.Addresses, type: :integer)
    end
  end

  defmodule Entities do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource

    @primary_key {:id, :integer, autogenerate: false}
    @schema_prefix "test"
    schema "entities" do
      field(:name, :string)
      field(:arr, {:array, :integer})
      field(:text_search_vector, PgRest.Compat.Resources.Raw)
      has_many(:child_entities, PgRest.Compat.Resources.ChildEntities, foreign_key: :parent_id)
    end
  end

  defmodule ChildEntities do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource

    @primary_key {:id, :integer, autogenerate: false}
    @schema_prefix "test"
    schema "child_entities" do
      field(:name, :string)
      belongs_to(:parent, PgRest.Compat.Resources.Entities, type: :integer)

      has_many(:grandchild_entities, PgRest.Compat.Resources.GrandchildEntities,
        foreign_key: :parent_id
      )
    end
  end

  defmodule GrandchildEntities do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource

    @primary_key {:id, :integer, autogenerate: false}
    @schema_prefix "test"
    schema "grandchild_entities" do
      field(:name, :string)
      field(:or_starting_col, :string)
      field(:and_starting_col, :string)
      field(:jsonb_col, :map)
      belongs_to(:parent, PgRest.Compat.Resources.ChildEntities, type: :integer)
    end
  end

  defmodule Tsearch do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource

    @primary_key false
    @schema_prefix "test"
    schema "tsearch" do
      field(:text_search_vector, PgRest.Compat.Resources.Raw)
    end
  end

  defmodule Ranges do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource

    @primary_key {:id, :integer, autogenerate: false}
    @schema_prefix "test"
    schema "ranges" do
      field(:range, PgRest.Compat.Resources.Raw)
    end
  end

  defmodule CompoundPk do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource

    @primary_key false
    @schema_prefix "test"
    schema "compound_pk" do
      field(:k1, :integer, primary_key: true)
      field(:k2, :string, primary_key: true)
      field(:extra, :integer)
    end
  end

  defmodule NoPk do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource

    @primary_key false
    @schema_prefix "test"
    schema "no_pk" do
      field(:a, :string)
      field(:b, :string)
    end
  end

  defmodule Employees do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource

    @primary_key false
    @schema_prefix "test"
    schema "employees" do
      field(:first_name, :string, primary_key: true)
      field(:last_name, :string, primary_key: true)
      field(:salary, PgRest.Compat.Resources.Raw)
      field(:company, :string)
      field(:occupation, :string)
    end
  end

  defmodule OnlyPk do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource

    @primary_key {:id, :integer, autogenerate: false}
    @schema_prefix "test"
    schema "only_pk" do
    end
  end

  defmodule UnitTest do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource

    @primary_key {:idUnitTest, :integer, autogenerate: false}
    @schema_prefix "test"
    schema "UnitTest" do
      field(:nameUnitTest, :string)
    end
  end

  defmodule WebContent do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource, relationships: [web_content: [constraint: "web_content_p_web_id_fkey"]]

    @primary_key {:id, :integer, autogenerate: false}
    @schema_prefix "test"
    schema "web_content" do
      field(:name, :string)
      field(:p_web_id, :integer)

      belongs_to(:parent, PgRest.Compat.Resources.WebContent,
        foreign_key: :p_web_id,
        define_field: false
      )

      has_many(:web_content, PgRest.Compat.Resources.WebContent, foreign_key: :p_web_id)
    end
  end

  defmodule CarBrands do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource

    @primary_key {:name, :string, autogenerate: false}
    @schema_prefix "test"
    schema "car_brands" do
    end
  end

  defmodule CarModels do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource

    @primary_key false
    @schema_prefix "test"
    schema "car_models" do
      field(:name, :string, primary_key: true)
      field(:year, :integer, primary_key: true)
      field(:car_brand_name, :string)

      belongs_to(:car_brand, PgRest.Compat.Resources.CarBrands,
        foreign_key: :car_brand_name,
        references: :name,
        type: :string,
        define_field: false
      )
    end
  end

  defmodule PutGuc do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource

    @primary_key {:id, :integer, autogenerate: false}
    @schema_prefix "test"
    schema "put_guc" do
      field(:c, :string)
    end
  end

  defmodule PutNumeric do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource

    @primary_key {:n, :decimal, autogenerate: false}
    @schema_prefix "test"
    schema "put_numeric" do
      field(:v, :string)
    end
  end

  defmodule Timestamps do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource

    @primary_key false
    @schema_prefix "test"
    schema "timestamps" do
      field(:t, :utc_datetime_usec)
    end
  end

  defmodule TiobePls do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource

    @primary_key {:name, :string, autogenerate: false}
    @schema_prefix "test"
    schema "tiobe_pls" do
      field(:rank, :integer)
    end
  end

  defmodule AmbigA do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource

    @primary_key {:id, :integer, autogenerate: false}
    @schema_prefix "test"
    schema "ambig_a" do
      field(:name, :string)
    end
  end

  defmodule AmbigB do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource

    @primary_key {:id, :integer, autogenerate: false}
    @schema_prefix "test"
    schema "ambig_b" do
      field(:name, :string)
      belongs_to(:a, PgRest.Compat.Resources.AmbigA, type: :integer)
    end
  end

  defmodule AmbigAb do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource

    @primary_key false
    @schema_prefix "test"
    schema "ambig_ab" do
      belongs_to(:a, PgRest.Compat.Resources.AmbigA, type: :integer, primary_key: true)
      belongs_to(:b, PgRest.Compat.Resources.AmbigB, type: :integer, primary_key: true)
    end
  end

  defmodule NullableFkParent do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource

    @primary_key {:id, :integer, autogenerate: false}
    @schema_prefix "test"
    schema "nullable_fk_parent" do
      field(:name, :string)
      has_many(:children, PgRest.Compat.Resources.NullableFkChild, foreign_key: :parent_id)
    end
  end

  defmodule NullableFkChild do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource

    @primary_key {:id, :integer, autogenerate: false}
    @schema_prefix "test"
    schema "nullable_fk_child" do
      field(:name, :string)
      belongs_to(:parent, PgRest.Compat.Resources.NullableFkParent, type: :integer)
    end
  end

  defmodule CsvEdge do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource

    @primary_key {:id, :integer, autogenerate: false}
    @schema_prefix "test"
    schema "csv_edge" do
      field(:label, :string)
      field(:note, :string)
    end
  end

  defmodule CsvEdgeCases do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource

    @primary_key {:id, :integer, autogenerate: false}
    @schema_prefix "test"
    schema "csv_edge_cases" do
      field(:txt, :string)
      field(:js, :map)
      field(:arr, {:array, :integer})
    end
  end

  defmodule DefaultsDemo do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource

    @primary_key {:id, :id, autogenerate: true}
    @schema_prefix "test"
    schema "defaults_demo" do
      field(:label, :string)
      field(:code, :string)
      field(:note, :string)
      field(:created_at, :utc_datetime_usec)
      field(:double_id, :integer, read_after_writes: true)
    end
  end

  defmodule TypeCases do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource

    @primary_key {:id, :integer, autogenerate: false}
    @schema_prefix "test"
    schema "type_cases" do
      field(:status, Ecto.Enum, values: [:draft, :active, :archived])
      field(:email, :string)
      field(:qty, :decimal)
      field(:at, :utc_datetime)
      field(:price, :decimal)
      field(:code, :string)
      field(:bits, PgRest.Compat.Resources.Raw)
    end
  end

  defmodule Accounts do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource

    @primary_key {:id, :integer, autogenerate: false}
    @schema_prefix "test"
    schema "accounts" do
      field(:email, :string)
      field(:hashed_password, :string, redact: true)
      field(:role, :string)
      field(:owner_id, :string)
    end
  end

  # The pg-safeupdate tables: identical but for their names.
  for {module, table} <- [
        SafeUpdateItems: "safe_update_items",
        SafeDeleteItems: "safe_delete_items",
        UnsafeUpdateItems: "unsafe_update_items",
        UnsafeDeleteItems: "unsafe_delete_items"
      ] do
    body =
      quote do
        @moduledoc false
        use Ecto.Schema
        use PgRest.Resource

        @primary_key {:id, :integer, autogenerate: false}
        @schema_prefix "test"
        schema unquote(table) do
          field(:name, :string)
          field(:observation, :string)
        end
      end

    Module.create(Module.concat(__MODULE__, module), body, Macro.Env.location(__ENV__))
  end

  defmodule Stuff do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource

    @primary_key {:id, :integer, autogenerate: false}
    @schema_prefix "test"
    schema "stuff" do
      field(:name, :string)
    end
  end

  defmodule LocTest do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource

    @primary_key {:id, :integer, autogenerate: false}
    @schema_prefix "test"
    schema "loc_test" do
      field(:c, :string)
    end
  end

  defmodule PgrestAfterLoc do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource

    @primary_key {:id, :integer, autogenerate: false}
    @schema_prefix "test"
    schema "pgrest_after_loc" do
      field(:c, :string)
    end
  end

  # Aggregate fixtures (AggregateFunctionsSpec).
  defmodule Trash do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource

    @primary_key {:id, :integer, autogenerate: false}
    @schema_prefix "test"
    schema "trash" do
    end
  end

  defmodule TrashDetails do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource, relationships: [trash: [cardinality: :one_to_one]]

    @primary_key {:id, :integer, autogenerate: false}
    @schema_prefix "test"
    schema "trash_details" do
      field(:jsonb_col, :map)

      belongs_to(:trash, PgRest.Compat.Resources.Trash,
        foreign_key: :id,
        type: :integer,
        define_field: false
      )
    end
  end

  defmodule ProjectInvoices do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource

    @primary_key {:id, :integer, autogenerate: false}
    @schema_prefix "test"
    schema "project_invoices" do
      field(:invoice_total, :decimal)
      belongs_to(:project, PgRest.Compat.Resources.Projects, type: :integer)
    end
  end

  defmodule BudgetCategories do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource

    @primary_key {:id, :integer, autogenerate: false}
    @schema_prefix "test"
    schema "budget_categories" do
      field(:category_name, :string)
      field(:budget_owner, :string)
      field(:budget_amount, :decimal)
    end
  end

  defmodule BudgetExpenses do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource

    @primary_key {:id, :integer, autogenerate: false}
    @schema_prefix "test"
    schema "budget_expenses" do
      field(:expense_amount, :decimal)
      belongs_to(:budget_category, PgRest.Compat.Resources.BudgetCategories, type: :integer)
    end
  end

  defmodule Factories do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource

    @primary_key {:id, :integer, autogenerate: false}
    @schema_prefix "test"
    schema "factories" do
      field(:name, :string)
    end
  end

  defmodule ProcessCategories do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource

    @primary_key {:id, :integer, autogenerate: false}
    @schema_prefix "test"
    schema "process_categories" do
      field(:name, :string)
    end
  end

  defmodule Processes do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource

    @primary_key {:id, :integer, autogenerate: false}
    @schema_prefix "test"
    schema "processes" do
      field(:name, :string)
      belongs_to(:factory, PgRest.Compat.Resources.Factories, type: :integer)

      belongs_to(:category, PgRest.Compat.Resources.ProcessCategories, type: :integer)

      has_one(:process_costs, PgRest.Compat.Resources.ProcessCosts, foreign_key: :process_id)
    end
  end

  defmodule ProcessCosts do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource

    @primary_key false
    @schema_prefix "test"
    schema "process_costs" do
      field(:cost, :decimal)

      belongs_to(:process, PgRest.Compat.Resources.Processes,
        type: :integer,
        primary_key: true
      )
    end
  end

  defmodule Supervisors do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource

    @primary_key {:id, :integer, autogenerate: false}
    @schema_prefix "test"
    schema "supervisors" do
      field(:name, :string)
    end
  end

  defmodule ProcessSupervisor do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource

    @primary_key false
    @schema_prefix "test"
    schema "process_supervisor" do
      belongs_to(:process, PgRest.Compat.Resources.Processes, type: :integer, primary_key: true)

      belongs_to(:supervisor, PgRest.Compat.Resources.Supervisors,
        type: :integer,
        primary_key: true
      )
    end
  end

  defmodule FactoryBuildings do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource

    @primary_key {:id, :integer, autogenerate: false}
    @schema_prefix "test"
    schema "factory_buildings" do
      field(:code, :string)
      field(:size, :decimal)
      field(:type, :string)
      field(:inspections, :map)
      belongs_to(:factory, PgRest.Compat.Resources.Factories, type: :integer)
    end
  end
end
