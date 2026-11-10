defmodule Przma.Authz.Repo do
  @moduledoc """
  Ecto repo for the centralised authorisation tables.

  Lives in the `przma_authz` schema of the Olimyam Postgres
  (`db:5432`, database `postgres`). Every query in Przma.Authz.* names
  its tables with the `przma_authz.` prefix, so nothing depends on the
  connection's search_path. Connection settings: config/runtime.exs
  (AUTHZ_DATABASE_URL, falls back to DATABASE_URL).

      mix ecto.migrate -r Przma.Authz.Repo
  """
  use Ecto.Repo,
    otp_app: :przma,
    adapter: Ecto.Adapters.Postgres
end
