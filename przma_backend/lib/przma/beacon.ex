defmodule Przma.Beacon do
  @moduledoc """
  Beacon CMS — the PRZMA admin dashboard, built into przma_backend but kept
  apart from the platform:

    * all Beacon code lives in lib/przma/beacon/ and lib/przma_web/beacon/
    * it runs under its own supervisor (Przma.Beacon.Supervisor)
    * it serves /admin on its own port (BEACON_ADMIN_PORT, default 4300)
    * it uses its own database (becam_cms)
    * it is OFF unless `export BEACON_ENABLED=true`

  Business code records activity with one call, after a real success:

      Przma.Beacon.track(did, "profile_updated", %{fields: ["bio"]})

  `track/3` never blocks and never raises. When Beacon is off it does nothing.
  """

  @doc "True when Beacon is switched on (BEACON_ENABLED=true at boot)."
  def enabled?, do: Application.get_env(:przma, :beacon, [])[:enabled] == true

  @doc "Record a user event for `did`. `details` must be JSON-encodable."
  @spec track(String.t() | nil, String.t(), map()) :: :ok
  def track(did, event_type, details \\ %{})

  def track(did, event_type, details) when is_binary(did) and is_binary(event_type) do
    if enabled?() do
      Przma.Beacon.UserActivityCollector.record(%{
        occurred_at: DateTime.utc_now(),
        did: did,
        username: username_from_did(did),
        event_type: event_type,
        session_id: nil,
        details: details,
        ip: nil,
        user_agent: nil
      })
    end

    :ok
  end

  def track(_did, _event_type, _details), do: :ok

  @doc "KeycloakAuth builds the DID as \"did:przma:<preferred_username>\"."
  def username_from_did("did:przma:" <> username), do: username
  def username_from_did(did), do: did
end
