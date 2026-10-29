defmodule Przma.Calendar.Access do
  @moduledoc """
  "May this person use this calendar, and how?" — answered in ONE place.

  A calendar lives in its OWNER's database. Every other user reaches it in
  one of three ways, checked in this order:

    1. owner            calendar's owner_did == caller          -> "owner"
    2. shared directly  shares row {cal}-u_{did_key} (active)    -> "viewer" | "editor"
    3. shared to circle shares row {cal}-c_{circle_id} (active)
                        AND the caller is an active member of
                        that circle (Przma.Circle.Members)       -> "viewer" | "editor"

  For an ordinary personal calendar only step 1 runs — circles are only
  involved when the owner chose to share the calendar with a circle.

  Finding the owner: the system table calendar/private/index maps
  calendar_id -> owner_did, so a client only ever sends a calendar_id.
  """

  alias Przma.Calendar.Ids
  alias Przma.Circle.Members
  alias Przma.Social.Store

  @rank %{"viewer" => 1, "editor" => 2, "owner" => 3}

  @doc "{:ok, %{owner: did, calendar: map, role: role}} or {:error, :not_found | :forbidden}."
  def resolve(did, calendar_id) do
    with true <- Ids.valid?(calendar_id),
         {:ok, owner} <- owner_of(calendar_id),
         {:ok, %{"status" => "active"} = calendar} <- Store.get(owner, "calendar", "calendars", calendar_id),
         {:ok, role} <- role(did, owner, calendar_id) do
      {:ok, %{owner: owner, calendar: calendar, role: role}}
    else
      false -> {:error, :not_found}
      {:ok, _archived} -> {:error, :not_found}
      {:error, :forbidden} -> {:error, :forbidden}
      {:error, _} -> {:error, :not_found}
    end
  end

  @doc "resolve/2, then require editor or owner."
  def resolve_edit(did, calendar_id) do
    with {:ok, ctx} <- resolve(did, calendar_id) do
      if can_edit?(ctx.role), do: {:ok, ctx}, else: {:error, :forbidden}
    end
  end

  @doc "resolve/2, then require the owner (sharing, renaming, archiving)."
  def resolve_owner(did, calendar_id) do
    with {:ok, ctx} <- resolve(did, calendar_id) do
      if ctx.role == "owner", do: {:ok, ctx}, else: {:error, :forbidden}
    end
  end

  def can_edit?(role), do: role in ~w(owner editor)

  @doc "Owner DID of a calendar from the system index."
  def owner_of(calendar_id) do
    case Store.get(Ids.system_did(), "calendar", "index", calendar_id) do
      {:ok, %{"owner_did" => owner, "status" => "active"}} -> {:ok, owner}
      _ -> {:error, :not_found}
    end
  end

  # ── role ─────────────────────────────────────────────────────────────

  defp role(did, did, _calendar_id), do: {:ok, "owner"}

  defp role(did, owner, calendar_id) do
    direct =
      case Store.get(owner, "calendar", "shares", Ids.share_user_row(calendar_id, did)) do
        {:ok, %{"status" => "active", "role" => role}} -> [role]
        _ -> []
      end

    roles = direct ++ circle_roles(did, owner, calendar_id)

    case Enum.max_by(roles, &Map.get(@rank, &1, 0), fn -> nil end) do
      nil -> {:error, :forbidden}
      role -> {:ok, role}
    end
  end

  # Circle shares: one row per circle. Muted ("restricted") and "audience"
  # circle members can read but never edit, whatever the share says.
  defp circle_roles(did, owner, calendar_id) do
    case Store.list(owner, "calendar", "shares", prefix: Ids.share_circle_prefix(calendar_id), limit: 1000) do
      {:ok, rows} ->
        for %{"status" => "active", "target" => circle_id, "role" => share_role} <- rows,
            {:ok, %{role: circle_role}} <- [Members.context(did, circle_id)] do
          if circle_role in ~w(owner admin member), do: share_role, else: "viewer"
        end

      _ ->
        []
    end
  end
end
