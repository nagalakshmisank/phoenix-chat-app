defmodule PRZMA.Repo do
  use Ecto.Repo,
    otp_app: :przma,
    adapter: Ecto.Adapters.Postgres
end
