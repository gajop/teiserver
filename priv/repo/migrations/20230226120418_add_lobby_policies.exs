defmodule Central.Repo.Migrations.AddLobbyPolicies do
  use Ecto.Migration

  def change do
    create table(:lobby_policies) do
      add :name, :string
      add :preset, :string

      add :icon, :string
      add :colour, :string

      add :enabled, :boolean, default: false

      add :map_list, {:array, :string}
      add :agent_name_list, {:array, :string}

      add :agent_name_format, :string
      add :lobby_name_format, :string

      add :min_rating, :integer
      add :max_rating, :integer

      add :min_uncertainty, :integer
      add :max_uncertainty, :integer

      add :min_rank, :integer
      add :max_rank, :integer
      add :min_teamsize, :integer
      add :max_teamsize, :integer

      add :max_teamcount, :integer, default: 2

      timestamps()
    end
  end
end
