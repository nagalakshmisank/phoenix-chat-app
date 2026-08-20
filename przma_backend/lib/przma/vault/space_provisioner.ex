defmodule Przma.Vault.SpaceProvisioner do
  @moduledoc """
  Runs once, right after a user's first successful Keycloak-authenticated
  request reaches Phoenix (registration), to lay down a user's 3 default
  spaces in S3: vault (private), public, professional.

  "vault" gets its content immediately via Przma.Vault.Profile.create/3
  (the profile row IS the private space's first object — no separate
  marker needed). The other 2 spaces have no content yet at registration
  time, so each gets a small "_meta" table written just so the space's
  S3 prefix actually exists and is visible/listable from registration
  onward, rather than only appearing whenever a user first posts
  something to it.

  "circle" stays defined in NamespacePolicy (valid to write to whenever
  a user actually joins/creates one) but is intentionally NOT
  auto-provisioned here — it isn't one of the 3 defaults.
  """

  alias Przma.Vault.{PzdbConnector, PzdbUri}

  @empty_spaces ["public", "professional"]

  @doc """
  Provisions all 3 default spaces for a newly-registered user. Call
  this once, from the registration-completion endpoint — NOT from
  every login, since re-running it would re-write (not duplicate,
  given @table "_meta" is a fixed single row) the 2 empty spaces' meta
  rows.
  """
  @spec provision_all(actor :: PzdbConnector.actor(), tenant_uuid :: String.t(), attrs :: map()) ::
          :ok | {:error, term()}
  def provision_all(%{did: did} = actor, tenant_uuid, profile_attrs) do
    with :ok <- Przma.Vault.Profile.create(actor, tenant_uuid, profile_attrs) do
      provision_empty_spaces(actor, tenant_uuid, did)
    end
  end

  defp provision_empty_spaces(actor, tenant_uuid, did) do
    Enum.reduce_while(@empty_spaces, :ok, fn space, :ok ->
      case write_space_meta(actor, tenant_uuid, did, space) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp write_space_meta(actor, tenant_uuid, did, space) do
    uri =
      %PzdbUri{transport: :s3, tenant_id: tenant_uuid, did: did, namespace: space, table: "_meta"}
      |> PzdbUri.to_string()

    row = %{id: did, did: did, space: space, created_at: System.os_time(:microsecond)}
    PzdbConnector.write(actor, uri, [row])
  end
end
