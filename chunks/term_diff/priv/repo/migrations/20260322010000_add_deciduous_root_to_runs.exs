defmodule TermDiff.Repo.Migrations.AddDeciduousRootToRuns do
  use Ecto.Migration

  def change do
    alter table(:runs) do
      add :deciduous_root, :integer
    end
  end
end
