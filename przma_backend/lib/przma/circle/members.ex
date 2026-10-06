defmodule Przma.Circle.Members do
  @moduledoc """
  Circle roster and membership changes.

  The roster lives in the circle owner's database
  (circle:private:members:{circle_id}_{member_key}). Each change:

    1. is allowed only after an invite-code check (join) or a role check
       (everything else) — see authorize/3
    2. updates the roster row in the owner's database
    3. tells the affected member through their inbox; that delivery also
       updates the member's own pointer (circle:private:memberships:…)
    4. is announced live on the circle's event channel

  Join requests are inbox items in the OWNER's inbox with a fixed id
  (chat:private:inbox:join-{circle_id}_{member_key}), so "pending
  requests" is a prefix read of that inbox and the joiner never writes
  into the roster.
  """

  alias Przma.Chat.Delivery
  alias Przma.Circle.{Circles, Permissions}
  alias Przma.Notify.{Notifications, Publisher}
  alias Przma.Social.{Contacts, Directory, Key, Store}

  # ── roster reads ─────────────────────────────────────────────────────

  def row_id(circle_id, member_did), do: circle_id <> "_" <> Key.did_key(member_did)

  def get(owner, circle_id, member_did), do: Store.get(owner, "circle", "members", row_id(circle_id, member_did))

  @doc "Active members of a circle."
  def list(owner, circle_id) do
    with {:ok, rows} <- Store.list(owner, "circle", "members", prefix: circle_id <> "_", limit: 1000) do
      {:ok, Enum.filter(rows, &(&1["status"] == "active"))}
    end
  end

  def role(owner, circle_id, did) do
    case get(owner, circle_id, did) do
      {:ok, %{"status" => "active", "role" => role}} -> {:ok, role}
      _ -> {:error, :not_a_member}
    end
  end

  @doc "The caller's view of a circle: {:ok, %{owner, circle, role}} for an active member."
  def context(did, circle_id) do
    with {:ok, circle, _pointer} <- Circles.locate(did, circle_id),
         {:ok, role} <- role(circle["owner_did"], circle_id, did) do
      {:ok, %{owner: circle["owner_did"], circle: circle, role: role}}
    end
  end

  @doc "context/2 plus a permission check for `action` (see Permissions)."
  def authorize(did, circle_id, action) do
    with {:ok, ctx} <- context(did, circle_id) do
      if Permissions.can?(action, ctx.role), do: {:ok, ctx}, else: {:error, :forbidden}
    end
  end

  @doc "Member list for the API (any active member may see it)."
  def list_for(did, circle_id) do
    with {:ok, %{owner: owner}} <- context(did, circle_id), do: list(owner, circle_id)
  end

  # ── join by invite code ──────────────────────────────────────────────

  def join(%{did: did}, invite_code) do
    with {:ok, %{"circle_id" => circle_id, "owner_did" => owner}} <- Directory.invite(invite_code),
         {:ok, circle} <- Circles.get(owner, circle_id) do
      case get(owner, circle_id, did) do
        {:ok, %{"status" => "active", "role" => role}} ->
          {:ok, join_result(circle_id, "active", role)}

        _ ->
          role = capacity_role(circle)

          if circle["join_approval_required"] == false,
            do: admit(did, circle, role),
            else: request(did, circle, role)
      end
    end
  end

  defp admit(did, %{"circle_id" => circle_id, "owner_did" => owner} = circle, role) do
    with :ok <- add_row(owner, circle_id, did, role, "link", did),
         :ok <- write_pointer(did, circle, role, "active") do
      notify(owner, did, "Joined", "#{name(did)} joined #{circle["name"]}", circle_id, did)
      Publisher.circle_event(circle_id, "member_joined", %{member_did: did, role: role})
      {:ok, join_result(circle_id, "active", role)}
    end
  end

  defp request(did, %{"circle_id" => circle_id, "owner_did" => owner} = circle, role) do
    with :ok <- write_pointer(did, circle, role, "pending"),
         {:ok, %{failed: []}} <- put_join_record(owner, circle_id, did, %{"join_status" => "pending", "requested_role" => role}) do
      notify(owner, did, "JoinRequest", "#{name(did)} asked to join #{circle["name"]}", circle_id, did)
      Publisher.circle_event(circle_id, "join_requested", %{member_did: did})
      {:ok, join_result(circle_id, "pending", role)}
    else
      {:ok, %{failed: _}} -> {:error, :owner_unreachable}
      err -> err
    end
  end

  @doc "Join requests waiting for approval (owner/admin)."
  def pending(did, circle_id) do
    with {:ok, %{owner: owner}} <- authorize(did, circle_id, "add_member"),
         {:ok, rows} <- Store.list(owner, "chat", "inbox", prefix: "join-" <> circle_id <> "_", limit: 1000) do
      {:ok,
       for %{"join_status" => "pending"} = row <- rows do
         %{
           "circle_id" => circle_id,
           "member_did" => row["actor_did"],
           "role" => row["requested_role"],
           "status" => "pending",
           "joined_at" => row["sent_at"]
         }
       end}
    end
  end

  def approve(%{did: did} = me, circle_id, member_did) do
    with {:ok, %{owner: owner, circle: circle}} <- authorize(did, circle_id, "add_member"),
         {:ok, %{"join_status" => "pending"}} <- join_record(owner, circle_id, member_did),
         role = capacity_role(circle),
         :ok <- add_row(owner, circle_id, member_did, role, "link_approved", did),
         :ok <- set_join_status(owner, circle_id, member_did, "approved") do
      # Same as the previous backend: an approved member becomes the owner's contact.
      if did == owner, do: Contacts.ensure(me, member_did, "circle")

      notify(member_did, did, "JoinApproved", "You joined #{circle["name"]}", circle_id, member_did,
        pointer: pointer(circle, role, "active")
      )

      Publisher.circle_event(circle_id, "member_joined", %{member_did: member_did, role: role})
      get(owner, circle_id, member_did)
    else
      {:ok, _} -> {:error, :no_pending_request}
      {:error, :not_found} -> {:error, :no_pending_request}
      err -> err
    end
  end

  def deny(%{did: did}, circle_id, member_did) do
    with {:ok, %{owner: owner, circle: circle}} <- authorize(did, circle_id, "add_member"),
         {:ok, %{"join_status" => "pending"}} <- join_record(owner, circle_id, member_did),
         :ok <- set_join_status(owner, circle_id, member_did, "denied") do
      notify(member_did, did, "JoinDenied", "Your request to join #{circle["name"]} was declined", circle_id, member_did,
        pointer: pointer(circle, nil, "denied")
      )

      {:ok, %{"circle_id" => circle_id, "member_did" => member_did, "status" => "denied"}}
    else
      {:ok, _} -> {:error, :no_pending_request}
      {:error, :not_found} -> {:error, :no_pending_request}
      err -> err
    end
  end

  # ── direct add / remove / roles ──────────────────────────────────────

  @doc "Adds one of the caller's contacts straight into the circle (no approval)."
  def add(%{did: did}, circle_id, member_did) do
    with {:ok, %{owner: owner, circle: circle}} <- authorize(did, circle_id, "add_member"),
         {:ok, _contact} <- in_contacts(did, member_did),
         :ok <- not_active(owner, circle_id, member_did),
         role = capacity_role(circle),
         :ok <- add_row(owner, circle_id, member_did, role, "direct_add", did) do
      notify(member_did, did, "CircleAdded", "#{name(did)} added you to #{circle["name"]}", circle_id, member_did,
        pointer: pointer(circle, role, "active")
      )

      Publisher.circle_event(circle_id, "member_joined", %{member_did: member_did, role: role})
      get(owner, circle_id, member_did)
    end
  end

  def remove(%{did: did}, circle_id, target_did) do
    with {:ok, %{owner: owner, circle: circle, role: role}} <- context(did, circle_id),
         {:ok, target_role} <- role(owner, circle_id, target_did),
         :ok <- check(Permissions.can_remove?(role, target_role), :forbidden),
         :ok <- write_row(owner, circle_id, target_did, %{"status" => "removed"}),
         :ok <- Circles.bump(owner, circle_id, Circles.counter_for(target_role), -1) do
      notify(target_did, did, "CircleRemoved", "You were removed from #{circle["name"]}", circle_id, target_did,
        pointer: pointer(circle, target_role, "removed")
      )

      Publisher.circle_event(circle_id, "member_removed", %{member_did: target_did})
      {:ok, %{"circle_id" => circle_id, "member_did" => target_did, "status" => "removed"}}
    end
  end

  @doc "Mute = role 'restricted' (can read, cannot send)."
  def mute(%{did: did}, circle_id, target_did) do
    with {:ok, %{role: role, owner: owner}} <- authorize(did, circle_id, "remove_member"),
         {:ok, target_role} <- role(owner, circle_id, target_did),
         :ok <- check(Permissions.can_remove?(role, target_role), :forbidden) do
      change_role(did, circle_id, target_did, "restricted", "member_muted")
    end
  end

  def update_role(%{did: did}, circle_id, target_did, new_role) do
    with {:ok, _ctx} <- authorize(did, circle_id, "promote_demote_roles"),
         :ok <- check(Permissions.assignable?(new_role), :invalid_role) do
      change_role(did, circle_id, target_did, new_role, "role_changed")
    end
  end

  defp change_role(did, circle_id, target_did, new_role, event) do
    with {:ok, %{owner: owner, circle: circle}} <- context(did, circle_id),
         {:ok, old_role} <- role(owner, circle_id, target_did),
         :ok <- check(old_role != "owner", :cannot_change_owner),
         :ok <- write_row(owner, circle_id, target_did, %{"role" => new_role}) do
      if Circles.counter_for(old_role) != Circles.counter_for(new_role) do
        Circles.bump(owner, circle_id, Circles.counter_for(old_role), -1)
        Circles.bump(owner, circle_id, Circles.counter_for(new_role), 1)
      end

      notify(target_did, did, "RoleChanged", "Your role in #{circle["name"]} is now #{new_role}", circle_id, target_did,
        pointer: pointer(circle, new_role, "active")
      )

      Publisher.circle_event(circle_id, event, %{member_did: target_did, role: new_role})
      get(owner, circle_id, target_did)
    end
  end

  def leave(%{did: did}, circle_id) do
    with {:ok, %{owner: owner, circle: circle, role: role}} <- context(did, circle_id),
         :ok <- check(role != "owner", :owner_cannot_leave),
         :ok <- write_row(owner, circle_id, did, %{"status" => "left"}),
         :ok <- Circles.bump(owner, circle_id, Circles.counter_for(role), -1),
         :ok <- write_pointer(did, circle, role, "left") do
      notify(owner, did, "MemberLeft", "#{name(did)} left #{circle["name"]}", circle_id, did)
      Publisher.circle_event(circle_id, "member_left", %{member_did: did})
      {:ok, %{"circle_id" => circle_id, "member_did" => did, "status" => "left"}}
    end
  end

  # ── ownership transfer ───────────────────────────────────────────────

  @doc """
  Moves the circle to another active member. Because circle data lives
  in the owner's database, the circle, its roster and its pins are
  copied into the new owner's database; the old copies are marked
  "transferred" and every member's pointer is redirected.
  Join requests still pending at that moment must be sent again.
  """
  def transfer(%{did: did}, circle_id, new_owner) do
    with {:ok, %{owner: owner, circle: circle, role: "owner"}} <- context(did, circle_id),
         :ok <- check(new_owner != owner, :already_owner),
         {:ok, _role} <- role(owner, circle_id, new_owner),
         {:ok, members} <- list(owner, circle_id),
         {:ok, pins} <- Store.list(owner, "circle", "pins", prefix: circle_id <> "_", limit: 1000),
         new_circle = Map.merge(circle, %{"owner_did" => new_owner, "status" => "active"}),
         :ok <- Store.put(new_owner, "circle", "circles", circle_id, new_circle) do
      moved =
        for member <- members do
          member_did = member["member_did"]

          role =
            cond do
              member_did == new_owner -> "owner"
              member_did == owner -> "member"
              true -> member["role"]
            end

          write_row(new_owner, circle_id, member_did, Map.merge(member, %{"role" => role, "status" => "active"}))
          write_row(owner, circle_id, member_did, %{"status" => "transferred"})
          {member_did, role}
        end

      Enum.each(pins, &Store.put(new_owner, "circle", "pins", &1["id"], &1))
      Store.put(owner, "circle", "circles", circle_id, %{"status" => "transferred", "transferred_to" => new_owner})
      Directory.put_invite(circle["invite_code"], circle_id, new_owner)
      Circles.sync_index(new_circle)

      roles = Map.new(moved)
      write_pointer(did, new_circle, roles[did], "active")

      Notifications.send(
        for({member_did, _} <- moved, member_did != did, do: member_did),
        did,
        "OwnershipTransferred",
        "circle",
        "#{name(new_owner)} is now the owner of #{circle["name"]}",
        %{"circle_id" => circle_id, "subject_did" => new_owner},
        pointer: fn recipient -> pointer(new_circle, roles[recipient], "active") end
      )

      Publisher.circle_event(circle_id, "ownership_transferred", %{member_did: new_owner})
      Circles.get_for(did, circle_id)
    else
      {:ok, %{role: _}} -> {:error, :forbidden}
      err -> err
    end
  end

  # ── row / pointer writers (also used by Circles) ─────────────────────

  @doc "Creates or updates a roster row in the owner's database."
  def write_row(owner, circle_id, member_did, fields) do
    defaults = %{"circle_id" => circle_id, "member_did" => member_did, "owner_did" => owner}
    Store.put(owner, "circle", "members", row_id(circle_id, member_did), Map.merge(fields, defaults))
  end

  @doc "Writes `did`'s OWN membership pointer (the caller is `did`)."
  def write_pointer(did, circle, role, status),
    do: Store.put(did, "circle", "memberships", circle["circle_id"], pointer(circle, role, status))

  def pointer(circle, role, status) do
    %{
      "circle_id" => circle["circle_id"],
      "owner_did" => circle["owner_did"],
      "name" => circle["name"],
      "status" => status
    }
    |> then(fn p -> if role, do: Map.put(p, "role", role), else: p end)
  end

  # ── private ──────────────────────────────────────────────────────────

  defp add_row(owner, circle_id, member_did, role, join_method, invited_by) do
    with :ok <-
           write_row(owner, circle_id, member_did, %{
             "role" => role,
             "status" => "active",
             "join_method" => join_method,
             "invited_by" => invited_by,
             "joined_at" => System.os_time(:microsecond)
           }) do
      Circles.bump(owner, circle_id, Circles.counter_for(role), 1)
    end
  end

  # Once the circle is full, later joiners become "audience" (read-only)
  # and are counted separately, so they never use up member places.
  defp capacity_role(circle) do
    if (circle["member_count"] || 0) >= (circle["max_members"] || 256), do: "audience", else: "member"
  end

  defp join_record_id(circle_id, member_did), do: "join-" <> row_id(circle_id, member_did)

  defp join_record(owner, circle_id, member_did),
    do: Store.get(owner, "chat", "inbox", join_record_id(circle_id, member_did))

  defp set_join_status(owner, circle_id, member_did, status),
    do: Store.put(owner, "chat", "inbox", join_record_id(circle_id, member_did), %{"join_status" => status})

  defp put_join_record(owner, circle_id, member_did, fields) do
    item =
      Map.merge(fields, %{
        "msg_id" => Key.message_id(),
        "activity_type" => "JoinRequest",
        "category" => "circle",
        "actor_did" => member_did,
        "circle_id" => circle_id,
        "sent_at" => System.os_time(:microsecond)
      })

    Delivery.deliver([owner], item, thread: "join", record: join_record_id(circle_id, member_did), count: false)
  end

  defp in_contacts(did, member_did) do
    case Contacts.get(did, member_did) do
      {:ok, contact} -> {:ok, contact}
      _ -> {:error, :not_in_contacts}
    end
  end

  defp not_active(owner, circle_id, member_did) do
    case role(owner, circle_id, member_did) do
      {:ok, _} -> {:error, :already_a_member}
      _ -> :ok
    end
  end

  defp notify(recipient, actor, activity_type, text, circle_id, subject_did, opts \\ []) do
    if recipient != actor or opts != [] do
      Notifications.send([recipient], actor, activity_type, "circle", text,
        %{"circle_id" => circle_id, "subject_did" => subject_did}, opts)
    end

    :ok
  end

  defp join_result(circle_id, status, role), do: %{"circle_id" => circle_id, "status" => status, "role" => role}

  defp name(did), do: Directory.display_name(did)

  defp check(true, _reason), do: :ok
  defp check(false, reason), do: {:error, reason}
end
