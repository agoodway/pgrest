defmodule PgRest.Test.TelemetryProbe do
  @moduledoc false
  # Forwards telemetry events to a test process as `{:event, event, measurements, metadata}`.

  @doc "Attaches for the current test and detaches on exit."
  @spec attach([atom()] | [[atom()]]) :: :ok
  def attach([first | _] = events) when is_list(first), do: Enum.each(events, &attach/1)

  def attach(event) do
    id = {__MODULE__, event, make_ref()}
    :ok = :telemetry.attach(id, event, &__MODULE__.handle/4, self())
    ExUnit.Callbacks.on_exit(fn -> :telemetry.detach(id) end)
  end

  @doc false
  def handle(event, measurements, metadata, test),
    do: send(test, {:event, event, measurements, metadata})

  @doc "Drains the mailbox of forwarded events."
  @spec drain() :: [{[atom()], map(), map()}]
  def drain do
    receive do
      {:event, event, measurements, metadata} -> [{event, measurements, metadata} | drain()]
    after
      0 -> []
    end
  end
end
