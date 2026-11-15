defmodule PgRest.MediaType do
  @moduledoc """
  One media type of an `Accept` header, as PostgREST understands it.

  `kind` is what PgRest can answer: `:json` (`application/json`), `:object`
  (`application/vnd.pgrst.object[+json]`), `:array` (`application/vnd.pgrst.array[+json]`),
  `:csv` (`text/csv`), `:plan` (`application/vnd.pgrst.plan[+json|+text]`), `:any` (`*/*`) or
  `:other`. Matching is case-insensitive. `raw` is the type as the client wrote it with the `q`
  parameter dropped (it is what a `PGRST107` lists). `nulls_stripped?` is the `nulls=stripped`
  parameter, valid on `:array` and `:object` only. `plan` is set for `:plan`: its `format`, the
  media type it is `for` (`application/json` when the client names none) and its `options`, in
  PostgREST's order (`analyze`, `verbose`, `settings`, `buffers`, `wal`). A plan's `raw` is
  PostgREST's canonical name for it, `application/vnd.pgrst.plan+<format>; for="<type>"` and
  `; options=<a>|<b>` when there are any: what a `PGRST107` lists and the response echoes.
  """

  @enforce_keys [:kind, :raw]
  defstruct [:kind, :raw, :plan, nulls_stripped?: false, q: 1.0]

  @type kind :: :json | :object | :array | :csv | :plan | :any | :other
  @type plan_option :: :analyze | :verbose | :settings | :buffers | :wal
  @type plan :: %{format: :text | :json, for: t(), options: [plan_option()]}

  @type t :: %__MODULE__{
          kind: kind(),
          raw: String.t(),
          nulls_stripped?: boolean(),
          q: float(),
          plan: plan() | nil
        }

  @json_type "application/json; charset=utf-8"

  @doc "The `*/*` any type, what a missing `Accept` header means."
  @spec any() :: t()
  def any, do: %__MODULE__{kind: :any, raw: "*/*"}

  @doc "The default, `application/json`."
  @spec json() :: t()
  def json, do: %__MODULE__{kind: :json, raw: "application/json"}

  @doc """
  The `Content-Type` of a response in this media type. The stripped types name the parameter
  as PostgREST does; an `:array` that is not stripped is plain JSON. Error bodies are always
  `application/json`.
  """
  @spec content_type(t()) :: String.t()
  def content_type(%__MODULE__{kind: :csv}), do: "text/csv; charset=utf-8"
  def content_type(%__MODULE__{kind: :plan, raw: raw}), do: raw <> "; charset=utf-8"

  def content_type(%__MODULE__{kind: :object, nulls_stripped?: stripped?}),
    do: "application/vnd.pgrst.object+json" <> stripped_param(stripped?) <> "; charset=utf-8"

  def content_type(%__MODULE__{kind: :array, nulls_stripped?: true}),
    do: "application/vnd.pgrst.array+json;nulls=stripped; charset=utf-8"

  def content_type(%__MODULE__{}), do: @json_type

  @doc """
  The media type a statement answers in: the type itself, `application/json` for `*/*`, and for
  a plan the type it is `for`, so an explained statement is the one that would run for it.
  """
  @spec body(t()) :: t()
  def body(%__MODULE__{kind: :plan, plan: %{for: target}}), do: body(target)
  def body(%__MODULE__{kind: :any}), do: json()
  def body(%__MODULE__{} = media), do: media

  defp stripped_param(true), do: ";nulls=stripped"
  defp stripped_param(false), do: ""
end
