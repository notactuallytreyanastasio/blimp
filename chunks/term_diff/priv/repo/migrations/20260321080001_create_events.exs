defmodule TermDiff.Repo.Migrations.CreateEvents do
  use Ecto.Migration

  def change do
    create table(:events) do
      add :type, :string, null: false
      add :source, :string, null: false
      add :data, :map, default: %{}

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:events, [:type])
    create index(:events, [:source])
    create index(:events, [:inserted_at])
  end
end
