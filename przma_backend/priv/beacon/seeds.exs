# Beacon CMS — demo data for the Users & Activity page.
#
#   BEACON_ENABLED=true mix run priv/beacon/seeds.exs
#
# Inserts 8 demo users (DIDs ending in "-demo") and ~100 events over the
# last 7 days. Safe to run again: it deletes the previous demo rows first.
# Remove demo data at any time with:
#   DELETE FROM przma_user_events WHERE did LIKE 'did:przma:%-demo';
#   DELETE FROM przma_users       WHERE did LIKE 'did:przma:%-demo';

import Ecto.Query
alias Przma.Beacon.Repo
alias Przma.Beacon.{PrzmaUser, UserEvent}

Repo.delete_all(from e in UserEvent, where: like(e.did, "did:przma:%-demo"))
Repo.delete_all(from u in PrzmaUser, where: like(u.did, "did:przma:%-demo"))

now = DateTime.utc_now()
ago = fn seconds -> DateTime.add(now, -seconds, :second) end

people = [
  {"mani", "Mani K", 2, 120},
  {"satish", "Satish R", 1, 600},
  {"anjali", "Anjali S", 3, 2_400},
  {"raj", "Raj P", 1, 9_000},
  {"keerthi", "Keerthi M", 2, 30_000},
  {"guna", "Guna", 1, 90_000},
  {"teju", "Teju", 1, 200_000},
  {"newbie", nil, 1, 300}
]

users =
  for {name, display, tier, last_seen_ago} <- people do
    first = if name == "newbie", do: ago.(900), else: ago.(last_seen_ago + 86_400 * Enum.random(3..30))

    %{
      did: "did:przma:#{name}-demo",
      username: "#{name}-demo",
      display_name: display,
      email: nil,
      tier: tier,
      first_seen_at: first,
      last_seen_at: ago.(last_seen_ago),
      request_count: Enum.random(20..900),
      last_ip: "10.0.0.#{Enum.random(2..60)}",
      last_user_agent: "Mozilla/5.0 (demo)",
      updated_at: now
    }
  end

Repo.insert_all(PrzmaUser, users)

event = fn u, type, at, details, sid ->
  %{
    occurred_at: at,
    did: u.did,
    username: u.username,
    event_type: type,
    session_id: sid,
    details: details,
    ip: u.last_ip,
    user_agent: u.last_user_agent
  }
end

events =
  Enum.flat_map(users, fn u ->
    span = DateTime.diff(u.last_seen_at, u.first_seen_at)
    registration = [event.(u, "registration_completed", u.first_seen_at, %{"tier" => u.tier}, nil),
                    event.(u, "profile_created", DateTime.add(u.first_seen_at, 40), %{"fields" => ["nickname", "display_name"]}, nil)]

    sessions =
      for i <- 1..Enum.random(4..14) do
        at = DateTime.add(u.first_seen_at, div(span * i, 15))
        sid = Ecto.UUID.generate()

        [event.(u, "signed_in", at, %{"tier" => u.tier}, sid)] ++
          if(rem(i, 3) == 0,
            do: [event.(u, "profile_updated", DateTime.add(at, 120), %{"fields" => Enum.take_random(["bio", "display_name", "avatar_cid", "nickname"], 2)}, nil)],
            else: []
          ) ++
          if(rem(i, 5) == 0,
            do: [event.(u, "auth_failed", DateTime.add(at, 4_000), %{"reason" => "token_expired", "verified" => false, "path" => "/api/v1/profile"}, nil)],
            else: []
          )
      end

    latest = event.(u, "signed_in", DateTime.add(u.last_seen_at, -60), %{"tier" => u.tier}, Ecto.UUID.generate())
    registration ++ List.flatten(sessions) ++ [latest]
  end)

Repo.insert_all(UserEvent, events)
IO.puts("Beacon demo: #{length(users)} users, #{length(events)} events inserted")
