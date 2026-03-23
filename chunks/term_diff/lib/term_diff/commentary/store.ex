defmodule TermDiff.Commentary.Store do
  @moduledoc """
  ETS-backed store for AI commentary on diffs. Keyed by file path.

  Owns a public ETS table so reads can bypass the GenServer for speed.
  Writes go through the GenServer to ensure consistency.

  Accepts a :name option for the GenServer name (defaults to __MODULE__).
  The ETS table name is derived from the GenServer name.
  """

  use GenServer

  alias TermDiff.Commentary.{FileCommentary, ReviewResult}

  # ── Client API ──

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, name, name: name)
  end

  @spec put_review(ReviewResult.t(), GenServer.server()) :: :ok
  def put_review(%ReviewResult{} = review, server \\ __MODULE__) do
    GenServer.call(server, {:put_review, review})
  end

  @spec get_file_commentary(String.t(), GenServer.server()) :: FileCommentary.t() | nil
  def get_file_commentary(file_path, server \\ __MODULE__) do
    table = table_name(server)

    case :ets.lookup(table, {:file_commentary, file_path}) do
      [{_, commentary}] -> commentary
      [] -> nil
    end
  end

  @spec get_annotations_for_line(String.t(), pos_integer(), GenServer.server()) :: [map()]
  def get_annotations_for_line(file_path, line_number, server \\ __MODULE__) do
    case get_file_commentary(file_path, server) do
      nil ->
        []

      %FileCommentary{annotations: annotations} ->
        Enum.filter(annotations, fn ann ->
          line_number >= ann.start_line and line_number <= ann.end_line
        end)
    end
  end

  @spec get_summary(GenServer.server()) :: String.t() | nil
  def get_summary(server \\ __MODULE__) do
    table = table_name(server)

    case :ets.lookup(table, :review_summary) do
      [{_, summary}] -> summary
      [] -> nil
    end
  end

  @spec get_status(GenServer.server()) :: :idle | :reviewing
  def get_status(server \\ __MODULE__) do
    table = table_name(server)

    case :ets.lookup(table, :review_meta) do
      [{_, %{status: status}}] -> status
      [] -> :idle
    end
  end

  @spec mark_reviewing(GenServer.server()) :: :ok
  def mark_reviewing(server \\ __MODULE__) do
    GenServer.call(server, :mark_reviewing)
  end

  @spec mark_stale([String.t()], GenServer.server()) :: :ok
  def mark_stale(file_paths, server \\ __MODULE__) do
    GenServer.call(server, {:mark_stale, file_paths})
  end

  @spec clear(GenServer.server()) :: :ok
  def clear(server \\ __MODULE__) do
    GenServer.call(server, :clear)
  end

  # ── Server Callbacks ──

  @impl true
  def init(name) do
    table_name = :"#{name}_ets"
    table = :ets.new(table_name, [:set, :public, :named_table, read_concurrency: true])
    :ets.insert(table, {:review_meta, %{status: :idle, diff_hash: nil, started_at: nil}})
    {:ok, %{table: table, table_name: table_name}}
  end

  @impl true
  def handle_call({:put_review, review}, _from, %{table: table} = state) do
    by_file = Enum.group_by(review.annotations, & &1.file)

    for {file, annotations} <- by_file do
      commentary = %FileCommentary{
        file: file,
        diff_hash: review.diff_hash,
        annotations: annotations,
        staleness: :fresh,
        reviewed_at: review.reviewed_at
      }

      :ets.insert(table, {{:file_commentary, file}, commentary})
    end

    :ets.insert(table, {:review_summary, review.summary})

    :ets.insert(
      table,
      {:review_meta, %{status: :idle, diff_hash: review.diff_hash, started_at: nil}}
    )

    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:mark_reviewing, _from, %{table: table} = state) do
    update_meta(table, fn meta -> %{meta | status: :reviewing, started_at: DateTime.utc_now()} end)

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:mark_stale, file_paths}, _from, %{table: table} = state) do
    for path <- file_paths do
      case :ets.lookup(table, {:file_commentary, path}) do
        [{key, commentary}] ->
          :ets.insert(table, {key, %{commentary | staleness: :stale}})

        [] ->
          :ok
      end
    end

    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:clear, _from, %{table: table} = state) do
    :ets.delete_all_objects(table)
    :ets.insert(table, {:review_meta, %{status: :idle, diff_hash: nil, started_at: nil}})
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:table_name, _from, %{table_name: table_name} = state) do
    {:reply, table_name, state}
  end

  defp update_meta(table, fun) do
    case :ets.lookup(table, :review_meta) do
      [{_, meta}] -> :ets.insert(table, {:review_meta, fun.(meta)})
      [] -> :ok
    end
  end

  defp table_name(server) when is_atom(server), do: :"#{server}_ets"
  defp table_name(server), do: GenServer.call(server, :table_name)
end
