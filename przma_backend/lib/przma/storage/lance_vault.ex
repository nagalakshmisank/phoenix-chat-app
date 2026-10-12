defmodule Przma.Storage.LanceVault do
  @moduledoc """
  Registration-time step for a user's doc store (replaces CouchVault).

  With CouchDB this created a database, security object and design docs.
  With LanceDB on S3 there is nothing to create up front: S3 has no real
  folders, and each `.lance` table is created by the first write to it
  (same "no marker documents" rule as before — a folder appears when its
  first real row is written).

  What it still does:
    * keeps the guard that a user can only provision their OWN storage
    * checks that the storage base path is configured
    * returns the user's S3 prefix (shown in the registration response)
  """

  alias Przma.Storage.LanceDocPath

  @spec ensure_user_vault(actor :: %{did: String.t()}, did :: String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def ensure_user_vault(%{did: actor_did}, did) when actor_did != did,
    do: {:error, :cannot_provision_other_users_storage}

  def ensure_user_vault(_actor, did) do
    case Application.get_env(:przma, :vault_base_path) do
      base when is_binary(base) and base != "" -> {:ok, LanceDocPath.user_prefix(did)}
      _ -> {:error, :vault_base_path_not_configured}
    end
  end
end
