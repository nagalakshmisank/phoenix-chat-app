defmodule Przma.Beacon.UserEvent do
  @moduledoc """
  becam_cms.przma_user_events — one row per meaningful user action
  (signed_in, registration_completed, profile_created, profile_updated,
  auth_failed). Table created by priv/beacon/migrations.
  """
  use Ecto.Schema

  schema "przma_user_events" do
    field :occurred_at, :utc_datetime_usec
    field :did, :string
    field :username, :string
    field :event_type, :string
    field :session_id, :string
    field :details, :map
    field :ip, :string
    field :user_agent, :string
  end
end
