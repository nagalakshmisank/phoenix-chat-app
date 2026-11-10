defmodule Przma.Authz.Endpoints do
  @moduledoc """
  Endpoint registry: which scope and feature every API needs.

  The central table `przma_authz.api_endpoints` is the source of truth.
  The list below holds the DEFAULTS for every API in this codebase;
  sync/0 runs at startup and inserts any that are missing
  (ON CONFLICT DO NOTHING), so an admin can later change a row in
  Supabase Studio — scope, feature, rate limit, or active = false to
  switch an API off — and the change is picked up within 60 s, without
  a deploy.

  Rule for developers: every new GraphQL field or REST route MUST be
  added here. A call to an API that has no row is refused with
  `endpoint_not_registered` (fail closed).

  Names: GraphQL fields use their camelCase name ("createEvent");
  REST routes use "METHOD /path" with the router's path pattern
  ("GET /api/v1/profile").
  """

  require Logger
  alias Przma.Authz.{Cache, Db}

  # {kind, name, scope, feature, rate_limit_per_min}
  @q "graphql_query"
  @m "graphql_mutation"
  @r "rest"

  @defaults [
    # ── registration & profile ─────────────────────────────────────────
    {@m, "completeRegistration", "auth:register", nil, 10},
    {@q, "profile", "profile:rw", nil, 120},
    {@m, "createProfile", "profile:rw", nil, 30},
    {@m, "updateProfile", "profile:rw", nil, 30},
    # ── own access, sessions, access keys (new) ────────────────────────
    {@q, "myAccess", "profile:rw", nil, 120},
    {@q, "mySessions", "profile:rw", nil, 60},
    {@m, "revokeMySession", "profile:rw", nil, 30},
    {@q, "myAccessKeys", "keys:manage", "keys.access_keys", 60},
    {@m, "createAccessKey", "keys:manage", "keys.access_keys", 10},
    {@m, "revokeAccessKey", "keys:manage", "keys.access_keys", 30},
    # ── platform admin (new) ───────────────────────────────────────────
    {@q, "adminAccount", "admin:*", nil, 120},
    {@q, "adminSecurityEvents", "admin:*", nil, 120},
    {@m, "adminSetPlan", "admin:*", nil, 60},
    {@m, "adminSetAccountStatus", "admin:*", nil, 60},
    {@m, "adminRevokeSessions", "admin:*", nil, 60},
    {@m, "adminGrantFeature", "admin:*", nil, 60},
    {@m, "adminMigrateStorage", "admin:*", nil, 10},
    # ── files ──────────────────────────────────────────────────────────
    {@q, "files", "files:rw", nil, 120},
    {@q, "commonsCasStatus", "files:rw", nil, 30},
    {@q, "casMeta", "files:rw", nil, 120},
    {@q, "blobDownloadUrl", "files:rw", nil, 120},
    {@m, "uploadFile", "files:rw", "files.upload", 30},
    {@m, "uploadBlob", "files:rw", "files.upload", 30},
    {@m, "syncFileRecord", "files:rw", "files.upload", 60},
    # ── chat ───────────────────────────────────────────────────────────
    {@q, "threads", "social:rw", "social.chat", 120},
    {@q, "unreadCount", "social:rw", "social.chat", 240},
    {@q, "conversation", "social:rw", "social.chat", 240},
    {@q, "inbox", "social:rw", "social.chat", 240},
    {@q, "outbox", "social:rw", "social.chat", 120},
    {@q, "message", "social:rw", "social.chat", 240},
    {@q, "messageBlobUrl", "social:rw", "social.chat", 120},
    {@m, "sendMessage", "social:rw", "social.chat", 60},
    {@m, "deleteMessage", "social:rw", "social.chat", 60},
    {@m, "saveMessageToVault", "social:rw", "social.chat", 30},
    {@m, "markThreadRead", "social:rw", "social.chat", 120},
    {@m, "markAllRead", "social:rw", "social.chat", 60},
    {@m, "muteThread", "social:rw", "social.chat", 60},
    {@m, "unmuteThread", "social:rw", "social.chat", 60},
    # ── circles ────────────────────────────────────────────────────────
    {@q, "myCircles", "social:rw", "social.chat", 120},
    {@q, "circle", "social:rw", "social.chat", 120},
    {@q, "circleMembers", "social:rw", "social.chat", 120},
    {@q, "pendingMembers", "social:rw", "social.chat", 120},
    {@q, "circleMessages", "social:rw", "social.chat", 240},
    {@q, "circlePins", "social:rw", "social.chat", 120},
    {@q, "discoverCircles", "social:rw", "social.chat", 60},
    {@m, "createCircle", "social:rw", "social.chat", 20},
    {@m, "updateCircle", "social:rw", "social.chat", 30},
    {@m, "deleteCircle", "social:rw", "social.chat", 20},
    {@m, "joinCircle", "social:rw", "social.chat", 30},
    {@m, "leaveCircle", "social:rw", "social.chat", 30},
    {@m, "approveMember", "social:rw", "social.chat", 60},
    {@m, "denyMember", "social:rw", "social.chat", 60},
    {@m, "addMember", "social:rw", "social.chat", 60},
    {@m, "removeMember", "social:rw", "social.chat", 60},
    {@m, "muteMember", "social:rw", "social.chat", 60},
    {@m, "updateMemberRole", "social:rw", "social.chat", 60},
    {@m, "transferOwnership", "social:rw", "social.chat", 10},
    {@m, "sendCircleMessage", "social:rw", "social.chat", 60},
    {@m, "deleteCircleMessage", "social:rw", "social.chat", 60},
    {@m, "pinMessage", "social:rw", "social.chat", 30},
    {@m, "unpinMessage", "social:rw", "social.chat", 30},
    {@m, "followCircle", "social:rw", "social.chat", 30},
    {@m, "circleTyping", "social:rw", "social.chat", 240},
    # ── contacts, follows, notifications ───────────────────────────────
    {@q, "contacts", "social:rw", nil, 120},
    {@q, "contact", "social:rw", nil, 120},
    {@q, "contactTypes", "social:rw", nil, 60},
    {@q, "lookupUser", "social:rw", nil, 60},
    {@q, "followers", "social:rw", nil, 60},
    {@q, "following", "social:rw", nil, 60},
    {@q, "contactSuggestions", "social:rw", nil, 60},
    {@q, "notifications", "social:rw", nil, 120},
    {@q, "notificationSettings", "social:rw", nil, 60},
    {@m, "addContact", "social:rw", nil, 30},
    {@m, "addContactFromFollower", "social:rw", nil, 30},
    {@m, "removeContact", "social:rw", nil, 30},
    {@m, "classifyContact", "social:rw", nil, 30},
    {@m, "createContactType", "social:rw", nil, 20},
    {@m, "followUser", "social:rw", nil, 30},
    {@m, "unfollowUser", "social:rw", nil, 30},
    {@m, "dismissSuggestion", "social:rw", nil, 30},
    {@m, "markNotificationsRead", "social:rw", nil, 60},
    {@m, "updateNotificationSettings", "social:rw", nil, 30},
    # ── calendar (phase 1) ─────────────────────────────────────────────
    {@q, "myCalendars", "calendar:read", "calendar.basic", 120},
    {@q, "calendar", "calendar:read", "calendar.basic", 120},
    {@q, "calendarShares", "calendar:read", "calendar.basic", 60},
    {@q, "calendarEvents", "calendar:read", "calendar.basic", 120},
    {@q, "myAgenda", "calendar:read", "calendar.basic", 120},
    {@q, "calendarEvent", "calendar:read", "calendar.basic", 120},
    {@q, "eventInvites", "calendar:read", "calendar.basic", 60},
    {@q, "holidays", "calendar:read", "calendar.basic", 60},
    {@m, "createCalendar", "calendar:rw", "calendar.basic", 20},
    {@m, "updateCalendar", "calendar:rw", "calendar.basic", 30},
    {@m, "archiveCalendar", "calendar:rw", "calendar.basic", 20},
    {@m, "shareCalendarWithUser", "calendar:rw", "calendar.basic", 30},
    {@m, "shareCalendarWithCircle", "calendar:rw", "calendar.basic", 30},
    {@m, "unshareCalendar", "calendar:rw", "calendar.basic", 30},
    {@m, "createEvent", "calendar:rw", "calendar.basic", 60},
    {@m, "updateEvent", "calendar:rw", "calendar.basic", 60},
    {@m, "cancelEvent", "calendar:rw", "calendar.basic", 60},
    {@m, "skipOccurrence", "calendar:rw", "calendar.basic", 60},
    {@m, "inviteToEvent", "calendar:rw", "calendar.basic", 30},
    {@m, "rsvpEvent", "calendar:rw", "calendar.basic", 60},
    {@m, "removeInvite", "calendar:rw", "calendar.basic", 30},
    {@m, "setPrivateNote", "calendar:rw", "calendar.basic", 60},
    # ── calendar (phase 2, ready for when that code is merged) ─────────
    {@m, "createPoll", "calendar:plus", "calendar.polls", 20},
    {@m, "createShareLink", "calendar:plus", "calendar.share_links", 20},
    {@m, "setWorkingHours", "calendar:business", "calendar.business", 20},
    {@q, "freeBusy", "calendar:business", "calendar.business", 60},
    {@q, "commonFreeSlots", "calendar:business", "calendar.business", 60},
    {@m, "createBookingPage", "calendar:booking", "calendar.booking", 10},
    {@q, "bookings", "calendar:booking", "calendar.booking", 60},
    # ── REST /api/v1 ───────────────────────────────────────────────────
    {@r, "POST /api/v1/registration/complete", "auth:register", nil, 10},
    {@r, "POST /api/v1/profile", "profile:rw", nil, 30},
    {@r, "GET /api/v1/profile", "profile:rw", nil, 120},
    {@r, "PATCH /api/v1/profile", "profile:rw", nil, 30},
    {@r, "GET /api/v1/search", "search:read", nil, 60},
    {@r, "POST /api/v1/search/index", "search:read", nil, 20},
    {@r, "GET /api/v1/search/stats", "search:read", nil, 60}
  ]

  def defaults, do: @defaults

  @doc "Inserts every default endpoint that is not in the table yet."
  @spec sync() :: :ok | {:error, term()}
  def sync do
    {kinds, names, scopes, features, rates} =
      Enum.reduce(Enum.reverse(@defaults), {[], [], [], [], []}, fn {k, n, s, f, r}, {ks, ns, ss, fs, rs} ->
        {[k | ks], [n | ns], [s | ss], [f | fs], [r | rs]}
      end)

    result =
      Db.exec(
        """
        INSERT INTO przma_authz.api_endpoints (kind, name, scope_code, feature_code, rate_limit_per_min)
        SELECT * FROM unnest($1::text[], $2::text[], $3::text[], $4::text[], $5::int[])
        ON CONFLICT (kind, name) DO NOTHING
        """,
        [kinds, names, scopes, features, rates]
      )

    case result do
      :ok ->
        Cache.delete(:endpoints)
        Logger.info("Authz: endpoint registry synced (#{length(@defaults)} defaults)")
        :ok

      {:error, reason} = err ->
        Logger.error("Authz: endpoint registry sync failed: #{inspect(reason)}")
        err
    end
  end

  @doc """
  The registry row for one API, from the cached table.
  {:ok, row} | {:error, :endpoint_not_registered} | {:error, db_reason}
  """
  @spec lookup(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def lookup(kind, name) do
    with {:ok, all} <- Cache.fetch(:endpoints, &load_all/0) do
      case Map.get(all, {kind, name}) do
        nil -> {:error, :endpoint_not_registered}
        row -> {:ok, row}
      end
    end
  end

  defp load_all do
    with {:ok, rows} <-
           Db.all("""
           SELECT kind, name, scope_code, feature_code, rate_limit_per_min, active
             FROM przma_authz.api_endpoints
           """) do
      {:ok,
       Map.new(rows, fn r ->
         {{r.kind, r.name},
          %{
            kind: r.kind,
            name: r.name,
            scope: r.scope_code,
            feature: r.feature_code,
            rate_limit: r.rate_limit_per_min,
            active: r.active
          }}
       end)}
    end
  end

  @doc "Absinthe field identifier (:create_event) -> \"createEvent\"."
  def graphql_name(identifier) when is_atom(identifier),
    do: identifier |> Atom.to_string() |> Macro.camelize() |> lower_first()

  defp lower_first(<<first::utf8, rest::binary>>), do: String.downcase(<<first::utf8>>) <> rest
end
