defmodule Przma.CommonsCas.Repo do
  @moduledoc """
  Dedicated Ecto repo for the przma_commons_cas Postgres database —
  intentionally separate from pzdb/LanceDB, which every other module
  in this app uses. The one deliberate exception to the "no Postgres"
  decision governing the rest of this project: purely for analytics,
  never a source of truth for authorization or ownership.
  """
  use Ecto.Repo,
    otp_app: :przma,
    adapter: Ecto.Adapters.Postgres
end