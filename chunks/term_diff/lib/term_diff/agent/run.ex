defmodule TermDiff.Agent.Run do
  @moduledoc """
  Schema for agent run records.

  A run represents a single invocation of a coding agent (Claude Code, Codex, etc.)
  against a workspace with a given prompt.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type status :: :pending | :running | :succeeded | :failed | :cancelled

  @type t :: %__MODULE__{
          id: integer() | nil,
          title: String.t() | nil,
          status: String.t() | nil,
          agent_type: String.t() | nil,
          prompt: String.t() | nil,
          workspace_path: String.t() | nil,
          repo_path: String.t() | nil,
          model: String.t() | nil,
          session_id: String.t() | nil,
          parent_run_id: integer() | nil,
          permission_mode: String.t() | nil,
          turn_number: integer(),
          max_turns: integer() | nil,
          input_tokens: integer(),
          output_tokens: integer(),
          total_tokens: integer(),
          exit_code: integer() | nil,
          error: String.t() | nil,
          started_at: DateTime.t() | nil,
          finished_at: DateTime.t() | nil,
          archived_at: DateTime.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @valid_statuses ~w(pending running succeeded failed cancelled)

  schema "runs" do
    field :title, :string
    field :status, :string, default: "pending"
    field :agent_type, :string
    field :prompt, :string
    field :workspace_path, :string
    field :repo_path, :string
    field :model, :string
    field :session_id, :string
    field :parent_run_id, :integer
    field :permission_mode, :string
    field :turn_number, :integer, default: 1
    field :max_turns, :integer
    field :input_tokens, :integer, default: 0
    field :output_tokens, :integer, default: 0
    field :total_tokens, :integer, default: 0
    field :exit_code, :integer
    field :error, :string
    field :started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec
    field :archived_at, :utc_datetime_usec
    field :deciduous_root, :integer

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(run, attrs) do
    run
    |> cast(attrs, [
      :title,
      :status,
      :agent_type,
      :prompt,
      :workspace_path,
      :repo_path,
      :model,
      :session_id,
      :parent_run_id,
      :permission_mode,
      :turn_number,
      :max_turns,
      :input_tokens,
      :output_tokens,
      :total_tokens,
      :exit_code,
      :error,
      :started_at,
      :finished_at,
      :archived_at,
      :deciduous_root
    ])
    |> validate_required([:status, :agent_type, :prompt])
    |> validate_inclusion(:status, @valid_statuses)
    |> validate_number(:turn_number, greater_than: 0)
    |> validate_number(:max_turns, greater_than: 0)
  end
end
