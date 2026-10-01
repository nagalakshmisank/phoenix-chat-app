defmodule PRZMAWeb.Beacon.Pages.UserActivityLive do
  @moduledoc """
  Beacon CMS admin page: Users & Activity.

  Mounted inside Beacon LiveAdmin with the router option
  `additional_pages: [{"/users", PRZMAWeb.Beacon.Pages.UserActivityLive, :index}]`
  so it appears in the LiveAdmin menu at /admin/<site>/users.

  URL parameters (all optional, kept in the URL so links can be shared):
    ?q=mani            search users
    ?did=did:przma:x   open one user's timeline
    ?type=auth_failed  filter the activity feed

  Refreshes itself every 5 s while open. Reads only via Przma.Beacon.Activity.
  """
  use Beacon.LiveAdmin.PageBuilder

  alias Przma.Beacon.Activity

  @refresh_ms 5_000

  @impl true
  def menu_link(_prefix, :index), do: {:root, "Users & Activity"}
  def menu_link(_prefix, _action), do: :skip

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: :timer.send_interval(@refresh_ms, :beacon_refresh)
    {:ok, assign(socket, q: "", did: nil, type: nil)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket =
      assign(socket,
        q: params["q"] || "",
        did: blank_to_nil(params["did"]),
        type: if(params["type"] in Activity.event_types(), do: params["type"])
      )

    {:noreply, load(socket)}
  end

  @impl true
  def handle_event("ua-search", %{"q" => q}, socket) do
    {:noreply, push_patch(socket, to: page_path(socket, socket.assigns.beacon_page.site, %{q: q, did: socket.assigns.did, type: socket.assigns.type}))}
  end

  @impl true
  def handle_info(:beacon_refresh, socket), do: {:noreply, load(socket)}
  def handle_info(_msg, socket), do: {:noreply, socket}

  defp load(socket) do
    %{q: q, did: did, type: type} = socket.assigns

    assign(socket,
      stats: Activity.stats(),
      users: Activity.list_users(q),
      selected: did && Activity.get_user(did),
      events: Activity.events(did: did, type: type, limit: if(did, do: 60, else: 25)),
      now: DateTime.utc_now()
    )
  end

  # ── template ──────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <style>
      .ua { --ink:#111827; --ink2:#4b5563; --muted:#6b7280; --line:#e5e7eb; --card:#fff; --bg:#f9fafb;
            --blue:#2a78d6; --green:#0b7a0b; --red:#c62828; --amber:#b45309; color: var(--ink); font-size:14px; }
      .ua-tiles { display:grid; grid-template-columns:repeat(auto-fit,minmax(150px,1fr)); gap:12px; margin:16px 0; }
      .ua-card { background:var(--card); border:1px solid var(--line); border-radius:10px; padding:14px 16px; min-width:0; }
      .ua-tile .l { color:var(--ink2); font-size:12px; } .ua-tile .v { font-size:26px; font-weight:700; margin-top:2px; }
      .ua-tile .n { color:var(--muted); font-size:12px; }
      .ua-grid { display:grid; grid-template-columns: 3fr 2fr; gap:16px; }
      @media (max-width: 1100px) { .ua-grid { grid-template-columns: 1fr; } }
      .ua h3 { font-size:15px; font-weight:700; margin:0 0 10px; display:flex; justify-content:space-between; align-items:center; }
      .ua-search { width:100%; padding:8px 10px; border:1px solid var(--line); border-radius:8px; margin-bottom:10px; font-size:14px; }
      .ua table { width:100%; border-collapse:collapse; }
      .ua th { text-align:left; font-size:11px; text-transform:uppercase; letter-spacing:.04em; color:var(--muted);
               padding:6px 8px; border-bottom:1px solid var(--line); }
      .ua td { padding:8px; border-bottom:1px solid var(--line); vertical-align:top; }
      .ua td.num, .ua th.num { text-align:right; font-variant-numeric:tabular-nums; }
      .ua tr.row { cursor:pointer; } .ua tr.row:hover { background:var(--bg); } .ua tr.sel { background:#eef5fd; }
      .ua .name { font-weight:600; } .ua .sub { color:var(--muted); font-size:12px; }
      .ua code { font:12px ui-monospace, SFMono-Regular, Menlo, monospace; }
      .ua-dot { display:inline-flex; align-items:center; gap:6px; font-size:12px; color:var(--ink2); white-space:nowrap; }
      .ua-dot i { width:8px; height:8px; border-radius:50%; background:#d1d5db; display:inline-block; }
      .ua-dot.on i { background:var(--green); } .ua-dot.on { color:var(--green); font-weight:600; }
      .ua-chips { display:flex; flex-wrap:wrap; gap:6px; margin-bottom:10px; }
      .ua-chips a { padding:3px 10px; border:1px solid var(--line); border-radius:999px; font-size:12px; color:var(--ink2); text-decoration:none; }
      .ua-chips a.on { background:var(--blue); border-color:var(--blue); color:#fff; }
      .ua-ev { display:grid; grid-template-columns: 22px 1fr; gap:8px; padding:8px 0; border-bottom:1px solid var(--line); }
      .ua-ev .ic { width:22px; height:22px; border-radius:50%; display:grid; place-items:center; font-size:12px; color:#fff; }
      .ua-ev .t { color:var(--muted); font-size:12px; }
      .ic.signed_in { background:var(--blue); } .ic.registration_completed { background:var(--green); }
      .ic.profile_created, .ic.profile_updated { background:#6d28d9; } .ic.auth_failed { background:var(--red); }
      .ua-kv { display:grid; grid-template-columns: 110px 1fr; gap:4px 10px; font-size:13px; margin-bottom:12px; }
      .ua-kv dt { color:var(--muted); } .ua-kv dd { margin:0; word-break:break-all; }
      .ua-empty { color:var(--ink2); padding:24px; text-align:center; }
      .ua-close { font-size:12px; font-weight:400; color:var(--blue); text-decoration:none; }
      .ua-warn { color:var(--red); font-size:11px; font-weight:600; }
    </style>

    <div class="ua">
      <.header>
        Users &amp; Activity
        <:subtitle>Who uses PRZMA and what they did · times in <%= Activity.timezone() %> · live</:subtitle>
      </.header>

      <section class="ua-tiles">
        <div class="ua-card ua-tile">
          <div class="l">Total users</div>
          <div class="v"><%= @stats.total_users %></div>
          <div class="n">seen by przma_backend</div>
        </div>
        <div class="ua-card ua-tile">
          <div class="l">Active now</div>
          <div class="v"><%= @stats.active_now %></div>
          <div class="n">last <%= Activity.active_minutes() %> minutes</div>
        </div>
        <div class="ua-card ua-tile">
          <div class="l">New today</div>
          <div class="v"><%= @stats.new_today %></div>
          <div class="n">first seen today</div>
        </div>
        <div class="ua-card ua-tile">
          <div class="l">Sign-ins today</div>
          <div class="v"><%= @stats.sign_ins_today %></div>
          <div class="n">new Keycloak sessions</div>
        </div>
        <div class="ua-card ua-tile">
          <div class="l">Failed auth today</div>
          <div class="v"><%= @stats.failed_auth_today %></div>
          <div class="n">expired / invalid tokens</div>
        </div>
      </section>

      <div class="ua-grid">
        <section class="ua-card">
          <h3>Users <span class="sub"><%= length(@users) %> shown</span></h3>
          <form phx-change="ua-search" phx-submit="ua-search">
            <input class="ua-search" type="search" name="q" value={@q} phx-debounce="300"
                   placeholder="Search username, name or DID" autocomplete="off" />
          </form>

          <div :if={@users == []} class="ua-empty">
            No users yet. Call any przma_backend API endpoint with a Keycloak token and the user appears here within a few seconds.
          </div>

          <table :if={@users != []}>
            <thead>
              <tr><th>User</th><th>Tier</th><th>Last seen</th><th class="num">Requests</th><th>Status</th></tr>
            </thead>
            <tbody>
              <tr :for={u <- @users} class={["row", u.did == @did && "sel"]}
                  phx-click={JS.patch(page_path(@socket, @beacon_page.site, %{q: @q, did: u.did, type: @type}))}>
                <td>
                  <div class="name"><%= u.display_name || u.username %></div>
                  <div class="sub"><code><%= u.did %></code></div>
                </td>
                <td><%= u.tier || "—" %></td>
                <td>
                  <%= ago(u.last_seen_at, @now) %>
                  <div class="sub"><%= fmt(u.last_seen_local) %></div>
                </td>
                <td class="num"><%= u.request_count %></td>
                <td>
                  <span class={["ua-dot", active?(u.last_seen_at, @now) && "on"]}>
                    <i></i><%= if active?(u.last_seen_at, @now), do: "active", else: "idle" %>
                  </span>
                </td>
              </tr>
            </tbody>
          </table>
        </section>

        <section class="ua-card">
          <%= if @selected do %>
            <h3>
              <%= @selected.display_name || @selected.username %>
              <.link patch={page_path(@socket, @beacon_page.site, %{q: @q, type: @type})} class="ua-close">✕ close</.link>
            </h3>
            <dl class="ua-kv">
              <dt>Username</dt><dd><%= @selected.username %></dd>
              <dt>DID</dt><dd><code><%= @selected.did %></code></dd>
              <dt :if={@selected.email}>Email</dt><dd :if={@selected.email}><%= @selected.email %></dd>
              <dt>Tier</dt><dd><%= @selected.tier || "—" %></dd>
              <dt>First seen</dt><dd><%= fmt(@selected.first_seen_local) %></dd>
              <dt>Last seen</dt><dd><%= fmt(@selected.last_seen_local) %> (<%= ago(@selected.last_seen_at, @now) %>)</dd>
              <dt>Requests</dt><dd><%= @selected.request_count %></dd>
              <dt>Last IP</dt><dd><%= @selected.last_ip || "—" %></dd>
            </dl>
            <h3>Timeline</h3>
          <% else %>
            <h3>Recent activity <span class="sub">all users</span></h3>
          <% end %>

          <div class="ua-chips">
            <.link patch={page_path(@socket, @beacon_page.site, %{q: @q, did: @did})} class={is_nil(@type) && "on"}>All</.link>
            <.link :for={t <- Activity.event_types()} patch={page_path(@socket, @beacon_page.site, %{q: @q, did: @did, type: t})}
                   class={@type == t && "on"}><%= label(t) %></.link>
          </div>

          <div :if={@events == []} class="ua-empty">No activity recorded yet.</div>

          <div :for={e <- @events} class="ua-ev">
            <span class={["ic", e.event_type]}><%= icon(e.event_type) %></span>
            <div>
              <div>
                <.link :if={is_nil(@did) && e.did} patch={page_path(@socket, @beacon_page.site, %{q: @q, did: e.did, type: @type})}>
                  <b><%= e.username || e.did %></b>
                </.link>
                <b :if={is_nil(@did) && is_nil(e.did)}>Unknown token</b>
                <%= describe(e) %>
                <span :if={e.details["verified"] == false} class="ua-warn">unverified</span>
              </div>
              <div class="t"><%= fmt(e.at_local) %><%= if e.ip, do: " · #{e.ip}" %></div>
            </div>
          </div>
        </section>
      </div>
    </div>
    """
  end

  # ── helpers ───────────────────────────────────────────────────────────

  # site is passed in explicitly: inside a template @socket has no assigns.
  defp page_path(socket, site, params) do
    params = params |> Enum.reject(fn {_k, v} -> v in [nil, ""] end) |> Map.new()
    beacon_live_admin_path(socket, site, "/users", params)
  end

  defp label("signed_in"), do: "Signed in"
  defp label("registration_completed"), do: "Registration"
  defp label("profile_created"), do: "Profile created"
  defp label("profile_updated"), do: "Profile updated"
  defp label("auth_failed"), do: "Failed auth"
  defp label(other), do: other

  defp icon("signed_in"), do: "→"
  defp icon("registration_completed"), do: "★"
  defp icon("profile_created"), do: "+"
  defp icon("profile_updated"), do: "✎"
  defp icon("auth_failed"), do: "!"
  defp icon(_), do: "•"

  defp describe(%{event_type: "signed_in"}), do: " signed in"
  defp describe(%{event_type: "registration_completed"}), do: " completed registration"
  defp describe(%{event_type: "profile_created"}), do: " created their profile"

  defp describe(%{event_type: "profile_updated", details: %{"fields" => [_ | _] = fields}}),
    do: " updated profile (#{Enum.join(fields, ", ")})"

  defp describe(%{event_type: "profile_updated"}), do: " updated profile"

  defp describe(%{event_type: "auth_failed", details: details}) do
    reason = if details["reason"] == "token_expired", do: "expired token", else: "invalid token"
    " was rejected: #{reason}" <> if(details["path"], do: " on #{details["path"]}", else: "")
  end

  defp describe(%{event_type: type}), do: " #{type}"

  defp active?(nil, _now), do: false
  defp active?(at, now), do: DateTime.diff(now, at) <= Activity.active_minutes() * 60

  defp ago(nil, _now), do: "—"

  defp ago(at, now) do
    s = max(DateTime.diff(now, at), 0)

    cond do
      s < 60 -> "just now"
      s < 3_600 -> "#{div(s, 60)} min ago"
      s < 86_400 -> "#{div(s, 3_600)} h ago"
      true -> "#{div(s, 86_400)} days ago"
    end
  end

  defp fmt(nil), do: "—"
  defp fmt(%NaiveDateTime{} = t), do: Calendar.strftime(t, "%d %b %Y, %H:%M:%S")

  defp blank_to_nil(v) when v in [nil, ""], do: nil
  defp blank_to_nil(v), do: v
end
