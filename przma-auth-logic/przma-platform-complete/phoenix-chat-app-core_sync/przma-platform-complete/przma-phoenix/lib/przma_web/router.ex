# lib/przma_web/router.ex (calendar routes section)
#
# Add these routes to the existing PRZMA router.
# All /api/v1/calendar routes require DID authentication
# via the :require_did_auth pipeline.

defmodule PRZMAWeb.Router do
  use PRZMAWeb, :router

  pipeline :api do
    plug :accepts, ["json", "activity+json"]
    plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

    # Parse request bodies. Required because we start the Router directly via
    # Plug.Cowboy (see PRZMA.Application), bypassing the Endpoint's Plug.Parsers.
    plug Plug.Parsers,
      parsers: [:urlencoded, :multipart, :json],
      pass: ["*/*"],
      length: 1_000_000_000,
      read_length: 1_000_000,
      json_decoder: Jason
  end
  
  pipeline :api_binary do
    plug :accepts, ["json", "activity+json", "octet-stream"]
    plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]
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

  pipeline :openapi do
    plug OpenApiSpex.Plug.PutApiSpec, module: PRZMAWeb.ApiSpec
  end
 
  
  scope "/api/openapi" do
    pipe_through :openapi
    get "/", OpenApiSpex.Plug.RenderSpec, []
  end
 
  scope "/swaggerui" do
    pipe_through :openapi
    get "/", OpenApiSpex.Plug.SwaggerUI, path: "/api/openapi"
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
    pipe_through [:api_binary, :require_did_auth]

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

  scope "/api/v1/social", PRZMAWeb do
    pipe_through [:api_binary, :require_did_auth]

    post "/sync/activity",          SocialSyncController, :sync_activity
    get  "/sync/inbox",             SocialSyncController, :list_inbox
    get  "/sync/view/:activity_id", SocialSyncController, :view_activity
    delete "/sync/:activity_id",  SocialSyncController, :delete_activity
    post "/sync/save",              SocialSyncController, :save_to_vault
    get  "/sync/outbox",            SocialSyncController, :list_outbox
    
  end

  # ── CIRCLES (group membership, roles, invite links, group messaging) ────
  #
  # Circle roster + settings live in the OWNER's own DID folder
  # (social/circle/circles.lance, social/circle/circle_members.lance).
  # Invite-code → owner_did resolution uses one shared lookup table at
  # przma-directory/circles/core/invites — the only non-DID-scoped table
  # in this feature. Group messages reuse ActivitySync.publish/1 under
  # the hood (space: "circle:{circle_id}"), so they show up in the normal
  # /api/v1/social/sync/inbox feed for every member.

  scope "/api/v1/circles", PRZMAWeb do
    pipe_through [:api_binary, :require_did_auth]

    post   "/",                                CircleController, :create
    post   "/join",                            CircleController, :join
    get    "/mine",                            CircleController, :mine
    get    "/:circle_id/members",              CircleController, :members
    get    "/:circle_id",                      CircleController, :show
    post   "/:circle_id/approve",              CircleController, :approve
    post   "/:circle_id/deny",                 CircleController, :deny
    delete "/:circle_id/members/:member_did",  CircleController, :remove_member
    post   "/:circle_id/messages",             CircleController, :send_message
    delete "/:circle_id",                      CircleController, :delete
    delete "/:circle_id/messages/:message_id", CircleController, :delete_message
    post   "/:circle_id/messages/:message_id/pin",   CircleController, :pin_message
    delete "/:circle_id/messages/:message_id/pin",   CircleController, :unpin_message
    post "/:circle_id/members/:member_did/mute", CircleController, :mute_member
    get "/:circle_id/pending",                  CircleController, :pending
  end

  # ── AUTH (pure Lance — no Postgres) ─────────────────────────────────────

  scope "/api/v1", PRZMAWeb do
    pipe_through :api

    post "/account/register",        AuthController, :register
    post "/account/verify_email",    AuthController, :verify_email
    post "/account/resend_otp",      AuthController, :resend_otp
    post "/account/forgot_password", AuthController, :forgot_password
    post "/account/reset_password",  AuthController, :reset_password
    post "/oauth/token",             AuthController, :login
  end

  scope "/api/v1", PRZMAWeb do
    pipe_through [:api, :require_did_auth]

    get    "/accounts/verify_credentials", AuthController, :verify_credentials
    delete "/oauth/token",                 AuthController, :logout
    get    "/sessions",                    AuthController, :list_sessions
    delete "/sessions/:id",                AuthController, :revoke_session
    delete "/sessions",                    AuthController, :revoke_all_sessions
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