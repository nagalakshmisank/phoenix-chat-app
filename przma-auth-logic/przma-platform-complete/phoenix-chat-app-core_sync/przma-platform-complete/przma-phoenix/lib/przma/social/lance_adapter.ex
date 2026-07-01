# lib/przma/social/lance_adapter.ex
#
# Thin Elixir adapter for social Lance operations.
# Calls Rust NIFs for membership and follower reads/writes.
# Keeps all Lance details out of identity.ex and circles.ex.

defmodule PRZMA.Social.LanceAdapter do
  alias PRZMA.Calendar.NIF
  require Logger

  @base_path Application.compile_env(:przma, [:vault, :base_path], "/var/przma/vaults")

  # ── MEMBERSHIP OPERATIONS ────────────────────────────────────────────────

  @doc "Write a membership record to the member's social Lance table"
  def insert_membership(m) do
    case NIF.social_insert_membership(@base_path, Jason.encode!(m)) do
      :ok           -> :ok
      {:error, msg} -> {:error, msg}
    end
  end

  @doc "Get a role from Lance (cache miss path)"
  def get_membership_role(did, circle_did) do
    case NIF.social_get_role(@base_path, did, circle_did) do
      {:ok, json}           -> {:ok, Jason.decode!(json)}
      {:error, "not_found"} -> {:error, :not_found}
      {:error, msg}         -> {:error, msg}
    end
  end

  @doc "Soft-delete: mark membership is_active = false"
  def deactivate_membership(did, circle_did) do
    case NIF.social_deactivate_membership(@base_path, did, circle_did) do
      :ok           -> :ok
      {:error, msg} -> {:error, msg}
    end
  end

  @doc "Update role in the member's Lance file"
  def update_membership_role(did, circle_did, new_role) do
    case NIF.social_update_role(@base_path, did, circle_did, new_role) do
      :ok           -> :ok
      {:error, msg} -> {:error, msg}
    end
  end

  # ── FOLLOWER OPERATIONS ───────────────────────────────────────────────────

  @doc "Write a follower entry to the owner's social Lance table"
  def insert_follower(%{did: owner_did} = follower) do
    data = Jason.encode!(%{
      owner_did:    owner_did,
      follower_did: follower.follower_did,
      inbox_url:    follower.inbox_url,
      is_active:    true,
    })
    case NIF.social_insert_follower(@base_path, data) do
      :ok           -> :ok
      {:error, msg} -> {:error, msg}
    end
  end

  @doc "List all active followers for a DID"
  def list_followers(did) do
    case NIF.social_list_followers(@base_path, did) do
      {:ok, json}   -> Jason.decode!(json)
      {:error, _}   -> []
    end
  end

  @doc "Remove a follower entry"
  def remove_follower(owner_did, follower_did) do
    case NIF.social_remove_follower(@base_path, owner_did, follower_did) do
      :ok           -> :ok
      {:error, msg} -> {:error, msg}
    end
  end
end
