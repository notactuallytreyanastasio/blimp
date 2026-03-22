defmodule TermDiff.Repo.Migrations.CreateRuns do
  use Ecto.Migration

  def change do
    create table(:runs) do
      add :title, :string
      add :status, :string, null: false, default: "pending"
      add :agent_type, :string, null: false
      add :prompt, :text, null: false
      add :workspace_path, :string
      add :repo_path, :string
      add :model, :string
      add :session_id, :string
      add :parent_run_id, :integer
      add :permission_mode, :string
      add :turn_number, :integer, default: 1
      add :max_turns, :integer
      add :input_tokens, :integer, default: 0
      add :output_tokens, :integer, default: 0
      add :total_tokens, :integer, default: 0
      add :exit_code, :integer
      add :error, :text
      add :started_at, :utc_datetime_usec
      add :finished_at, :utc_datetime_usec
      add :archived_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:runs, [:status])
    create index(:runs, [:repo_path])
    create index(:runs, [:inserted_at])
  end
end
