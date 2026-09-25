defmodule Przma.Vault.SpaceProvisioner do
  @moduledoc """
  Runs once after Keycloak registration (safe to re-run). Steps, in order:

    1. CouchDB  — the user's ONE database (CouchVault):
                  partitioned, q=1, admin-only, _design/przma (from
                  NamespacePolicy), _design/folders, by-space index
    2. Profile  — vault:private:profile via PzdbConnector (fields in CouchDB,
                  JSON mirror in S3 at did_…/vault/private/profile.couch.json)
    3. Lance    — public/professional "_meta" tables, exactly as before (untouched)

  No marker/placeholder documents are created: a namespace/space "folder"
  appears in CouchDB and S3 when its first real document is written
  (e.g. vault:private:profile creates vault/private).

  Every DOCUMENT goes through PzdbConnector — pzdb URI, NamespacePolicy,
  PzdbAuthorization. Step 1 creates the empty container only (no data)
  and is bound to the actor's own DID.

  Re-running is harmless: the database is reused, and
  {:error, :already_exists} from step 2 is treated as success.
  """

  alias Przma.Storage.CouchVault
  alias Przma.Vault.{Profile, PzdbConnector, PzdbUri}

  @lance_meta_spaces ["public", "professional"]

  @spec provision_all(PzdbConnector.actor(), String.t(), map(), keyword()) :: :ok | {:error, term()}
  def provision_all(%{did: did} = actor, tenant_uuid, profile_attrs, opts \\ []) do
    tier = Keyword.get(opts, :tier, 1)

    with {:ok, _db} <- step(:couchdb, CouchVault.ensure_user_db(actor, did)),
         :ok <- step(:profile, ensure_profile(actor, tenant_uuid, Map.put(profile_attrs, :tier, tier))),
         :ok <- step(:lance_meta, provision_lance_meta(actor, tenant_uuid, did)) do
      :ok
    end
  end

  # Tags the failing step so the API error says WHERE registration stopped.
  defp step(_name, :ok), do: :ok
  defp step(_name, {:ok, _} = ok), do: ok
  defp step(name, {:error, reason}), do: {:error, {name, reason}}

  defp ensure_profile(actor, tenant_uuid, attrs) do
    case Profile.create(actor, tenant_uuid, attrs) do
      :ok -> :ok
      {:error, :already_exists} -> :ok
      err -> err
    end
  end

  # UNCHANGED behaviour from the previous version — still Lance.
  defp provision_lance_meta(actor, tenant_uuid, did) do
    Enum.reduce_while(@lance_meta_spaces, :ok, fn space, :ok ->
      uri =
        %PzdbUri{transport: :s3, tenant_id: tenant_uuid, did: did, namespace: space, table: "_meta"}
        |> PzdbUri.to_string()

      row = %{id: did, did: did, space: space, created_at: System.os_time(:microsecond)}

      case PzdbConnector.write(actor, uri, [row]) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end
end
