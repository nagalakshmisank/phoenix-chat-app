defmodule PRZMA.Social.Follows do
  @moduledoc """
  Person-to-person follow (follow_a_person_flow.png + account_settings_visibility_toggle.png).

  NOT part of IMPLEMENTATION_GUIDE.md — that guide only covers circle-level
  follow (public circles, always instant). This module is the gap-fill for
  account-level privacy: following a *person* is instant if their account
  is public (Auth.is_private == false), or pending-until-approved if private.

  Mirrors the structure of circle_sync.ex's join_circle/approve_member/
  deny_member pattern (same dir_for/upsert/read_table shape), since that's
  the closest existing analog to "pending -> approve/deny".

  Row is written to BOTH the follower's own vault and the target's own
  vault (same id, "{follower_did}:{target_did}") so each side can read
  their own copy of the relationship without a cross-vault read.
  """

  alias PRZMA.PzDb.NIF
  alias PRZMA.Auth
  alias PRZMA.Social.Contacts
  require Logger

  defp vault_base, do: Application.get_env(:przma, :vault_base_path, "s3://perkeep")
  defp dir_for(did), do: "#{vault_base()}/#{sanitize(did)}/social"
  defp sanitize(did), do: did |> String.replace(":", "_") |> String.replace(".", "_")
  defp follow_id(follower_did, target_did), do: "#{follower_did}:#{target_did}"

  @doc """
  Alice (follower_did) follows Bob (target_did).
  - Bob's account is_private == false -> instant, status "active"
  - Bob's account is_private == true  -> "pending", awaiting Bob's approve/deny
  Either way, a pending ContactSuggestion is created for Bob (reuses the
  same Contacts.create_suggestion/4 the guide's follow_circle/2 uses).
  """
  def follow(follower_did, target_did) do
    with {:ok, target} <- Auth.get_account(target_did) do
      now = System.os_time(:microsecond)
      status = if target.is_private, do: "pending", else: "active"

      row = %{
        "id" => follow_id(follower_did, target_did),
        "follower_did" => follower_did,
        "target_did" => target_did,
        "status" => status,
        "created_at" => now,
        "updated_at" => now
      }

      with {:ok, _} <- upsert(follower_did, "person_follows", row),
           {:ok, _} <- upsert(target_did, "person_follows", row) do
        Contacts.create_suggestion(target_did, follower_did, "person", "follow")
        {:ok, %{status: status, target_did: target_did}}
      end
    end
  end

  @doc "Target (owner_did) approves a pending follow from follower_did."
  def approve_follow(owner_did, follower_did) do
    with {:ok, row} <- get_follow(owner_did, follower_did) do
      updated = Map.merge(row, %{"status" => "active", "updated_at" => System.os_time(:microsecond)})

      with {:ok, _} <- upsert(owner_did, "person_follows", updated),
           {:ok, _} <- upsert(follower_did, "person_follows", updated) do
        {:ok, updated}
      end
    end
  end

  @doc "Target (owner_did) denies a pending follow from follower_did."
  def deny_follow(owner_did, follower_did) do
    with {:ok, row} <- get_follow(owner_did, follower_did) do
      updated = Map.merge(row, %{"status" => "denied", "updated_at" => System.os_time(:microsecond)})

      with {:ok, _} <- upsert(owner_did, "person_follows", updated),
           {:ok, _} <- upsert(follower_did, "person_follows", updated) do
        {:ok, updated}
      end
    end
  end

  def get_follow(owner_did, follower_did) do
    with {:ok, rows} <- read_table(owner_did, "person_follows") do
      case Enum.find(rows, &(&1["id"] == follow_id(follower_did, owner_did))) do
        nil -> {:error, :not_found}
        row -> {:ok, row}
      end
    end
  end

  def list_pending_follow_requests(owner_did) do
    with {:ok, rows} <- read_table(owner_did, "person_follows") do
      {:ok, Enum.filter(rows, &(&1["target_did"] == owner_did and &1["status"] == "pending"))}
    end
  end

  # ── PRIVATE ───────────────────────────────────────────────────────────
  defp upsert(did, table, row) do
    case NIF.pzdb_upsert(dir_for(did), table, Jason.encode!(row), Jason.encode!(["id"])) do
      {:ok, json} -> {:ok, Jason.decode!(json)}
      json when is_binary(json) -> {:ok, Jason.decode!(json)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_table(did, table) do
    case NIF.pzdb_read_many(dir_for(did), table, "", 500, 0) do
      {:ok, json} -> {:ok, decode(json)}
      json when is_binary(json) -> {:ok, decode(json)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode(json) when is_binary(json), do: decode(Jason.decode!(json))
  defp decode(%{"records" => records}) when is_list(records), do: records
  defp decode(list) when is_list(list), do: list
  defp decode(_), do: []
end
