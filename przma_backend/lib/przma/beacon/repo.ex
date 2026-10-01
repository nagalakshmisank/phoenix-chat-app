defmodule Przma.Beacon.Repo do
  @moduledoc """
  Connection to the Beacon CMS database (becam_cms). Used ONLY by Beacon code:
  Beacon CMS's own tables (beacon_*), and our activity tables (przma_*).

  It never touches CouchDB, S3/Lance or the commons CAS database.
  Settings come from BEACON_DB_* env vars (config/runtime.exs).

      mix ecto.migrate -r Przma.Beacon.Repo
  """
  use Ecto.Repo,
    otp_app: :przma,
    adapter: Ecto.Adapters.Postgres
end
