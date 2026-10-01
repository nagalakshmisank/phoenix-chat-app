defmodule Przma.Beacon.Activity do
  @moduledoc """
  Read side of Beacon CMS "Users & Activity".

  Every number and row on the admin page comes from a function here —
  the LiveView never writes SQL itself. Data is written by the collector
  (Przma.Beacon.UserActivityCollector); this module only reads it.

  Times are converted to the dashboard time zone by Postgres
  (config :przma, :beacon, timezone: "Asia/Kolkata").
  """
  import Ecto.Query

  alias Przma.Beacon.Repo
  alias Przma.Beacon.{PrzmaUser, UserEvent}

  @active_minutes 15

  @event_types ~w(signed_in registration_completed profile_created profile_updated auth_failed)

  def event_types, do: @event_types
  def active_minutes, do: @active_minutes

  def timezone, do: Application.get_env(:przma, :beacon, [])[:timezone] || "Asia/Kolkata"

  @doc "Numbers for the tiles at the top of the page."
  def stats do
    tz = timezone()
    active_since = DateTime.add(DateTime.utc_now(), -@active_minutes * 60, :second)

    users =
      from(u in PrzmaUser,
        select: %{
          total_users: count(u.did),
          active_now: filter(count(u.did), u.last_seen_at >= ^active_since),
          new_today:
            filter(
              count(u.did),
              u.first_seen_at >= fragment("date_trunc('day', now() AT TIME ZONE ?) AT TIME ZONE ?", ^tz, ^tz)
            )
        }
      )
      |> Repo.one()

    events =
      from(e in UserEvent,
        where: e.occurred_at >= fragment("date_trunc('day', now() AT TIME ZONE ?) AT TIME ZONE ?", ^tz, ^tz),
        select: %{
          sign_ins_today: filter(count(e.id), e.event_type == "signed_in"),
          failed_auth_today: filter(count(e.id), e.event_type == "auth_failed")
        }
      )
      |> Repo.one()

    Map.merge(users, events)
  end

  @doc "Users, most recently active first. `search` matches username, name or DID."
  def list_users(search \\ "", limit \\ 50) do
    tz = timezone()

    PrzmaUser
    |> search_users(search)
    |> order_by([u], desc: u.last_seen_at)
    |> limit(^limit)
    |> select([u], %{
      did: u.did,
      username: u.username,
      display_name: u.display_name,
      tier: u.tier,
      request_count: u.request_count,
      last_seen_at: u.last_seen_at,
      last_seen_local: fragment("? AT TIME ZONE ?", u.last_seen_at, ^tz)
    })
    |> Repo.all()
  end

  defp search_users(query, search) when search in [nil, ""], do: query

  defp search_users(query, search) do
    term = "%" <> String.replace(search, ~r/[\\%_]/, "\\\\\\0") <> "%"

    where(
      query,
      [u],
      ilike(u.username, ^term) or ilike(u.display_name, ^term) or ilike(u.did, ^term)
    )
  end

  @doc "One user with times in the dashboard time zone, or nil."
  def get_user(did) do
    tz = timezone()

    from(u in PrzmaUser,
      where: u.did == ^did,
      select: %{
        did: u.did,
        username: u.username,
        display_name: u.display_name,
        email: u.email,
        tier: u.tier,
        request_count: u.request_count,
        last_ip: u.last_ip,
        last_user_agent: u.last_user_agent,
        last_seen_at: u.last_seen_at,
        first_seen_local: fragment("? AT TIME ZONE ?", u.first_seen_at, ^tz),
        last_seen_local: fragment("? AT TIME ZONE ?", u.last_seen_at, ^tz)
      }
    )
    |> Repo.one()
  end

  @doc "Latest events — for one user (`did`) or everyone (nil), optionally one type."
  def events(opts \\ []) do
    tz = timezone()
    limit = Keyword.get(opts, :limit, 40)

    UserEvent
    |> filter_did(opts[:did])
    |> filter_type(opts[:type])
    |> order_by([e], desc: e.occurred_at, desc: e.id)
    |> limit(^limit)
    |> select([e], %{
      id: e.id,
      did: e.did,
      username: e.username,
      event_type: e.event_type,
      details: e.details,
      ip: e.ip,
      at_local: fragment("? AT TIME ZONE ?", e.occurred_at, ^tz)
    })
    |> Repo.all()
  end

  defp filter_did(query, nil), do: query
  defp filter_did(query, did), do: where(query, [e], e.did == ^did)

  defp filter_type(query, type) when type in @event_types, do: where(query, [e], e.event_type == ^type)
  defp filter_type(query, _type), do: query
end
