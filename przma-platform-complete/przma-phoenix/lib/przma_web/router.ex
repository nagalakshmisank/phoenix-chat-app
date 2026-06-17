# lib/przma_web/router.ex (calendar routes section)
#
# Add these routes to the existing PRZMA router.
# All /api/v1/calendar routes require DID authentication
# via the :require_did_auth pipeline.

defmodule PRZMAWeb.Router do
  use PRZMAWeb, :router

  pipeline :api do
    plug :accepts, ["json"]

    # Parse request bodies. Required because we start the Router directly via
    # Plug.Cowboy (see PRZMA.Application), bypassing the Endpoint's Plug.Parsers.
    plug Plug.Parsers,
      parsers: [:urlencoded, :multipart, :json],
      pass: ["*/*"],
      length: 1_000_000_000,
      read_length: 1_000_000,
      json_decoder: Jason
  end

  pipeline :require_did_auth do
    plug PRZMAWeb.Plugs.DIDAuth
  end

  # ── CALENDAR ROUTES ────────────────────────────────────────────────────────
  # TODO: Calendar service disabled for now — has compilation errors in controllers
  # Re-enable when calendar service is ready
  #
  # scope "/api/v1/calendar", PRZMAWeb.Calendar do
  #   pipe_through [:api, :require_did_auth]
  #   ...calendar routes...
  # end
  #
  # scope "/book", PRZMAWeb.Calendar do
  #   ...booking routes...
  # end
  #
  # scope "/caldav", PRZMAWeb do
  #   ...caldav routes...
  # end
  #
  # scope "/ap", PRZMAWeb do
  #   ...activitypub routes...
  # end

  # ── FILE SYNC (offline client → CAS + pzdb) ──────────────────────────────
  #
  # IMPROVED: Integrates PRZMA.Platform.CAS + ServicesCatalogue
  #
  # Single-device sync (offline client):
  #   blob   → PRZMA.Platform.CAS.put()  → server CAS (s3://perkeep/cas/{aa}/{hash})
  #   record → PzDb.write()              → remote Lance (hierarchical namespace)
  #
  # Multi-device sync (pull missing files):
  #   GET /pending                       → list missing syncs from queue
  #   POST /mark-synced                  → update sync queue status
  #
  # EFFICIENCY IMPROVEMENTS:
  #   ✅ 25% storage savings (no base64 overhead)
  #   ✅ Hierarchical namespace (files/core/, files/commons/, files/circle/)
  #   ✅ Perfect deduplication (CAS by hash)
  #   ✅ Multi-device sync support
  #   ✅ Encryption support

  scope "/api/v1/files", PRZMAWeb do
    pipe_through :api

    # Single-device sync (offline upload)
    post "/sync/blob",         FileSyncController, :upload_blob
    post "/sync/record",       FileSyncController, :sync_record
    get  "/sync/list",         FileSyncController, :list_remote
    get  "/sync/cas-meta",     FileSyncController, :list_cas_meta
    get  "/sync/blob/:hash",   FileSyncController, :download_blob

    # Multi-device sync (pull missing files from server queue)
    get  "/sync/pending",      FileSyncController, :list_pending
    post "/sync/mark-synced",  FileSyncController, :mark_synced
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
