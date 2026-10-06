defmodule Przma.Circle.Circles do
  @moduledoc """
  Circles (groups). A circle's data lives in its OWNER's database:

      circle:private:circles:{circle_id}                 name, settings, counters, invite code
      circle:private:members:{circle_id}_{member_key}    the roster (Przma.Circle.Members)
      circle:private:pins:{circle_id}_{msg_id}           pinned messages (Przma.Circle.Pins)
      circle:private:followers:{circle_id}_{did_key}     followers of a public circle

  Every member (the owner too) has a small pointer in their OWN database,
  which is how "my circles" and "who owns circle X" are answered:

      circle:private:memberships:{circle_id}             owner_did, role, status

  Shared directory: invite code -> circle, and the public circle index.
  """

  alias Przma.Circle.{Members, Permissions}
  alias Przma.Notify.{Notifications, Publisher}
  alias Przma.Social.{Directory, Key, Store}

  @hidden ~w(deleted transferred)

  def create(%{did: owner}, name, opts \\ %{}) do
    circle_id = Key.circle_id()
    code = Key.invite_code()
    name = clean_name(name)
    visibility = if opts[:visibility] == "public", do: "public", else: "private"

    circle = %{
      "circle_id" => circle_id,
      "owner_did" => owner,
      "name" => name,
      "visibility" => visibility,
      "member_count" => 1,
      "audience_count" => 0,
      "follower_count" => 0,
      "invite_code" => code,
      "join_approval_required" => opts[:join_approval_required] != false,
      "max_members" => max_members(opts[:max_members]),
      "status" => "active"
    }

    with :ok <- Store.put(owner, "circle", "circles", circle_id, circle),
         :ok <-
           Members.write_row(owner, circle_id, owner, %{
             "role" => "owner",
             "status" => "active",
             "join_method" => "owner",
             "invited_by" => owner,
             "joined_at" => System.os_time(:microsecond)
           }),
         :ok <- Members.write_pointer(owner, circle, "owner", "active"),
         :ok <- Directory.put_invite(code, circle_id, owner),
         :ok <- sync_index(circle) do
      get_for(owner, circle_id)
    end
  end

  @doc "The circle document from the owner's database (not found once deleted or transferred away)."
  def get(owner_did, circle_id) do
    with true <- Key.valid_id?(circle_id),
         {:ok, %{"status" => status} = circle} when status not in @hidden <-
           Store.get(owner_did, "circle", "circles", circle_id) do
      {:ok, circle}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc "Finds the circle through the caller's own membership pointer."
  def locate(did, circle_id) do
    with true <- Key.valid_id?(circle_id),
         {:ok, %{"owner_did" => owner} = pointer} <- Store.get(did, "circle", "memberships", circle_id),
         {:ok, circle} <- get(owner, circle_id) do
      {:ok, circle, pointer}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc "Circle as the caller sees it (adds my_role / my_status)."
  def get_for(did, circle_id) do
    with {:ok, circle, %{"status" => status} = pointer} when status in ~w(active pending) <-
           locate(did, circle_id) do
      {:ok, view(circle, pointer)}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc "Circles the caller owns or joined (including join requests still pending)."
  def my_circles(did) do
    with {:ok, pointers} <- Store.list(did, "circle", "memberships", limit: 1000) do
      circles =
        for %{"status" => status, "owner_did" => owner, "circle_id" => id} = pointer <- pointers,
            status in ~w(active pending),
            {:ok, circle} <- [get(owner, id)] do
          view(circle, pointer)
        end

      {:ok, circles}
    end
  end

  def update(%{did: did}, circle_id, attrs) do
    with {:ok, %{owner: owner, circle: circle}} <- Members.authorize(did, circle_id, "edit_circle_settings") do
      changes =
        %{}
        |> put_change("name", attrs[:name] && clean_name(attrs[:name]))
        |> put_change("visibility", attrs[:visibility] in ~w(public private) && attrs[:visibility])
        |> put_bool("join_approval_required", attrs[:join_approval_required])
        |> put_change("max_members", attrs[:max_members] && max_members(attrs[:max_members]))

      with :ok <- Store.put(owner, "circle", "circles", circle_id, changes),
           :ok <- sync_index(Map.merge(circle, changes)) do
        Publisher.circle_event(circle_id, "circle_updated", %{actor_did: did})
        get_for(did, circle_id)
      end
    end
  end

  def delete(%{did: did}, circle_id) do
    with {:ok, %{owner: owner, circle: circle}} <- Members.authorize(did, circle_id, "delete_circle"),
         {:ok, members} <- Members.list(owner, circle_id),
         :ok <- Store.put(owner, "circle", "circles", circle_id, %{"status" => "deleted"}) do
      Enum.each(members, &Members.write_row(owner, circle_id, &1["member_did"], %{"status" => "deleted"}))
      Members.write_pointer(owner, circle, "owner", "deleted")
      Directory.close_invite(circle["invite_code"])
      Directory.unindex_circle(circle_id)

      others = for m <- members, m["member_did"] != owner, do: m["member_did"]

      Notifications.send(
        others,
        did,
        "CircleDeleted",
        "circle",
        "#{circle["name"]} was deleted",
        %{"circle_id" => circle_id},
        pointer: %{"circle_id" => circle_id, "status" => "deleted"}
      )

      Publisher.circle_event(circle_id, "circle_deleted", %{actor_did: did})
      {:ok, %{"circle_id" => circle_id, "status" => "deleted"}}
    end
  end

  # ── public circles ───────────────────────────────────────────────────

  def discover(limit \\ 50), do: Directory.list_public_circles(limit)

  @doc "Follows a public circle (no approval). The owner is notified."
  def follow(%{did: did}, circle_id) do
    with {:ok, %{"owner_did" => owner}} <- Directory.public_circle(circle_id),
         {:ok, circle} <- get(owner, circle_id) do
      record = circle_id <> "_" <> Key.did_key(did)

      case Store.get(owner, "circle", "followers", record) do
        {:ok, %{"status" => "active"}} ->
          :ok

        _ ->
          Store.put(owner, "circle", "followers", record, %{
            "circle_id" => circle_id,
            "follower_did" => did,
            "status" => "active",
            "followed_at" => System.os_time(:microsecond)
          })

          bump(owner, circle_id, "follower_count", 1)

          if did != owner do
            Notifications.send(
              [owner],
              did,
              "CircleFollowed",
              "follow",
              "#{Directory.display_name(did)} followed #{circle["name"]}",
              %{"circle_id" => circle_id, "subject_did" => did}
            )
          end

          Publisher.circle_event(circle_id, "new_follower", %{member_did: did})
      end

      {:ok, %{"circle_id" => circle_id, "status" => "following"}}
    end
  end

  # ── helpers used by Members ──────────────────────────────────────────

  @doc "Atomically changes one of the circle's counters."
  def bump(owner, circle_id, field, delta),
    do: Store.put(owner, "circle", "circles", circle_id, %{"$inc" => %{field => delta}})

  def counter_for("audience"), do: "audience_count"
  def counter_for(_role), do: "member_count"

  @doc "Keeps the shared directory (public index) in line with the circle's visibility."
  def sync_index(%{"visibility" => "public"} = c), do: Directory.index_circle(c["circle_id"], c["owner_did"], c["name"])
  def sync_index(%{"circle_id" => id}), do: Directory.unindex_circle(id)

  def can?(action, role), do: Permissions.can?(action, role)

  # ── private ──────────────────────────────────────────────────────────

  defp view(circle, pointer) do
    circle
    |> Map.put("my_role", pointer["role"])
    |> Map.put("my_status", pointer["status"])
  end

  defp clean_name(name) do
    case name |> to_string() |> String.trim() |> String.slice(0, 100) do
      "" -> "Untitled Circle"
      cleaned -> cleaned
    end
  end

  defp max_members(n) when is_integer(n) and n >= 1, do: min(n, 256)
  defp max_members(_), do: 256

  defp put_change(map, _key, nil), do: map
  defp put_change(map, _key, false), do: map
  defp put_change(map, key, value), do: Map.put(map, key, value)

  defp put_bool(map, key, value) when is_boolean(value), do: Map.put(map, key, value)
  defp put_bool(map, _key, _value), do: map
end
