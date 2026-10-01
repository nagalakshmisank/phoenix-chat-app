defmodule Przma.Beacon.PrzmaUser do
  @moduledoc """
  becam_cms.przma_users — one row per platform user (keyed by DID),
  kept up to date by Przma.Beacon.UserActivityCollector.
  Table created by priv/beacon/migrations.
  """
  use Ecto.Schema

  @primary_key {:did, :string, autogenerate: false}
  schema "przma_users" do
    field :username, :string
    field :display_name, :string
    field :email, :string
    field :tier, :integer
    field :first_seen_at, :utc_datetime_usec
    field :last_seen_at, :utc_datetime_usec
    field :request_count, :integer
    field :last_ip, :string
    field :last_user_agent, :string
    field :updated_at, :utc_datetime_usec
  end
end
