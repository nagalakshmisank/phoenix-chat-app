defmodule Przma.Beacon.Repo.Migrations.CreateBeaconTables do
  @moduledoc """
  Beacon CMS's own tables (beacon_pages, beacon_layouts, ...), exactly as
  Beacon's installer generates them. Lives in becam_cms only.

  Run with:  mix ecto.migrate -r Przma.Beacon.Repo
  """
  use Ecto.Migration
  def up, do: Beacon.Migration.up()
  def down, do: Beacon.Migration.down()
end
