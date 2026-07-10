defmodule PRZMA.Social.CircleSync do
  alias PRZMA.PzDb.NIF
  alias PRZMA.Social.ActivitySync
  require Logger

  defp vault_base, do: Application.get_env(:przma, :vault_base_path, "s3://perkeep")
  defp dir_for(did), do: "#{vault_base()}/#{sanitize(did)}/social"
  defp directory_dir, do: "#{vault_base()}/przma-directory/circles"
  defp sanitize(did), do: did |> String.replace(":", "_") |> String.replace(".", "_")
  defp member_row_id(circle_id, did), do: "#{circle_id}:#{did}"

  # ── CREATE ──────────────────────────────────────────────────────────
  def create_circle(owner_did, name, opts \\ %{}) do
    circle_id   = generate_circle_id()
    invite_code = generate_invite_code()
    now         = System.os_time(:microsecond)
    base_url    = Application.get_env(:przma, :base_url, "http://172.235.18.126:4201")

    circle_row = %{
      "id" => circle_id, "owner_did" => owner_did, "name" => name,
      "member_count" => 1, "invite_code" => invite_code,
      "invite_link" => "#{base_url}/join/#{invite_code}",
      "join_approval_required" => Map.get(opts, "join_approval_required", true),
      "max_members" => Map.get(opts, "max_members", 256),
      "created_at" => now, "updated_at" => now
    }

    owner_row = %{
      "id" => member_row_id(circle_id, owner_did), "circle_id" => circle_id,
      "member_did" => owner_did, "owner_did" => owner_did,
      "role" => "owner", "status" => "active", "invited_by" => owner_did,
      "joined_at" => now, "updated_at" => now
    }

    with {:ok, _} <- upsert(owner_did, "circles", circle_row),
         {:ok, _} <- upsert(owner_did, "circle_members", owner_row),
         {:ok, _} <- upsert_raw(directory_dir(), "circle_invites", %{
           "id" => invite_code, "invite_code" => invite_code,
           "circle_id" => circle_id, "owner_did" => owner_did, "created_at" => now
         }) do
      {:ok, circle_row}
    end
  end

  def resolve_owner_did(did, circle_id) do
    with {:ok, rows} <- read_table(did, "circle_members") do
      case Enum.find(rows, &(&1["circle_id"] == circle_id)) do
        %{"owner_did" => owner_did} -> {:ok, owner_did}
        nil -> {:error, :not_found}
      end
    end
  end

  def get_circle_for(did, circle_id) do
    with {:ok, owner_did} <- resolve_owner_did(did, circle_id) do
      get_circle(owner_did, circle_id)
    end
  end

  # ── JOIN ────────────────────────────────────────────────────────────
  def join_circle(member_did, invite_code) do
    with {:ok, %{"circle_id" => circle_id, "owner_did" => owner_did}} <- resolve_invite(invite_code),
         {:ok, circle} <- get_circle(owner_did, circle_id) do
      status = if circle["join_approval_required"], do: "pending", else: "active"
      now = System.os_time(:microsecond)

      roster_row = %{
        "id" => member_row_id(circle_id, member_did), "circle_id" => circle_id,
        "member_did" => member_did, "owner_did" => owner_did,
        "role" => "member", "status" => status, "invited_by" => member_did,
        "joined_at" => now, "updated_at" => now
      }

      with {:ok, _} <- upsert(owner_did, "circle_members", roster_row) do
        if status == "active" do
          mirror_to_member(member_did, roster_row)
          bump_member_count(owner_did, circle_id, 1)
          notify_join(member_did, owner_did, circle_id, "Joined")
          {:ok, %{status: "active", circle_id: circle_id}}
        else
          notify_join(member_did, owner_did, circle_id, "JoinRequest")
          {:ok, %{status: "pending", circle_id: circle_id}}
        end
      end
    end
  end

  def approve_member(owner_did, circle_id, member_did) do
    with {:ok, row} <- get_member(owner_did, circle_id, member_did) do
      updated = Map.merge(row, %{"status" => "active", "updated_at" => System.os_time(:microsecond)})
      with {:ok, _} <- upsert(owner_did, "circle_members", updated) do
        mirror_to_member(member_did, updated)
        bump_member_count(owner_did, circle_id, 1)
        {:ok, updated}
      end
    end
  end

  def deny_member(owner_did, circle_id, member_did) do
    with {:ok, row} <- get_member(owner_did, circle_id, member_did) do
      updated = Map.merge(row, %{"status" => "removed", "updated_at" => System.os_time(:microsecond)})
      upsert(owner_did, "circle_members", updated)
    end
  end

  def remove_member(owner_did, circle_id, target_did) do
    with {:ok, target_row} <- get_member(owner_did, circle_id, target_did) do
      updated = Map.merge(target_row, %{"status" => "removed", "updated_at" => System.os_time(:microsecond)})
      with {:ok, _} <- upsert(owner_did, "circle_members", updated) do
        bump_member_count(owner_did, circle_id, -1)
        {:ok, updated}
      end
    end
  end

  # ── READ ────────────────────────────────────────────────────────────
  def list_my_circles(did), do: read_table(did, "circle_members")

  def list_members(owner_did, circle_id) do
    with {:ok, rows} <- read_table(owner_did, "circle_members") do
      {:ok, Enum.filter(rows, &(&1["circle_id"] == circle_id and &1["status"] == "active"))}
    end
  end

  def get_circle(owner_did, circle_id) do
    with {:ok, rows} <- read_table(owner_did, "circles") do
      case Enum.find(rows, &(&1["id"] == circle_id)) do
        nil -> {:error, :not_found}
        row -> {:ok, row}
      end
    end
  end

  def get_member(owner_did, circle_id, member_did) do
    with {:ok, rows} <- read_table(owner_did, "circle_members") do
      case Enum.find(rows, &(&1["id"] == member_row_id(circle_id, member_did))) do
        nil -> {:error, :not_found}
        row -> {:ok, row}
      end
    end
  end

  def get_role(owner_did, circle_id, did) do
    case get_member(owner_did, circle_id, did) do
      {:ok, %{"role" => role, "status" => "active"}} -> {:ok, role}
      {:ok, _} -> {:error, :not_active}
      err -> err
    end
  end

  def expand_recipients(owner_did, circle_id) do
    with {:ok, members} <- list_members(owner_did, circle_id) do
      {:ok, Enum.map(members, & &1["member_did"])}
    end
  end

  # ── PRIVATE ─────────────────────────────────────────────────────────
  defp generate_circle_id, do: :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
  defp generate_invite_code, do: :crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false)

  defp mirror_to_member(member_did, roster_row) do
    mirrored = Map.put(roster_row, "id", member_row_id(roster_row["circle_id"], roster_row["owner_did"]))
    upsert(member_did, "circle_members", mirrored)
  end

  defp bump_member_count(owner_did, circle_id, delta) do
    with {:ok, circle} <- get_circle(owner_did, circle_id) do
      updated = Map.merge(circle, %{
        "member_count" => max((circle["member_count"] || 0) + delta, 0),
        "updated_at" => System.os_time(:microsecond)
      })
      upsert(owner_did, "circles", updated)
    end
  end

  defp notify_join(member_did, owner_did, circle_id, activity_type) do
    ActivitySync.publish(%{
      "id" => "#{activity_type}_#{circle_id}_#{member_did}_#{System.os_time(:microsecond)}",
      "did" => owner_did, "actor" => member_did, "activity_type" => activity_type,
      "space" => "circle:#{circle_id}", "to" => [owner_did],
      "raw_json" => Jason.encode!(%{circle_id: circle_id, member_did: member_did})
    })
  end

  defp resolve_invite(invite_code) do
    case NIF.pzdb_read_many(directory_dir(), "circle_invites", "invite_code = '#{invite_code}'", 1, 0) do
      {:ok, json} -> extract_one(json)
      json when is_binary(json) -> extract_one(json)
      {:error, reason} -> {:error, reason}
    end
  end

  defp upsert(did, table, row), do: upsert_raw(dir_for(did), table, row)

  defp upsert_raw(dir, table, row) do
    case NIF.pzdb_upsert(dir, table, Jason.encode!(row), Jason.encode!(["id"])) do
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

  defp extract_one(json) do
    case decode(json) do
      [row | _] -> {:ok, row}
      []        -> {:error, :invite_not_found}
    end
  end

  defp decode(json) when is_binary(json), do: decode(Jason.decode!(json))
  defp decode(%{"records" => records}) when is_list(records), do: records
  defp decode(list) when is_list(list), do: list
  defp decode(_), do: []
end