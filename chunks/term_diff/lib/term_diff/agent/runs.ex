defmodule TermDiff.Agent.Runs do
  @moduledoc """
  Context for managing agent runs.

  Provides CRUD operations for runs and broadcasts changes
  via PubSub for LiveView consumers.
  """
  import Ecto.Query

  alias TermDiff.Agent.Run
  alias TermDiff.Repo

  @spec list_runs(keyword()) :: [Run.t()]
  def list_runs(opts \\ []) do
    query =
      Run
      |> where([r], is_nil(r.archived_at))
      |> order_by([r], desc: r.inserted_at)
      |> limit(50)

    query =
      case Keyword.get(opts, :repo_path) do
        nil -> query
        path -> where(query, [r], r.repo_path == ^path)
      end

    Repo.all(query)
  end

  @spec get_run!(integer()) :: Run.t()
  def get_run!(id), do: Repo.get!(Run, id)

  @spec get_run(integer()) :: Run.t() | nil
  def get_run(id), do: Repo.get(Run, id)

  @spec create_run(map()) :: {:ok, Run.t()} | {:error, Ecto.Changeset.t()}
  def create_run(attrs) do
    %Run{}
    |> Run.changeset(attrs)
    |> Repo.insert()
    |> tap_ok(fn run -> broadcast({:run_created, run}) end)
  end

  @spec update_run(Run.t(), map()) :: {:ok, Run.t()} | {:error, Ecto.Changeset.t()}
  def update_run(%Run{} = run, attrs) do
    run
    |> Run.changeset(attrs)
    |> Repo.update()
    |> tap_ok(fn updated -> broadcast({:run_updated, updated}) end)
  end

  @spec archive_run(Run.t()) :: {:ok, Run.t()} | {:error, Ecto.Changeset.t()}
  def archive_run(%Run{} = run) do
    run
    |> Run.changeset(%{archived_at: DateTime.utc_now()})
    |> Repo.update()
    |> tap_ok(fn archived -> broadcast({:run_archived, archived}) end)
  end

  @spec archive_stale_runs(integer()) :: {integer(), nil}
  def archive_stale_runs(max_age_hours \\ 24) do
    cutoff = DateTime.add(DateTime.utc_now(), -max_age_hours * 3600)

    {count, _} =
      Run
      |> where([r], is_nil(r.archived_at))
      |> where([r], r.updated_at < ^cutoff)
      |> where([r], r.status not in ["running", "pending"])
      |> Repo.update_all(set: [archived_at: DateTime.utc_now()])

    if count > 0, do: broadcast({:runs_cleaned, count})
    {count, nil}
  end

  @doc """
  Returns the full run chain (oldest first) for a given run by walking
  up the parent_run_id chain. Used for stitching multi-turn conversations.
  """
  @spec get_run_chain(Run.t()) :: [Run.t()]
  def get_run_chain(%Run{parent_run_id: nil} = run), do: [run]

  def get_run_chain(%Run{parent_run_id: parent_id} = run) do
    parent = Repo.get!(Run, parent_id)
    get_run_chain(parent) ++ [run]
  end

  @spec change_run(Run.t(), map()) :: Ecto.Changeset.t()
  def change_run(%Run{} = run, attrs \\ %{}) do
    Run.changeset(run, attrs)
  end

  defp broadcast(message) do
    Phoenix.PubSub.broadcast(TermDiff.PubSub, "runs", message)
  end

  defp tap_ok({:ok, value} = result, func) do
    func.(value)
    result
  end

  defp tap_ok(error, _func), do: error
end
