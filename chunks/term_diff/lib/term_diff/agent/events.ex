defmodule TermDiff.Agent.Events do
  @moduledoc """
  Event bus for agent runs.

  Events are:
  1. Persisted to Postgres (for history, replay, and external queries)
  2. Broadcast via PubSub to two topics:
     - "events" (all events)
     - "events:<type>" (filtered by event type)

  ## Event Types

  - `run.started` -- agent run has been dispatched
  - `run.output` -- a line/event from agent stdout
  - `run.finished` -- agent run completed (success or failure)
  - `run.cancelled` -- agent run was cancelled by user
  """
  import Ecto.Query

  alias TermDiff.Agent.Event
  alias TermDiff.Repo

  @spec emit(map()) :: {:ok, Event.t()} | {:error, Ecto.Changeset.t()}
  def emit(attrs) do
    result =
      %Event{}
      |> Event.changeset(attrs)
      |> Repo.insert()

    case result do
      {:ok, event} ->
        broadcast(event)
        result

      {:error, _changeset} ->
        result
    end
  end

  @spec list_events(keyword()) :: [Event.t()]
  def list_events(opts \\ []) do
    Event
    |> maybe_filter_type(Keyword.get(opts, :type))
    |> maybe_filter_source(Keyword.get(opts, :source))
    |> maybe_filter_since(Keyword.get(opts, :since))
    |> maybe_filter_run_id(Keyword.get(opts, :run_id))
    |> order_by([e], asc: e.inserted_at)
    |> limit(^Keyword.get(opts, :limit, 100))
    |> Repo.all()
  end

  defp maybe_filter_type(query, nil), do: query
  defp maybe_filter_type(query, type), do: where(query, [e], e.type == ^type)

  defp maybe_filter_source(query, nil), do: query
  defp maybe_filter_source(query, source), do: where(query, [e], e.source == ^source)

  defp maybe_filter_since(query, nil), do: query
  defp maybe_filter_since(query, since), do: where(query, [e], e.inserted_at > ^since)

  defp maybe_filter_run_id(query, nil), do: query

  defp maybe_filter_run_id(query, run_id) do
    where(query, [e], fragment("(data->>'run_id')::integer = ?", ^run_id))
  end

  defp broadcast(%Event{} = event) do
    Phoenix.PubSub.broadcast(TermDiff.PubSub, "events", {:event, event})
    Phoenix.PubSub.broadcast(TermDiff.PubSub, "events:#{event.type}", {:event, event})
  end
end
