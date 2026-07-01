# lib/przma_web/router.ex (calendar routes section)
#
# Add these routes to the existing PRZMA router.
# All /api/v1/calendar routes require DID authentication
# via the :require_did_auth pipeline.

defmodule PRZMAWeb.Router do
  use PRZMAWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :require_did_auth do
    plug PRZMAWeb.Plugs.DIDAuth
  end

  # ── CALENDAR ROUTES ────────────────────────────────────────────────────────

  scope "/api/v1/calendar", PRZMAWeb.Calendar do
    pipe_through [:api, :require_did_auth]

    # Events
    get    "/events",                     EventController, :index
    post   "/events",                     EventController, :create
    get    "/events/search",              EventController, :search
    post   "/events/analytics",           EventController, :analytics
    get    "/events/:id",                 EventController, :show
    put    "/events/:id",                 EventController, :update
    delete "/events/:id",                 EventController, :delete
    post   "/events/:id/rsvp",            EventController, :rsvp
    post   "/events/:id/share",           EventController, :share
    get    "/events/:id/intelligence",    EventController, :intelligence

    # Tasks
    get    "/tasks",                      TaskController, :index
    post   "/tasks",                      TaskController, :create
    post   "/tasks/:id/complete",         TaskController, :complete
    post   "/tasks/:id/assign",           TaskController, :assign
    post   "/tasks/:id/block",            TaskController, :block

    # Availability
    get    "/availability",               AvailabilityController, :index
    put    "/availability",               AvailabilityController, :update
    get    "/availability/:did",          AvailabilityController, :freebusy

    # Booking links (create requires auth; show/book are public below)
    get    "/booking-links",              BookingController, :index
    post   "/booking-links",              BookingController, :create

    # Circle polls
    get    "/circles/:circle_did/polls",         PollController, :index
    post   "/circles/:circle_did/polls",         PollController, :create
    post   "/circles/:circle_did/polls/:id/vote",   PollController, :vote
    post   "/circles/:circle_did/polls/:id/resolve", PollController, :resolve
  end

  # ── PUBLIC BOOKING ROUTES (no auth) ───────────────────────────────────────

  scope "/book", PRZMAWeb.Calendar do
    pipe_through :api

    # Public booking link pages
    get  "/:id",      BookingController, :show
    post "/:id/book", BookingController, :book
  end

  # ── CALDAV ROUTES ─────────────────────────────────────────────────────────

  scope "/caldav", PRZMAWeb do
    pipe_through :api

    get  "/.well-known/caldav",             CalDAVController, :well_known
    match :propfind, "/principal/:did",     CalDAVController, :principal
    match :propfind, "/calendars/:did/",    CalDAVController, :calendar_list
    get   "/calendars/:did/:calendar_id/",  CalDAVController, :calendar_get
    put   "/calendars/:did/:calendar_id/:uid.ics", CalDAVController, :event_put
    delete "/calendars/:did/:calendar_id/:uid.ics", CalDAVController, :event_delete
  end

  # ── ACTIVITYPUB CALENDAR ROUTES ───────────────────────────────────────────

  scope "/ap", PRZMAWeb do
    pipe_through :api

    get  "/actor/:did",    ActivityPubController, :actor
    post "/inbox/:did",    ActivityPubController, :inbox
    get  "/outbox/:did",   ActivityPubController, :outbox
    get  "/events/:id",    ActivityPubController, :event
  end

  # ── WEBSOCKET ─────────────────────────────────────────────────────────────

  # In your endpoint.ex:
  # socket "/socket", PRZMAWeb.UserSocket, websocket: true
  # and in UserSocket: channel "calendar:*", PRZMAWeb.CalendarChannel
end

defmodule PRZMAWeb.Router.Phase6Routes do
  @moduledoc """
  Phase 6 analytics and companion context routes.
  Add these to the :require_did_auth scope in PRZMAWeb.Router.

  scope "/api/v1/calendar", PRZMAWeb.Calendar do
    pipe_through [:api, :require_did_auth]

    # Analytics
    get  "/analytics/time-distribution",          AnalyticsController, :time_distribution
    get  "/analytics/meeting-patterns",            AnalyticsController, :meeting_patterns
    get  "/analytics/practice-adherence/:title",   AnalyticsController, :practice_adherence
    get  "/analytics/insights",                    AnalyticsController, :insights
    get  "/analytics/weekly-report",               AnalyticsController, :weekly_report
    get  "/companion/context",                     AnalyticsController, :companion_context
    post "/analytics/embed",                       AnalyticsController, :embed
    post "/analytics/semantic-rank",               AnalyticsController, :semantic_rank
    post "/analytics/backfill-embeddings",         AnalyticsController, :backfill_embeddings

    # Intelligence endpoints
    get  "/events/:id/intelligence",               IntelligenceController, :pre_brief
    post "/events/:id/capture/audio",              IntelligenceController, :capture_audio
    post "/events/:id/capture/note",               IntelligenceController, :capture_note
    post "/events/:id/capture/marker",             IntelligenceController, :mark_moment
    post "/events/:id/capture/confirm_action",     IntelligenceController, :confirm_action
    post "/events/:id/reflection",                 IntelligenceController, :submit_reflection
    get  "/events/:id/summary",                    IntelligenceController, :meeting_summary
    get  "/events/:id/transcript",                 IntelligenceController, :get_transcript
    get  "/events/:id/transcript/text",            IntelligenceController, :get_transcript_text
    post "/intelligence/extract",                  IntelligenceController, :extract_action_items

    # Deployment
    get    "/deployment/mode",                     DeploymentController, :show_mode
    get    "/deployment/license",                  DeploymentController, :license
    post   "/deployment/byos/register",            DeploymentController, :register_byos
    get    "/deployment/byos/validate",            DeploymentController, :validate_byos
    delete "/deployment/byos",                     DeploymentController, :revoke_byos
    get    "/deployment/storage/status",           DeploymentController, :storage_status
    post   "/deployment/encryption/setup",         DeploymentController, :setup_encryption
  end
  """
end
