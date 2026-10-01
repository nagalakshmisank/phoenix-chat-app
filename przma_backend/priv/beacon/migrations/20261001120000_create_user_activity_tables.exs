defmodule Przma.Beacon.Repo.Migrations.CreateUserActivityTables do
  @moduledoc """
  Beacon CMS — User Activity tables in becam_cms (prefix przma_ so they
  never clash with Beacon's own beacon_* tables).

  WRITTEN BY: Przma.Beacon.UserActivityCollector
  READ BY:    Przma.Beacon.Activity (admin page)

  Run with:  mix ecto.migrate -r Przma.Beacon.Repo
  """
  use Ecto.Migration

  def change do
    # One row per platform user, keyed by DID (did:przma:<username>)
    create table(:przma_users, primary_key: false) do
      add :did, :text, primary_key: true
      add :username, :text, null: false
      add :display_name, :text
      add :email, :text
      add :tier, :smallint
      add :first_seen_at, :timestamptz, null: false
      add :last_seen_at, :timestamptz, null: false
      add :request_count, :bigint, null: false, default: 0
      add :last_ip, :text
      add :last_user_agent, :text
      add :updated_at, :timestamptz, null: false
    end

    create index(:przma_users, ["last_seen_at DESC"], name: :przma_users_last_seen_idx)
    create index(:przma_users, [:username], name: :przma_users_username_idx)

    # One row per meaningful action
    create table(:przma_user_events) do
      add :occurred_at, :timestamptz, null: false
      add :did, :text
      add :username, :text
      # signed_in | registration_completed | profile_created | profile_updated | auth_failed
      add :event_type, :text, null: false
      # Keycloak session id (sid) — only for signed_in
      add :session_id, :text
      add :details, :map, null: false, default: %{}
      add :ip, :text
      add :user_agent, :text
    end

    create index(:przma_user_events, ["occurred_at DESC"], name: :przma_user_events_occurred_at_idx)
    create index(:przma_user_events, [:did, "occurred_at DESC"], name: :przma_user_events_did_idx)
    create index(:przma_user_events, [:event_type, "occurred_at DESC"], name: :przma_user_events_type_idx)

    # A Keycloak session produces exactly one "signed_in" row, even if
    # przma_backend restarts or sees the session on many requests.
    create unique_index(:przma_user_events, [:did, :session_id],
             name: :przma_user_events_one_signin_per_session,
             where: "event_type = 'signed_in'"
           )
  end
end
