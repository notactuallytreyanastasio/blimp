defmodule TermDiff.Agent.Event do
  @moduledoc """
  Schema for persisted events in the event bus.

  Events are the primary communication mechanism.
  Every significant action (run started, output received, run finished,
  CI failure detected, etc.) is emitted as an event.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: integer() | nil,
          type: String.t() | nil,
          source: String.t() | nil,
          data: map(),
          inserted_at: DateTime.t() | nil
        }

  schema "events" do
    field :type, :string
    field :source, :string
    field :data, :map, default: %{}

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(event, attrs) do
    event
    |> cast(attrs, [:type, :source, :data])
    |> validate_required([:type, :source])
  end
end
