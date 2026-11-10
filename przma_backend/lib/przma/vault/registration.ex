defmodule Przma.Vault.Registration do
  @moduledoc """
  Registration completion, shared by the REST controller and GraphQL
  resolver so both follow exactly the same path.

  Identity comes ONLY from the verified Keycloak token (set by
  KeycloakAuth) — never from request parameters. The only client input
  is the optional nickname.

  Order (authorisation scope):
    1. Przma.Authz.Registration.ensure_account/1 — central Postgres rows
       (account, role, workspace, entitlements, storage location, quota,
       audit) and, for tier2, the user's own bucket
    2. LanceDB setup below — now written under the user's own base path
       (Przma.Storage.Location.base_for/1)
    3. Przma.Authz.Registration.activate/1 — account pending_setup -> active
  If step 2 fails the account stays pending_setup and the next call retries.
  """

  alias Przma.Storage.LanceDocPath
  alias Przma.Vault.SpaceProvisioner

  @type identity :: %{
          did: String.t(),
          tenant_uuid: String.t(),
          storage_tier: 1..3,
          token_claims: map(),
          ip: term()
        }

  @spec complete(identity(), String.t() | nil) :: {:ok, map()} | {:error, term()}
  def complete(%{did: did, tenant_uuid: tenant_uuid} = identity, nickname \\ nil) do
    claims = identity[:token_claims] || %{}
    actor = %{did: did, origin_instance_id: nil, portable_grant: nil}

    attrs =
      %{email: claims["email"], nickname: blank_to_nil(nickname) || claims["preferred_username"]}
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    with {:ok, account} <- authz_account(identity),
         :ok <- SpaceProvisioner.provision_all(actor, tenant_uuid, attrs, tier: storage_tier(account, identity)) do
      Przma.Authz.Registration.activate(did)
      # Shared account directory: lets other users find this DID (add
      # contact, send message). Best-effort — never fails registration.
      Przma.Social.Directory.put_account(did, tenant_uuid, attrs)
      # Default personal calendar. Best-effort and idempotent (its id is
      # derived from the DID); myCalendars also creates it if missing.
      ensure_default_calendar(did)
      # `database` is kept (same key the frontend already reads); it holds
      # the user's S3 folder (now in their own bucket for tier 2).
      prefix = LanceDocPath.user_prefix(did)

      {:ok,
       %{
         status: "registered",
         did: did,
         gid: tenant_uuid,
         database: prefix,
         storage_path: prefix,
         plan: account[:plan_code]
       }}
    end
  end

  # Central authz rows first. AUTHZ_MODE=off skips them (old behaviour).
  defp authz_account(identity) do
    if Przma.Authz.mode() == "off" do
      {:ok, %{}}
    else
      Przma.Authz.Registration.ensure_account(identity)
    end
  end

  defp storage_tier(%{storage: %{storage_tier: t}}, _identity) when is_integer(t), do: t
  defp storage_tier(_account, identity), do: identity[:storage_tier] || 1

  defp ensure_default_calendar(did) do
    Przma.Calendar.ensure_default_calendar(did)
  rescue
    error ->
      require Logger
      Logger.warning("default calendar for #{did} not created: #{inspect(error)}")
      :ok
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(s) when is_binary(s), do: if(String.trim(s) == "", do: nil, else: String.trim(s))
end
