defmodule Przma.Calendar.Calendars do
  @moduledoc """
  Calendars: create, list, update, archive — and the default personal
  calendar every user gets at registration.

      {owner}/calendar/private/calendars.lance     one row per calendar (id = calendar_id)
      {system}/calendar/private/index.lance        calendar_id -> owner_did (see Access)

  Field names avoid the ones LanceDocAdapter reserves (id, type, did, gid,
  created_at, updated_at, ...), which is why the kind is "calendar_type".
  """

  alias Przma.Calendar.{Access, Ids, Live}
  alias Przma.Social.Store

  @types ~w(personal family friends business school)

  def types, do: @types

  @doc "Creates a calendar owned by the caller."
  def create(%{did: did}, attrs), do: do_create(did, Ids.calendar_id(), attrs, false)

  @doc """
  Makes sure the user has a default personal calendar. Its id is derived
  from the DID, so calling this at every registration / first use is safe.
  """
  def ensure_default(did) do
    id = Ids.default_calendar_id(did)

    case Store.get(did, "calendar", "calendars", id) do
      {:ok, calendar} -> {:ok, Map.put(calendar, "my_role", "owner")}
      {:error, :not_found} -> do_create(did, id, %{name: "My Calendar", calendar_type: "personal"}, true)
      err -> err
    end
  end

  @doc "One calendar the caller can see, with my_role."
  def get_for(did, calendar_id) do
    with {:ok, %{calendar: calendar, role: role}} <- Access.resolve(did, calendar_id) do
      {:ok, Map.put(calendar, "my_role", role)}
    end
  end

  @doc """
  Every calendar the caller can see: own calendars, calendars shared with
  them directly (subscriptions), and calendars shared with their circles.
  """
  def list_mine(did) do
    ensure_default(did)

    own =
      case Store.list(did, "calendar", "calendars", limit: 1000) do
        {:ok, rows} -> for %{"status" => "active"} = c <- rows, do: Map.put(c, "my_role", "owner")
        _ -> []
      end

    shared = (subscribed_ids(did) ++ circle_calendar_ids(did)) |> Enum.uniq()

    others =
      for id <- shared,
          not Enum.any?(own, &(&1["calendar_id"] == id)),
          {:ok, calendar} <- [get_for(did, id)],
          do: calendar

    {:ok, own ++ others}
  end

  @doc "Owner only: name, color, timezone, region."
  def update(%{did: did}, calendar_id, attrs) do
    with {:ok, %{owner: owner, calendar: calendar}} <- Access.resolve_owner(did, calendar_id) do
      changes =
        %{}
        |> put_if("name", attrs[:name] && clean_name(attrs[:name]))
        |> put_if("color", attrs[:color])
        |> put_if("timezone", attrs[:timezone])
        |> put_if("region", attrs[:region])

      with :ok <- Store.put(owner, "calendar", "calendars", calendar_id, changes) do
        Live.publish(calendar_id, "calendar_updated", did)
        {:ok, calendar |> Map.merge(changes) |> Map.put("my_role", "owner")}
      end
    end
  end

  @doc "Owner only. The default calendar cannot be archived. Rows are kept (no deletes in the doc store)."
  def archive(%{did: did}, calendar_id) do
    with {:ok, %{owner: owner, calendar: calendar}} <- Access.resolve_owner(did, calendar_id),
         :ok <- if(calendar["is_default"], do: {:error, :cannot_archive_default_calendar}, else: :ok),
         :ok <- Store.put(owner, "calendar", "calendars", calendar_id, %{"status" => "archived"}),
         :ok <- system_put("index", calendar_id, %{"status" => "archived"}) do
      {:ok, true}
    end
  end

  # ── private ──────────────────────────────────────────────────────────

  defp do_create(did, id, attrs, default?) do
    type = to_string(attrs[:calendar_type] || "personal")

    with :ok <- if(type in @types, do: :ok, else: {:error, :invalid_calendar_type}),
         name when is_binary(name) <- clean_name(attrs[:name] || "Calendar") || {:error, :invalid_name} do
      calendar = %{
        "calendar_id" => id,
        "owner_did" => did,
        "name" => name,
        "calendar_type" => type,
        "color" => attrs[:color] || default_color(type),
        "timezone" => attrs[:timezone] || cfg(:default_timezone, "Asia/Kolkata"),
        "region" => attrs[:region] || cfg(:default_region, "IN_TN"),
        "is_default" => default?,
        "status" => "active",
        "created_by" => did
      }

      with :ok <- Store.put(did, "calendar", "calendars", id, calendar),
           :ok <- system_put("index", id, %{"calendar_id" => id, "owner_did" => did, "status" => "active"}) do
        {:ok, Map.put(calendar, "my_role", "owner")}
      end
    end
  end

  defp subscribed_ids(did) do
    case Store.list(did, "calendar", "subscriptions", limit: 1000) do
      {:ok, rows} -> for %{"status" => "active", "calendar_id" => id} <- rows, do: id
      _ -> []
    end
  end

  # Calendars shared with any circle the caller is an active member of.
  defp circle_calendar_ids(did) do
    circle_ids =
      case Store.list(did, "circle", "memberships", limit: 1000) do
        {:ok, rows} -> for %{"status" => "active"} = row <- rows, do: row["circle_id"] || row["id"]
        _ -> []
      end

    Enum.flat_map(circle_ids, fn circle_id ->
      case Store.list(Ids.system_did(), "calendar", "circle_calendars",
             prefix: Ids.circle_calendar_prefix(circle_id),
             limit: 1000
           ) do
        {:ok, rows} -> for %{"status" => "active", "calendar_id" => id} <- rows, do: id
        _ -> []
      end
    end)
  end

  def system_put(table, id, fields, opts \\ []),
    do: Store.put(Ids.system_did(), "calendar", table, id, fields, Keyword.merge([gid: Ids.system_gid()], opts))

  defp clean_name(name) when is_binary(name) do
    case name |> String.trim() |> String.slice(0, 80) do
      "" -> nil
      n -> n
    end
  end

  defp clean_name(_), do: nil

  defp default_color("family"), do: "#2E7D32"
  defp default_color("friends"), do: "#F57C00"
  defp default_color("business"), do: "#1565C0"
  defp default_color("school"), do: "#6A1B9A"
  defp default_color(_), do: "#00838F"

  defp put_if(map, _key, nil), do: map
  defp put_if(map, _key, false), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)

  defp cfg(key, default), do: :przma |> Application.get_env(:calendar, []) |> Keyword.get(key, default)
end
