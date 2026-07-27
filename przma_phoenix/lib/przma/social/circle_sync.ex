defmodule PRZMA.Social.CircleSync do
  alias PRZMA.PzDb
  alias PRZMA.Social.ActivitySync
  require Logger

  # Circle tables live in the owner's own vault, service "social", space
  # "core". Table names (circles, circle_members, circle_invites,
  # circle_pins) already match the Rust NIF's exact schema names once
  # singularized here and re-pluralized by Namespace.resolve/2.
  defp singularize("circles"), do: "circle"
  defp singularize("circle_members"), do: "circle_member"
  defp singularize("circle_invites"), do: "circle_invite"
  defp singularize("circle_pins"), do: "circle_pin"

  # circle_invites must resolve for ANY user presenting a code, so it's kept
  # under a fixed pseudo-owner rather than any real DID. Namespace doesn't
  # validate DID format, so this is a safe, self-consistent convention.
  @directory_did "przma-directory"

  defp member_row_id(circle_id, did), do: "#{circle_id}:#{did}"

  # ── CREATE ──────────────────────────────────────────────────────────
  def create_circle(owner_did, name, opts \\ %{}) do
    circle_id   = generate_circle_id()
    invite_code = generate_invite_code()
    now         = System.os_time(:microsecond)
    base_url    = Application.get_env(:przma, :base_url, "http://172.235.18.126:4201")

    circle_row = %{
      "id" => circle_id, "owner_did" => owner_did, "name" => name,
      "member_count" => 1, "audience_count" => 0, "invite_code" => invite_code,
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
         {:ok, _} <- upsert(@directory_did, "circle_invites", %{
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

  def delete_circle(owner_did, circle_id) do
    with {:ok, circle} <- get_circle(owner_did, circle_id) do
      now = System.os_time(:microsecond)
      updated_circle = Map.merge(circle, %{"status" => "deleted", "updated_at" => now})

      with {:ok, _} <- upsert(owner_did, "circles", updated_circle),
           {:ok, members} <- list_members(owner_did, circle_id) do
        failures =
          members
          |> Enum.map(fn member ->
            deleted_row = Map.merge(member, %{"status" => "deleted", "updated_at" => now})
            row_result = upsert(owner_did, "circle_members", deleted_row)

            mirror_result =
              if member["member_did"] != owner_did do
                mirror_to_member(member["member_did"], deleted_row)
              else
                {:ok, :self}
              end

            {member["member_did"], row_result, mirror_result}
          end)
          |> Enum.reject(fn {_did, r, m} -> match?({:ok, _}, r) and match?({:ok, _}, m) end)

        if failures != [] do
          Logger.warning("[CircleSync] delete_circle partial failure circle_id=#{circle_id} failures=#{inspect(failures)}")
        end

        PRZMAWeb.Endpoint.broadcast("circle:#{circle_id}", "circle_deleted", %{"circle_id" => circle_id})
        {:ok, updated_circle}
      end
    end
  end

  # ── OWNERSHIP TRANSFER ─────────────────────────────────────────────
  # Circle + roster "source of truth" rows live in the owner's own vault.
  # Transferring means: write fresh copies under the new owner's vault,
  # mark the old ones "transferred" in the old owner's vault, flip the
  # old owner to "member" / new owner to "owner", and re-mirror every
  # member's row so future lookups follow the new owner_did.
  def transfer_ownership(current_owner_did, circle_id, new_owner_did) do
    with {:ok, circle} <- get_circle(current_owner_did, circle_id),
         {:ok, new_owner_row} <- get_member(current_owner_did, circle_id, new_owner_did) do
      if new_owner_row["status"] != "active" do
        {:error, :target_not_active_member}
      else
        now = System.os_time(:microsecond)
        new_circle = Map.merge(circle, %{"owner_did" => new_owner_did, "updated_at" => now})
        old_circle_marker = Map.merge(circle, %{"status" => "transferred", "updated_at" => now})

        with {:ok, members} <- list_members(current_owner_did, circle_id),
             {:ok, _} <- upsert(new_owner_did, "circles", new_circle),
             {:ok, _} <- upsert(current_owner_did, "circles", old_circle_marker) do
          Enum.each(members, fn member ->
            new_role =
              cond do
                member["member_did"] == new_owner_did -> "owner"
                member["member_did"] == current_owner_did -> "member"
                true -> member["role"]
              end

            updated_row =
              Map.merge(member, %{"owner_did" => new_owner_did, "role" => new_role, "updated_at" => now})

            upsert(new_owner_did, "circle_members", updated_row)
            mirror_to_member(member["member_did"], updated_row)
          end)

          PRZMAWeb.Endpoint.broadcast("circle:#{circle_id}", "ownership_transferred", %{
            "circle_id" => circle_id, "new_owner_did" => new_owner_did
          })

          {:ok, new_circle}
        end
      end
    end
  end

  # ── JOIN ────────────────────────────────────────────────────────────
  def join_circle(member_did, invite_code) do
    with {:ok, %{"circle_id" => circle_id, "owner_did" => owner_did}} <- resolve_invite(invite_code),
         {:ok, circle} <- get_circle(owner_did, circle_id) do
      role   = capacity_role(circle)
      status = if circle["join_approval_required"], do: "pending", else: "active"
      now    = System.os_time(:microsecond)

      roster_row = %{
        "id" => member_row_id(circle_id, member_did), "circle_id" => circle_id,
        "member_did" => member_did, "owner_did" => owner_did,
        "role" => role, "status" => status, "invited_by" => member_did,
        "joined_at" => now, "updated_at" => now
      }

      with {:ok, _} <- upsert(owner_did, "circle_members", roster_row) do
        if status == "active" do
          mirror_to_member(member_did, roster_row)
          bump_count(owner_did, circle_id, role, 1)
          notify_join(member_did, owner_did, circle_id, "Joined")

          PRZMAWeb.Endpoint.broadcast("circle:#{circle_id}", "member_joined", %{
            "circle_id" => circle_id, "member_did" => member_did, "role" => role
          })

          {:ok, %{status: "active", circle_id: circle_id, role: role}}
        else
          notify_join(member_did, owner_did, circle_id, "JoinRequest")

          PRZMAWeb.Endpoint.broadcast("circle:#{circle_id}", "join_requested", %{
            "circle_id" => circle_id, "member_did" => member_did
          })

          {:ok, %{status: "pending", circle_id: circle_id, role: role}}
        end
      end
    end
  end

  # Once member_count has hit max_members, anyone joining after that
  # lands in "audience" (receive-only) instead of "member" — they still
  # get in, just without send/pin rights. Tracked separately so audience
  # joins never count against the cap.
  defp capacity_role(circle) do
    member_count = circle["member_count"] || 0
    max_members  = circle["max_members"] || 256
    if member_count >= max_members, do: "audience", else: "member"
  end

  def approve_member(owner_did, circle_id, member_did) do
    with {:ok, row} <- get_member(owner_did, circle_id, member_did) do
      updated = Map.merge(row, %{"status" => "active", "updated_at" => System.os_time(:microsecond)})
      with {:ok, _} <- upsert(owner_did, "circle_members", updated) do
        mirror_to_member(member_did, updated)
        bump_count(owner_did, circle_id, row["role"], 1)

        PRZMAWeb.Endpoint.broadcast("circle:#{circle_id}", "member_joined", %{
          "circle_id" => circle_id, "member_did" => member_did, "role" => row["role"]
        })

        {:ok, updated}
      end
    end
  end

  def deny_member(owner_did, circle_id, member_did) do
    with {:ok, row} <- get_member(owner_did, circle_id, member_did) do
      updated = Map.merge(row, %{"status" => "removed", "updated_at" => System.os_time(:microsecond)})
      with {:ok, _} <- upsert(owner_did, "circle_members", updated) do
        PRZMAWeb.Endpoint.broadcast("circle:#{circle_id}", "member_removed", %{
          "circle_id" => circle_id, "member_did" => member_did
        })
        {:ok, updated}
      end
    end
  end

  def remove_member(owner_did, circle_id, target_did) do
    with {:ok, target_row} <- get_member(owner_did, circle_id, target_did) do
      updated = Map.merge(target_row, %{"status" => "removed", "updated_at" => System.os_time(:microsecond)})
      with {:ok, _} <- upsert(owner_did, "circle_members", updated) do
        bump_count(owner_did, circle_id, target_row["role"], -1)

        PRZMAWeb.Endpoint.broadcast("circle:#{circle_id}", "member_removed", %{
          "circle_id" => circle_id, "member_did" => target_did
        })

        {:ok, updated}
      end
    end
  end

  # ── LEAVE ───────────────────────────────────────────────────────────
  def leave_circle(member_did, circle_id) do
    with {:ok, owner_did}  <- resolve_owner_did(member_did, circle_id),
         {:ok, member_row} <- get_member(owner_did, circle_id, member_did) do
      if member_row["role"] == "owner" do
        {:error, :owner_cannot_leave}
      else
        now = System.os_time(:microsecond)
        updated = Map.merge(member_row, %{"status" => "left", "updated_at" => now})

        with {:ok, _} <- upsert(owner_did, "circle_members", updated) do
          mirror_to_member(member_did, updated)
          bump_count(owner_did, circle_id, member_row["role"], -1)

          PRZMAWeb.Endpoint.broadcast("circle:#{circle_id}", "member_left", %{
            "circle_id" => circle_id, "member_did" => member_did
          })

          {:ok, updated}
        end
      end
    end
  end

  # ── READ ────────────────────────────────────────────────────────────
  def list_my_circles(did) do
    with {:ok, rows} <- read_table(did, "circle_members") do
      mine =
        rows
        |> Enum.filter(&(&1["member_did"] == did and &1["status"] not in ["deleted", "removed", "left"]))
        |> Enum.filter(&circle_still_active?/1)

      {:ok, mine}
    end
  end

  defp circle_still_active?(%{"owner_did" => owner_did, "circle_id" => circle_id}) do
    match?({:ok, _}, get_circle(owner_did, circle_id))
  end

  def list_members(owner_did, circle_id) do
    with {:ok, rows} <- read_table(owner_did, "circle_members") do
      {:ok, Enum.filter(rows, &(&1["circle_id"] == circle_id and &1["status"] == "active"))}
    end
  end

  def get_circle(owner_did, circle_id) do
    with {:ok, rows} <- read_table(owner_did, "circles") do
      case Enum.find(rows, &(&1["id"] == circle_id and &1["status"] not in ["deleted", "transferred"])) do
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

  # ── DELETE MESSAGE (everywhere) ────────────────────────────────────
  # Removes the message from the sender's outbox AND from every current
  # member's inbox — including the sender's OWN inbox copy, since
  # ActivitySync.publish/1 self-delivers to every `to` entry, and the
  # sender is always included in `to` (expand_recipients doesn't filter
  # them out). Skipping the sender here was the bug: their inbox row
  # survived and re-appeared on the next GET /inbox poll even though the
  # live "message_deleted" broadcast hid it instantly for anyone watching.
  def delete_message_everywhere(sender_did, owner_did, circle_id, message_id) do
    with {:ok, to_list} <- expand_recipients(owner_did, circle_id) do
      recipients = Enum.uniq(to_list)

      results =
        [ActivitySync.delete_activity(sender_did, message_id, "outbox")] ++
          Enum.map(recipients, &ActivitySync.delete_activity(&1, message_id, "inbox"))

      # :not_found is fine here — it just means that member never had a
      # copy (e.g. joined after the message was sent) or it was already
      # deleted; only genuine failures should block the response.
      failures =
        Enum.reject(results, fn
          {:ok, _} -> true
          {:error, :not_found} -> true
          _ -> false
        end)

      if failures == [] do
        {:ok, :deleted_everywhere}
      else
        Logger.warning("[CircleSync] partial delete for message_id=#{message_id} failures=#{inspect(failures)}")
        {:error, :partial_delete}
      end
    end
  end

  # ── PIN / UNPIN ─────────────────────────────────────────────────────
  def pin_message(owner_did, circle_id, message_id, pinned_by) do
    row = %{
      "id" => "#{circle_id}:#{message_id}", "circle_id" => circle_id,
      "message_id" => message_id, "pinned_by" => pinned_by,
      "pinned_at" => System.os_time(:microsecond)
    }
    upsert(owner_did, "circle_pins", row)
  end

  def unpin_message(owner_did, circle_id, message_id) do
    with {:ok, rows} <- read_table(owner_did, "circle_pins") do
      case Enum.find(rows, &(&1["id"] == "#{circle_id}:#{message_id}")) do
        nil -> {:error, :not_found}
        row -> upsert(owner_did, "circle_pins", Map.put(row, "status", "unpinned"))
      end
    end
  end

  def get_pin(owner_did, circle_id, message_id) do
    with {:ok, rows} <- read_table(owner_did, "circle_pins") do
      case Enum.find(rows, &(&1["id"] == "#{circle_id}:#{message_id}" and &1["status"] != "unpinned")) do
        nil -> {:error, :not_found}
        row -> {:ok, row}
      end
    end
  end

  def list_pins(owner_did, circle_id) do
    with {:ok, rows} <- read_table(owner_did, "circle_pins") do
      {:ok, Enum.filter(rows, &(&1["circle_id"] == circle_id and &1["status"] != "unpinned"))}
    end
  end

  def update_role(owner_did, circle_id, member_did, new_role) do
    with {:ok, row} <- get_member(owner_did, circle_id, member_did) do
      updated = Map.merge(row, %{"role" => new_role, "updated_at" => System.os_time(:microsecond)})
      with {:ok, _} <- upsert(owner_did, "circle_members", updated) do
        mirror_to_member(member_did, updated)
        {:ok, updated}
      end
    end
  end

  def list_pending(owner_did, circle_id) do
    with {:ok, rows} <- read_table(owner_did, "circle_members") do
      {:ok, Enum.filter(rows, &(&1["circle_id"] == circle_id and &1["status"] == "pending"))}
    end
  end

  # ── PRIVATE ─────────────────────────────────────────────────────────
  defp generate_circle_id, do: :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
  defp generate_invite_code, do: :crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false)

  defp mirror_to_member(member_did, roster_row) do
    mirrored = Map.put(roster_row, "id", member_row_id(roster_row["circle_id"], member_did))
    upsert(member_did, "circle_members", mirrored)
  end

  defp bump_count(owner_did, circle_id, "audience", delta),
    do: bump_audience_count(owner_did, circle_id, delta)
  defp bump_count(owner_did, circle_id, _role, delta),
    do: bump_member_count(owner_did, circle_id, delta)

  defp bump_member_count(owner_did, circle_id, delta) do
    with {:ok, circle} <- get_circle(owner_did, circle_id) do
      updated = Map.merge(circle, %{
        "member_count" => max((circle["member_count"] || 0) + delta, 0),
        "updated_at" => System.os_time(:microsecond)
      })
      upsert(owner_did, "circles", updated)
    end
  end

  defp bump_audience_count(owner_did, circle_id, delta) do
    with {:ok, circle} <- get_circle(owner_did, circle_id) do
      updated = Map.merge(circle, %{
        "audience_count" => max((circle["audience_count"] || 0) + delta, 0),
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
    uri = "pzdb://#{@directory_did}/social/core/circle_invite/#{invite_code}"
    case PzDb.query(uri, filter: "invite_code = '#{invite_code}'", limit: 1) do
      {:ok, %{"records" => [row | _]}} -> {:ok, row}
      {:ok, %{"records" => []}}        -> {:error, :invite_not_found}
      {:error, reason}                 -> {:error, reason}
    end
  end

  defp upsert(did, table, row) do
    uri = "pzdb://#{did}/social/core/#{singularize(table)}/#{row["id"]}"
    PzDb.write(uri, row)
  end

  defp read_table(did, table) do
    uri = "pzdb://#{did}/social/core/#{singularize(table)}/_"
    case PzDb.query(uri, limit: 500) do
      {:ok, %{"records" => records}} -> {:ok, records}
      {:ok, other}                   -> {:ok, decode(other)}
      {:error, reason}               -> {:error, reason}
    end
  end

  defp decode(json) when is_binary(json), do: decode(Jason.decode!(json))
  defp decode(%{"records" => records}) when is_list(records), do: records
  defp decode(list) when is_list(list), do: list
  defp decode(_), do: []
end