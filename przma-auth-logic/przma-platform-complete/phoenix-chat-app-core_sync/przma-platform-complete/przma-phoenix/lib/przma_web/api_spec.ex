defmodule PRZMAWeb.ApiSpec do
  @moduledoc """
  OpenAPI/Swagger specification for the PRZMA Platform API.

  Scope: routes live in lib/przma_web/router.ex —
  /api/v1/account/*, /api/v1/oauth/*, /api/v1/sessions*,
  /api/v1/accounts/verify_credentials, /api/v1/files/*, /api/v1/social/*,
  /api/v1/circles/*.

  Calendar (/api/v1/calendar/*) is intentionally NOT included here: it is
  commented out in router.ex ("Calendar service disabled — has compilation
  errors in controllers"). Add it back into this spec only once those routes
  are uncommented and working.
  """

  alias OpenApiSpex.{Components, Info, OpenApi, Reference, Schema, Server}

  @behaviour OpenApi

  @impl OpenApi
  def spec do
    %OpenApi{
      info: %Info{
        title: "PRZMA Platform API — Files, Social, Circles & Auth",
        version: "1.0.0",
        description: """
        Live endpoints: /api/v1/account/*, /api/v1/oauth/*, /api/v1/sessions,
        /api/v1/accounts/verify_credentials, /api/v1/files/*, /api/v1/social/*,
        and /api/v1/circles/*.

        ## Auth
        - `/api/v1/account/*` and `POST /api/v1/oauth/token` — public, no auth
          required (registration/login themselves).
        - `/api/v1/social/*`, `/api/v1/files/*`, `/api/v1/circles/*`,
          `DELETE /api/v1/oauth/token`, `/api/v1/sessions*`,
          `/api/v1/accounts/verify_credentials` — require
          `:require_did_auth` (`PRZMAWeb.Plugs.DIDAuth`). Real signed-token
          verification (`Phoenix.Token`), not a stub — the DID is embedded in
          the token itself, so verifying it never touches the database.

        ## Circles
        Circles are WhatsApp-group-style spaces: create → get a shareable
        invite link → others join (instantly or pending owner/admin
        approval) → group messages fan out via the existing
        `/api/v1/social/sync/activity` delivery mechanism, so they show up
        in the normal `/api/v1/social/sync/inbox` feed for every member.

        Roles: owner, admin, member, restricted, audience. Status: pending,
        active, removed, left — status gates access entirely; role only
        matters once status is active. `audience` is assigned automatically
        to anyone who joins after the circle hits `max_members` — they can
        receive messages but not send or pin. Ownership can be handed off
        via transfer-ownership; the outgoing owner becomes a regular
        `member`.

        ## Deletes are soft
        `DELETE /api/v1/social/sync/{activity_id}` and
        `DELETE /api/v1/circles/{circle_id}` mark rows `status: "deleted"`
        rather than physically removing them, and only ever act on the
        caller's own copy (sender's own outbox, or a circle the caller
        owns) — no endpoint reaches into another member's private inbox.

        ## Realtime
        The REST endpoints below are mirrored by broadcasts on the
        `circle:{circle_id}` Phoenix channel topic: `circle_deleted`,
        `message_pinned`, `message_unpinned`, `member_joined`,
        `join_requested`, `member_removed`, `member_muted`, `member_left`,
        `ownership_transferred`. Swagger only exercises the REST side —
        use a socket client to see the pushes.
        """
      },
      servers: [
        %Server{url: "http://172.235.18.126:4201", description: "Development"}
      ],
      paths: %{
        # ── AUTH ─────────────────────────────────────────────────────────
        "/api/v1/account/register" => %OpenApiSpex.PathItem{
          post: op_auth_body("Register Account", "register",
            "Create a new account. DID is computed as did:przma:<nickname>. " <>
            "Sends a 6-digit OTP to the given email for verification.",
            "RegisterRequest",
            %{200 => resp("Registered — check email for OTP", "RegisterResponse"),
              400 => resp("Invalid nickname/password", "ErrorResponse"),
              409 => resp("nickname_taken", "ErrorResponse")})
        },

        "/api/v1/account/verify_email" => %OpenApiSpex.PathItem{
          post: op_auth_body("Verify Email (OTP)", "verify_email",
            "Confirm the 6-digit code sent at registration. Max 3 attempts, " <>
            "10-minute expiry.",
            "VerifyEmailRequest",
            %{200 => resp("Verified", "OkResponse"),
              400 => resp("Invalid or expired code", "ErrorResponse"),
              404 => resp("User not found", "ErrorResponse"),
              429 => resp("Too many attempts", "ErrorResponse")})
        },

        "/api/v1/account/resend_otp" => %OpenApiSpex.PathItem{
          post: op_auth_body("Resend OTP", "resend_otp",
            "Issue a fresh 6-digit code. Rate-limited to one per 60 seconds.",
            "ResendOtpRequest",
            %{200 => resp("Sent", "OkResponse"),
              404 => resp("User not found", "ErrorResponse"),
              429 => resp("Rate limited", "ErrorResponse")})
        },

        "/api/v1/account/forgot_password" => %OpenApiSpex.PathItem{
          post: op_auth_body("Forgot Password", "forgot_password",
            "Request a password-reset token by nickname + email. Always " <>
            "returns 200 (never reveals whether the account exists).",
            "ForgotPasswordRequest",
            %{200 => resp("Sent (or silently ignored)", "OkResponse")})
        },

        "/api/v1/account/reset_password" => %OpenApiSpex.PathItem{
          post: op_auth_body("Reset Password", "reset_password",
            "Complete a password reset using the token from forgot_password. " <>
            "15-minute expiry, max 3 attempts, single use.",
            "ResetPasswordRequest",
            %{200 => resp("Password reset", "OkResponse"),
              400 => resp("Invalid, expired, or mismatched passwords", "ErrorResponse"),
              404 => resp("No reset requested for this account", "ErrorResponse"),
              429 => resp("Too many attempts", "ErrorResponse")})
        },

        "/api/v1/oauth/token" => %OpenApiSpex.PathItem{
          post: op_auth_body("Login (issue access token)", "login",
            "Password grant. Verifies credentials, issues a signed access " <>
            "token (Phoenix.Token, 24h) and creates a session row for " <>
            "later revoke/logout.",
            "LoginRequest",
            %{200 => resp("Logged in", "LoginResponse"),
              401 => resp("Invalid nickname or password", "ErrorResponse"),
              403 => resp("Account disabled", "ErrorResponse")}),
          delete: %OpenApiSpex.Operation{
            summary: "Logout (revoke current session)", tags: ["Auth"], operationId: "logout",
            description: "Revokes a specific session id if supplied. The access " <>
                         "token itself remains cryptographically valid until it " <>
                         "expires (stateless) — revoking only removes it from " <>
                         "the active-sessions list.",
            security: [%{"BearerAuth" => []}],
            requestBody: OpenApiSpex.Operation.request_body(
              "Optional session_id", "application/json",
              %Reference{"$ref": "#/components/schemas/LogoutRequest"}, required: false
            ),
            responses: %{200 => resp("Logged out", "OkResponse"),
                         401 => resp("Unauthorized", "ErrorResponse")}
          }
        },

        "/api/v1/accounts/verify_credentials" => %OpenApiSpex.PathItem{
          get: %OpenApiSpex.Operation{
            summary: "Get Current Account", tags: ["Auth"], operationId: "verify_credentials",
            description: "Returns the authenticated DID's profile.",
            security: [%{"BearerAuth" => []}],
            responses: %{200 => resp("OK", "AccountResponse"),
                         401 => resp("Unauthorized", "ErrorResponse"),
                         404 => resp("Not found", "ErrorResponse")}
          }
        },

        "/api/v1/sessions" => %OpenApiSpex.PathItem{
          get: %OpenApiSpex.Operation{
            summary: "List Active Sessions", tags: ["Auth"], operationId: "list_sessions",
            description: "Lists this DID's non-revoked login sessions.",
            security: [%{"BearerAuth" => []}],
            responses: %{200 => resp("OK", "SessionsResponse"),
                         401 => resp("Unauthorized", "ErrorResponse")}
          },
          delete: %OpenApiSpex.Operation{
            summary: "Logout Everywhere", tags: ["Auth"], operationId: "revoke_all_sessions",
            description: "Revokes every active session for this DID.",
            security: [%{"BearerAuth" => []}],
            responses: %{200 => resp("OK", "OkResponse"),
                         401 => resp("Unauthorized", "ErrorResponse")}
          }
        },

        "/api/v1/sessions/{id}" => %OpenApiSpex.PathItem{
          delete: %OpenApiSpex.Operation{
            summary: "Revoke One Session", tags: ["Auth"], operationId: "revoke_session",
            description: "Revokes a single session belonging to the authenticated DID.",
            security: [%{"BearerAuth" => []}],
            parameters: [
              %OpenApiSpex.Parameter{name: :id, in: :path, required: true, schema: %Schema{type: :string}}
            ],
            responses: %{200 => resp("Revoked", "OkResponse"),
                         401 => resp("Unauthorized", "ErrorResponse"),
                         404 => resp("Session not found", "ErrorResponse")}
          }
        },

        # ── FILES ────────────────────────────────────────────────────────
        "/api/v1/files/sync/blob" => %OpenApiSpex.PathItem{
          post: %OpenApiSpex.Operation{
            summary: "Upload Blob", tags: ["Files"], operationId: "upload_blob",
            description: "Upload a file blob to CAS. did/blake3_hash come " <>
              "from headers x-przma-did / x-przma-blake3 (or body params). " <>
              "Accepts raw octet-stream OR multipart/form-data with a " <>
              "`blob` field. IMPORTANT: for raw-body uploads you MUST send " <>
              "Content-Type: application/octet-stream explicitly — " <>
              "without it, curl/some clients default to " <>
              "application/x-www-form-urlencoded, which the :api " <>
              "pipeline's Plug.Parsers will consume before this " <>
              "controller can read the body, silently storing an empty " <>
              "(0-byte) blob.",
            security: [%{"BearerAuth" => []}],
            parameters: [
              %OpenApiSpex.Parameter{
                name: :"x-przma-did", in: :header, required: true,
                description: "DID of the uploading user",
                schema: %Schema{type: :string}, example: "did:example:alice"
              },
              %OpenApiSpex.Parameter{
                name: :"x-przma-blake3", in: :header, required: true,
                description: "BLAKE3 hash of the blob being uploaded",
                schema: %Schema{type: :string},
                example: "demo000000000000000000000000000000000000000000000000000001"
              },
              %OpenApiSpex.Parameter{
                name: :"x-przma-space", in: :header, required: false,
                description: "Namespace (core | commons | circle), default core",
                schema: %Schema{type: :string, default: "core"}, example: "circle"
              }
            ],
            requestBody: %OpenApiSpex.RequestBody{
              description: "Raw binary blob to store. Set the dropdown to " <>
                "application/octet-stream and type/paste the file content " <>
                "into the body box.",
              required: true,
              content: %{
                "application/octet-stream" => %OpenApiSpex.MediaType{
                  schema: %Schema{type: :string, format: :binary}
                }
              }
            },
            responses: %{
              200 => resp("Stored", "UploadBlobResponse"),
              400 => resp("Missing fields", "ErrorResponse"),
              401 => resp("Unauthorized", "ErrorResponse"),
              403 => resp("did_mismatch", "ErrorResponse"),
              500 => resp("Server error", "ErrorResponse")
            }
          }
        },

        "/api/v1/files/sync/record" => %OpenApiSpex.PathItem{
          post: op_files_body("Sync File Record", "sync_record",
            "Sync file metadata to pzdb (Lance).",
            "SyncRecordRequest",
            %{200 => resp("Synced", "SyncRecordResponse"),
              403 => resp("did_mismatch", "ErrorResponse"),
              500 => resp("Server error", "ErrorResponse")})
        },

        #"/api/v1/files/sync/list" => %OpenApiSpex.PathItem{
         # get: op_files("List Remote Files", "list_remote",
          #  "List synced files for a space (core | commons | circle).",
           # %{200 => resp("OK", "ListRemoteResponse")})
       # },

        #"/api/v1/files/sync/cas-meta" => %OpenApiSpex.PathItem{
         # get: op_files("List CAS Metadata", "list_cas_meta",
          #  "List CAS blob metadata (hash, ref_count, size, space, s3_uri).",
           # %{200 => resp("OK", "ListCasMetaResponse")})
       # },

        "/api/v1/files/sync/blob/{hash}" => %OpenApiSpex.PathItem{
          get: %OpenApiSpex.Operation{
            summary: "Download Blob", tags: ["Files"], operationId: "download_blob",
            description: "Download a blob from CAS by its BLAKE3 hash.",
            security: [%{"BearerAuth" => []}],
            parameters: [
              %OpenApiSpex.Parameter{
                name: :hash, in: :path, required: true,
                schema: %Schema{type: :string}
              },
              %OpenApiSpex.Parameter{
                name: :owner, in: :query, required: false,
                description: "DID of the blob owner (defaults to requester's did)",
                schema: %Schema{type: :string}
              }
            ],
            responses: %{
              200 => %OpenApiSpex.Response{
                description: "Binary blob",
                content: %{"application/octet-stream" => %OpenApiSpex.MediaType{
                  schema: %Schema{type: :string, format: :binary}
                },
                "application/json" => %OpenApiSpex.MediaType{
                 schema: %Schema{type: :string, format: :binary}
                }
                }
              },
              401 => resp("Unauthorized", "ErrorResponse"),
              404 => resp("Not found", "ErrorResponse")
            }
          }
        },

        "/api/v1/files/sync/pending" => %OpenApiSpex.PathItem{
          get: op_files("List Pending Syncs", "list_pending",
            "List items still queued for sync (status = pending).",
            %{200 => resp("OK", "ListPendingResponse")})
        },

        "/api/v1/files/sync/mark-synced" => %OpenApiSpex.PathItem{
          post: op_files_body("Mark Synced", "mark_synced",
            "Mark a queued file_id (in a given space) as synced.",
            "MarkSyncedRequest",
            %{200 => resp("OK", "MarkSyncedResponse"),
              500 => resp("Server error", "ErrorResponse")})
        },

        # ── SOCIAL ───────────────────────────────────────────────────────
        "/api/v1/social/sync/activity" => %OpenApiSpex.PathItem{
          post: op_social_body("Publish Activity", "sync_activity",
            "Publish an activity to a recipient's inbox. Requires DID auth.",
            "SyncActivityRequest",
            %{200 => resp("Synced", "SyncActivityResponse"),
              400 => resp("Missing required fields", "ErrorResponse"),
              401 => resp("Unauthorized", "ErrorResponse"),
              403 => resp("did_mismatch", "ErrorResponse")})
        },

        "/api/v1/social/sync/inbox" => %OpenApiSpex.PathItem{
          get: %OpenApiSpex.Operation{
            summary: "List Inbox", tags: ["Social"], operationId: "list_inbox",
            description: "List inbox activities for the authenticated DID.",
            security: [%{"BearerAuth" => []}],
            parameters: [
              %OpenApiSpex.Parameter{
                name: :since, in: :query, required: false,
                description: "Unix microseconds — only activities after this timestamp",
                schema: %Schema{type: :integer}
              }
            ],
            responses: %{
              200 => resp("OK", "ListInboxResponse"),
              401 => resp("Unauthorized", "ErrorResponse")
            }
          }
        },

        # ── SOCIAL: NEW — outbox read ──────────────────────────────────
        "/api/v1/social/sync/outbox" => %OpenApiSpex.PathItem{
          get: %OpenApiSpex.Operation{
            summary: "List Outbox", tags: ["Social"], operationId: "list_outbox",
            description: "List the authenticated DID's own sent activities. " <>
                         "Deleted activities (status = deleted) are excluded.",
            security: [%{"BearerAuth" => []}],
            parameters: [
              %OpenApiSpex.Parameter{
                name: :since, in: :query, required: false,
                description: "Unix microseconds — only activities after this timestamp",
                schema: %Schema{type: :integer}
              }
            ],
            responses: %{
              200 => resp("OK", "ListOutboxResponse"),
              401 => resp("Unauthorized", "ErrorResponse")
            }
          }
        },

        "/api/v1/social/sync/view/{activity_id}" => %OpenApiSpex.PathItem{
          get: %OpenApiSpex.Operation{
            summary: "View Activity Object", tags: ["Social"], operationId: "view_activity",
            description: "Download the CAS object referenced by an inbox " <>
                         "activity. Requires the activity to have been " <>
                         "published with a non-null object_cas field; " <>
                         "otherwise this errors (no object to resolve).",
            security: [%{"BearerAuth" => []}],
            parameters: [
              %OpenApiSpex.Parameter{
                name: :activity_id, in: :path, required: true,
                schema: %Schema{type: :string}
              }
            ],
            responses: %{
              200 => %OpenApiSpex.Response{
                description: "Binary content",
                content: %{"application/octet-stream" => %OpenApiSpex.MediaType{
                  schema: %Schema{type: :string, format: :binary}
                },
                "application/json" => %OpenApiSpex.MediaType{
                schema: %Schema{type: :string, format: :binary}
                }
                }
              },
              401 => resp("Unauthorized", "ErrorResponse"),
              404 => resp("activity_not_found", "ErrorResponse")
            }
          }
        },

        # ── SOCIAL: NEW — delete own message ──────────────────────────
        "/api/v1/social/sync/{activity_id}" => %OpenApiSpex.PathItem{
          delete: %OpenApiSpex.Operation{
            summary: "Delete Own Message", tags: ["Social"], operationId: "delete_activity",
            description: "Soft-deletes an activity from the caller's own " <>
                         "outbox only (status: deleted). Does not remove " <>
                         "already-delivered copies from any recipient's " <>
                         "inbox — deleting someone else's message is not " <>
                         "supported (would require reading another DID's " <>
                         "private inbox).",
            security: [%{"BearerAuth" => []}],
            parameters: [
              %OpenApiSpex.Parameter{
                name: :activity_id, in: :path, required: true,
                schema: %Schema{type: :string}
              }
            ],
            responses: %{
              200 => resp("Deleted", "OkResponse"),
              401 => resp("Unauthorized", "ErrorResponse"),
              404 => resp("Not found", "ErrorResponse")
            }
          }
        },

        "/api/v1/social/sync/save" => %OpenApiSpex.PathItem{
          post: op_social_body("Save Activity To Vault", "save_to_vault",
            "Copy an inbox activity's object into the caller's own vault. " <>
            "Requires the activity to have a non-null object_cas field.",
            "SaveToVaultRequest",
            %{200 => resp("Saved", "SaveToVaultResponse"),
              401 => resp("Unauthorized", "ErrorResponse"),
              404 => resp("activity_not_found", "ErrorResponse")})
        },

        # ── CIRCLES ──────────────────────────────────────────────────────
        "/api/v1/circles" => %OpenApiSpex.PathItem{
          post: op_circles_body("Create Circle", "create_circle",
            "Create a new circle. Caller becomes owner.",
            "CreateCircleRequest",
            %{200 => resp("Created", "CircleResponse"),
              401 => resp("Unauthorized", "ErrorResponse"),
              500 => resp("Server error", "ErrorResponse")})
        },

        "/api/v1/circles/join" => %OpenApiSpex.PathItem{
          post: op_circles_body("Join Circle", "join_circle",
            "Join a circle via invite code. Returns active or pending " <>
            "depending on the circle's join_approval_required setting. " <>
            "If the circle is already at max_members, the join still " <>
            "succeeds but the assigned role is \"audience\" instead of " <>
            "\"member\" (receive-only — no send/pin rights).",
            "JoinCircleRequest",
            %{200 => resp("Joined or pending", "JoinCircleResponse"),
              401 => resp("Unauthorized", "ErrorResponse"),
              404 => resp("invite_not_found", "ErrorResponse")})
        },

        "/api/v1/circles/mine" => %OpenApiSpex.PathItem{
          get: %OpenApiSpex.Operation{
            summary: "List My Circles", tags: ["Circles"], operationId: "list_my_circles",
            description: "List circles the authenticated DID belongs to.",
            security: [%{"BearerAuth" => []}],
            responses: %{200 => resp("OK", "MyCirclesResponse"),
                         401 => resp("Unauthorized", "ErrorResponse")}
          }
        },

        # ── CIRCLES: NEW — get / delete a single circle ───────────────
        "/api/v1/circles/{circle_id}" => %OpenApiSpex.PathItem{
          get: %OpenApiSpex.Operation{
            summary: "Get Circle", tags: ["Circles"], operationId: "show_circle",
            description: "Returns a single circle's own settings row " <>
                         "(name, invite link, member_count, etc.) — no " <>
                         "member list. Resolves the owning DID from the " <>
                         "caller's own mirrored membership row, so any " <>
                         "active member (not just the owner) can call this.",
            security: [%{"BearerAuth" => []}],
            parameters: [
              %OpenApiSpex.Parameter{name: :circle_id, in: :path, required: true, schema: %Schema{type: :string}}
            ],
            responses: %{200 => resp("OK", "CircleResponse"),
                         401 => resp("Unauthorized", "ErrorResponse"),
                         404 => resp("Not found", "ErrorResponse")}
          },
          delete: %OpenApiSpex.Operation{
            summary: "Delete Circle", tags: ["Circles"], operationId: "delete_circle",
            description: "Owner only. Soft-deletes the circle " <>
                         "(status: deleted) and marks every current " <>
                         "member's roster row deleted too, so it also " <>
                         "drops out of list_my_circles for the owner and " <>
                         "every member — not just get_circle. Broadcasts " <>
                         "circle_deleted on the circle channel.",
            security: [%{"BearerAuth" => []}],
            parameters: [
              %OpenApiSpex.Parameter{name: :circle_id, in: :path, required: true, schema: %Schema{type: :string}}
            ],
            responses: %{200 => resp("Deleted", "OkResponse"),
                         403 => resp("forbidden", "ErrorResponse"),
                         401 => resp("Unauthorized", "ErrorResponse")}
          }
        },

        "/api/v1/circles/{circle_id}/members" => %OpenApiSpex.PathItem{
          get: %OpenApiSpex.Operation{
            summary: "List Circle Members", tags: ["Circles"], operationId: "list_circle_members",
            description: "List active members of a circle.",
            security: [%{"BearerAuth" => []}],
            parameters: [
              %OpenApiSpex.Parameter{name: :circle_id, in: :path, required: true, schema: %Schema{type: :string}}
            ],
            responses: %{200 => resp("OK", "MembersResponse"),
                         401 => resp("Unauthorized", "ErrorResponse"),
                         404 => resp("Not found", "ErrorResponse")}
          }
        },

        # ── CIRCLES: NEW — pending join requests ───────────────────────
        "/api/v1/circles/{circle_id}/pending" => %OpenApiSpex.PathItem{
          get: %OpenApiSpex.Operation{
            summary: "List Pending Join Requests", tags: ["Circles"], operationId: "list_pending_members",
            description: "Owner/admin only. Lists circle_member rows with " <>
                         "status = pending, awaiting approve/deny.",
            security: [%{"BearerAuth" => []}],
            parameters: [
              %OpenApiSpex.Parameter{name: :circle_id, in: :path, required: true, schema: %Schema{type: :string}}
            ],
            responses: %{200 => resp("OK", "PendingResponse"),
                         403 => resp("forbidden", "ErrorResponse"),
                         401 => resp("Unauthorized", "ErrorResponse")}
          }
        },

        "/api/v1/circles/{circle_id}/approve" => %OpenApiSpex.PathItem{
          post: op_circles_body_with_path("Approve Join Request", "approve_member",
            "Approve a pending join request. Owner/admin only. Broadcasts " <>
            "member_joined on the circle channel.",
            :circle_id, "MemberDidRequest",
            %{200 => resp("Approved", "MemberResponse"),
              403 => resp("forbidden", "ErrorResponse"),
              401 => resp("Unauthorized", "ErrorResponse")})
        },

        "/api/v1/circles/{circle_id}/deny" => %OpenApiSpex.PathItem{
          post: op_circles_body_with_path("Deny Join Request", "deny_member",
            "Deny a pending join request. Owner/admin only. Broadcasts " <>
            "member_removed on the circle channel.",
            :circle_id, "MemberDidRequest",
            %{200 => resp("Denied", "OkResponse"),
              403 => resp("forbidden", "ErrorResponse"),
              401 => resp("Unauthorized", "ErrorResponse")})
        },

        "/api/v1/circles/{circle_id}/members/{member_did}" => %OpenApiSpex.PathItem{
          delete: %OpenApiSpex.Operation{
            summary: "Remove Member", tags: ["Circles"], operationId: "remove_circle_member",
            description: "Owner can remove anyone; admin cannot remove " <>
                         "another admin or the owner. Broadcasts " <>
                         "member_removed on the circle channel.",
            security: [%{"BearerAuth" => []}],
            parameters: [
              %OpenApiSpex.Parameter{name: :circle_id, in: :path, required: true, schema: %Schema{type: :string}},
              %OpenApiSpex.Parameter{name: :member_did, in: :path, required: true, schema: %Schema{type: :string}}
            ],
            responses: %{200 => resp("Removed", "OkResponse"),
                         403 => resp("forbidden", "ErrorResponse"),
                         401 => resp("Unauthorized", "ErrorResponse")}
          }
        },

        # ── CIRCLES: NEW — leave circle ─────────────────────────────────
        "/api/v1/circles/{circle_id}/leave" => %OpenApiSpex.PathItem{
          post: %OpenApiSpex.Operation{
            summary: "Leave Circle", tags: ["Circles"], operationId: "leave_circle",
            description: "Marks the caller's own membership row \"left\" " <>
                         "(both the owner's authoritative roster copy and " <>
                         "the caller's own mirrored copy), decrements " <>
                         "member_count or audience_count depending on the " <>
                         "caller's role, and broadcasts member_left on the " <>
                         "circle channel. The owner cannot leave directly — " <>
                         "transfer ownership first (see transfer-ownership " <>
                         "below).",
            security: [%{"BearerAuth" => []}],
            parameters: [
              %OpenApiSpex.Parameter{name: :circle_id, in: :path, required: true, schema: %Schema{type: :string}}
            ],
            responses: %{200 => resp("Left", "OkResponse"),
                         400 => resp("owner_cannot_leave", "ErrorResponse"),
                         404 => resp("Not found", "ErrorResponse"),
                         401 => resp("Unauthorized", "ErrorResponse")}
          }
        },

        # ── CIRCLES: NEW — transfer ownership ───────────────────────────
        "/api/v1/circles/{circle_id}/transfer-ownership" => %OpenApiSpex.PathItem{
          post: %OpenApiSpex.Operation{
            summary: "Transfer Ownership", tags: ["Circles"], operationId: "transfer_circle_ownership",
            description: "Current owner only. Hands the circle over to " <>
                         "another active member: that member becomes " <>
                         "\"owner\", the current owner becomes a regular " <>
                         "\"member\", and the circle + roster source-of-" <>
                         "truth rows move to the new owner's vault. " <>
                         "Broadcasts ownership_transferred on the circle " <>
                         "channel. The target must already be an active " <>
                         "member of the circle.",
            security: [%{"BearerAuth" => []}],
            parameters: [
              %OpenApiSpex.Parameter{name: :circle_id, in: :path, required: true, schema: %Schema{type: :string}}
            ],
            requestBody: OpenApiSpex.Operation.request_body(
              "Request body", "application/json",
              %Reference{"$ref": "#/components/schemas/TransferOwnershipRequest"},
              required: true
            ),
            responses: %{200 => resp("Transferred", "CircleResponse"),
                         400 => resp("target_not_active_member", "ErrorResponse"),
                         403 => resp("forbidden", "ErrorResponse"),
                         401 => resp("Unauthorized", "ErrorResponse")}
          }
        },

        # ── CIRCLES: NEW — mute member ─────────────────────────────────
        "/api/v1/circles/{circle_id}/members/{member_did}/mute" => %OpenApiSpex.PathItem{
          post: %OpenApiSpex.Operation{
            summary: "Mute Member", tags: ["Circles"], operationId: "mute_circle_member",
            description: "Owner/admin only. Sets the target member's role " <>
                         "to restricted (can still receive messages and " <>
                         "stay in the circle, loses send_message). " <>
                         "Broadcasts member_muted on the circle channel.",
            security: [%{"BearerAuth" => []}],
            parameters: [
              %OpenApiSpex.Parameter{name: :circle_id, in: :path, required: true, schema: %Schema{type: :string}},
              %OpenApiSpex.Parameter{name: :member_did, in: :path, required: true, schema: %Schema{type: :string}}
            ],
            responses: %{200 => resp("Muted", "MemberResponse"),
                         403 => resp("forbidden", "ErrorResponse"),
                         401 => resp("Unauthorized", "ErrorResponse")}
          }
        },

        "/api/v1/circles/{circle_id}/messages" => %OpenApiSpex.PathItem{
          post: %OpenApiSpex.Operation{
            summary: "Send Group Message", tags: ["Circles"], operationId: "send_circle_message",
            description: "Send a message to all active circle members — " <>
                         "fans out the same way sync_activity delivers to " <>
                         "a single recipient. Appears via GET " <>
                         "/api/v1/social/sync/inbox for every member.",
            security: [%{"BearerAuth" => []}],
            parameters: [
              %OpenApiSpex.Parameter{name: :circle_id, in: :path, required: true, schema: %Schema{type: :string}}
            ],
            requestBody: OpenApiSpex.Operation.request_body(
              "Request body", "application/json",
              %Reference{"$ref": "#/components/schemas/SendCircleMessageRequest"},
              required: true
            ),
            responses: %{200 => resp("Synced", "SendCircleMessageResponse"),
                         403 => resp("forbidden", "ErrorResponse"),
                         404 => resp("circle_not_found", "ErrorResponse"),
                         401 => resp("Unauthorized", "ErrorResponse")}
          }
        },

        # ── CIRCLES: NEW — delete a message ────────────────────────────
        "/api/v1/circles/{circle_id}/messages/{message_id}" => %OpenApiSpex.PathItem{
          delete: %OpenApiSpex.Operation{
            summary: "Delete Own Circle Message", tags: ["Circles"], operationId: "delete_circle_message",
            description: "Soft-deletes a group message from the sender's " <>
                         "own outbox AND from every current member's " <>
                         "inbox copy — including the sender's own " <>
                         "self-delivered inbox copy (group messages are " <>
                         "delivered to every member, sender included). " <>
                         "Broadcasts message_deleted on the circle channel.",
            security: [%{"BearerAuth" => []}],
            parameters: [
              %OpenApiSpex.Parameter{name: :circle_id, in: :path, required: true, schema: %Schema{type: :string}},
              %OpenApiSpex.Parameter{name: :message_id, in: :path, required: true, schema: %Schema{type: :string}}
            ],
            responses: %{200 => resp("Deleted", "OkResponse"),
                         401 => resp("Unauthorized", "ErrorResponse"),
                         404 => resp("Not found", "ErrorResponse")}
          }
        },

        # ── CIRCLES: NEW — pin / unpin a message ───────────────────────
        "/api/v1/circles/{circle_id}/messages/{message_id}/pin" => %OpenApiSpex.PathItem{
          post: %OpenApiSpex.Operation{
            summary: "Pin Message", tags: ["Circles"], operationId: "pin_circle_message",
            description: "Any active owner/admin/member can pin (not " <>
                         "audience or restricted). Adds a row to the " <>
                         "circle's own circle_pins table (lives in the " <>
                         "owner's folder) — visible to all members " <>
                         "without exposing anyone's private inbox. " <>
                         "Broadcasts message_pinned on the circle channel.",
            security: [%{"BearerAuth" => []}],
            parameters: [
              %OpenApiSpex.Parameter{name: :circle_id, in: :path, required: true, schema: %Schema{type: :string}},
              %OpenApiSpex.Parameter{name: :message_id, in: :path, required: true, schema: %Schema{type: :string}}
            ],
            responses: %{200 => resp("Pinned", "OkResponse"),
                         403 => resp("forbidden", "ErrorResponse"),
                         401 => resp("Unauthorized", "ErrorResponse")}
          },
          delete: %OpenApiSpex.Operation{
            summary: "Unpin Message", tags: ["Circles"], operationId: "unpin_circle_message",
            description: "Owner/admin can unpin any pinned message; a " <>
                         "plain member can only unpin a message they " <>
                         "themselves pinned. Broadcasts message_unpinned " <>
                         "on the circle channel.",
            security: [%{"BearerAuth" => []}],
            parameters: [
              %OpenApiSpex.Parameter{name: :circle_id, in: :path, required: true, schema: %Schema{type: :string}},
              %OpenApiSpex.Parameter{name: :message_id, in: :path, required: true, schema: %Schema{type: :string}}
            ],
            responses: %{200 => resp("Unpinned", "OkResponse"),
                         403 => resp("forbidden", "ErrorResponse"),
                         401 => resp("Unauthorized", "ErrorResponse"),
                         404 => resp("Not found", "ErrorResponse")}
          }
        },

        # ── CIRCLES: NEW — list current pins ───────────────────────────
        "/api/v1/circles/{circle_id}/pins" => %OpenApiSpex.PathItem{
          get: %OpenApiSpex.Operation{
            summary: "List Pinned Messages", tags: ["Circles"], operationId: "list_circle_pins",
            description: "Returns every currently-pinned message for the " <>
                         "circle (status != unpinned). Meant for a client " <>
                         "to call once on load to seed the pinned banner, " <>
                         "before relying on the live message_pinned / " <>
                         "message_unpinned broadcasts for updates.",
            security: [%{"BearerAuth" => []}],
            parameters: [
              %OpenApiSpex.Parameter{name: :circle_id, in: :path, required: true, schema: %Schema{type: :string}}
            ],
            responses: %{200 => resp("OK", "PinsResponse"),
                         401 => resp("Unauthorized", "ErrorResponse")}
          }
        }
      },
      components: %Components{
        schemas: %{
          # Auth
          "RegisterRequest"         => register_request_schema(),
          "RegisterResponse"        => register_response_schema(),
          "VerifyEmailRequest"      => verify_email_request_schema(),
          "ResendOtpRequest"        => resend_otp_request_schema(),
          "ForgotPasswordRequest"   => forgot_password_request_schema(),
          "ResetPasswordRequest"    => reset_password_request_schema(),
          "LoginRequest"            => login_request_schema(),
          "LoginResponse"           => login_response_schema(),
          "LogoutRequest"           => logout_request_schema(),
          "AccountResponse"         => account_response_schema(),
          "SessionsResponse"        => sessions_response_schema(),
          "OkResponse"              => ok_response_schema(),

          # Files
          "UploadBlobResponse"   => upload_blob_response_schema(),
          "SyncRecordRequest"    => sync_record_request_schema(),
          "SyncRecordResponse"   => sync_record_response_schema(),
        #  "ListRemoteResponse"   => list_remote_response_schema(),
        # "ListCasMetaResponse"  => list_cas_meta_response_schema(),
          "ListPendingResponse"  => list_pending_response_schema(),
          "MarkSyncedRequest"    => mark_synced_request_schema(),
          "MarkSyncedResponse"   => mark_synced_response_schema(),

          # Social
          "SyncActivityRequest"  => sync_activity_request_schema(),
          "SyncActivityResponse" => sync_activity_response_schema(),
          "ListInboxResponse"    => list_inbox_response_schema(),
          "ListOutboxResponse"   => list_outbox_response_schema(),
          "SaveToVaultRequest"   => save_to_vault_request_schema(),
          "SaveToVaultResponse"  => save_to_vault_response_schema(),

          # Circles
          "CreateCircleRequest"       => create_circle_request_schema(),
          "CircleResponse"            => circle_response_schema(),
          "JoinCircleRequest"         => join_circle_request_schema(),
          "JoinCircleResponse"        => join_circle_response_schema(),
          "MyCirclesResponse"         => my_circles_response_schema(),
          "MembersResponse"           => members_response_schema(),
          "PendingResponse"           => pending_response_schema(),
          "MemberDidRequest"          => member_did_request_schema(),
          "MemberResponse"            => member_response_schema(),
          "SendCircleMessageRequest"  => send_circle_message_request_schema(),
          "SendCircleMessageResponse" => send_circle_message_response_schema(),
          "TransferOwnershipRequest"  => transfer_ownership_request_schema(),
          "PinsResponse"               => pins_response_schema(),

          # Shared
          "ErrorResponse"        => error_response_schema()
        },
        securitySchemes: %{
          "BearerAuth" => %OpenApiSpex.SecurityScheme{
            type: "http", scheme: "bearer",
            description: "Signed access token from POST /api/v1/oauth/token. " <>
                         "Contains the DID (HMAC-signed via Phoenix.Token) — " <>
                         "verification is pure computation, no DB lookup."
          }
        }
      }
    }
  end

  # ===========================================================================
  # Schemas — Auth
  # ===========================================================================

  defp register_request_schema do
    %Schema{
      type: :object, title: "RegisterRequest",
      required: [:nickname, :password],
      properties: %{
        nickname: %Schema{type: :string, minLength: 1, maxLength: 30, example: "alice"},
        password: %Schema{type: :string, minLength: 6, example: "hunter22"},
        email:    %Schema{type: :string, format: :email, example: "alice@example.com"},
        name:     %Schema{type: :string, nullable: true},
        bio:      %Schema{type: :string, nullable: true}
      }
    }
  end

  defp register_response_schema do
    %Schema{
      type: :object, title: "RegisterResponse",
      properties: %{
        message:   %Schema{type: :string},
        did:       %Schema{type: :string, example: "did:przma:alice"},
        nickname:  %Schema{type: :string},
        next_step: %Schema{type: :string}
      }
    }
  end

  defp verify_email_request_schema do
    %Schema{
      type: :object, title: "VerifyEmailRequest",
      required: [:nickname, :code],
      properties: %{
        nickname: %Schema{type: :string, example: "alice"},
        code:     %Schema{type: :string, example: "482913"}
      }
    }
  end

  defp resend_otp_request_schema do
    %Schema{
      type: :object, title: "ResendOtpRequest",
      required: [:nickname],
      properties: %{nickname: %Schema{type: :string, example: "alice"}}
    }
  end

  defp forgot_password_request_schema do
    %Schema{
      type: :object, title: "ForgotPasswordRequest",
      required: [:nickname, :email],
      properties: %{
        nickname: %Schema{type: :string, example: "alice"},
        email:    %Schema{type: :string, format: :email, example: "alice@example.com"}
      }
    }
  end

  defp reset_password_request_schema do
    %Schema{
      type: :object, title: "ResetPasswordRequest",
      required: [:nickname, :token, :password, :password_confirmation],
      properties: %{
        nickname:              %Schema{type: :string, example: "alice"},
        token:                 %Schema{type: :string},
        password:              %Schema{type: :string, minLength: 6},
        password_confirmation: %Schema{type: :string, minLength: 6}
      }
    }
  end

  defp login_request_schema do
    %Schema{
      type: :object, title: "LoginRequest",
      required: [:grant_type, :username, :password],
      properties: %{
        grant_type: %Schema{type: :string, enum: ["password"], example: "password"},
        username:   %Schema{type: :string, example: "alice"},
        password:   %Schema{type: :string, example: "hunter22"}
      }
    }
  end

  defp login_response_schema do
    %Schema{
      type: :object, title: "LoginResponse",
      properties: %{
        access_token: %Schema{type: :string},
        token_type:   %Schema{type: :string, example: "Bearer"},
        expires_in:   %Schema{type: :integer, example: 86_400},
        did:          %Schema{type: :string, example: "did:przma:alice"},
        me:           %Schema{type: :string, example: "alice"},
        is_verified:  %Schema{type: :boolean}
      }
    }
  end

  defp logout_request_schema do
    %Schema{
      type: :object, title: "LogoutRequest",
      properties: %{session_id: %Schema{type: :string, nullable: true}}
    }
  end

  defp account_response_schema do
    %Schema{
      type: :object, title: "AccountResponse",
      properties: %{
        did:          %Schema{type: :string},
        username:     %Schema{type: :string},
        display_name: %Schema{type: :string},
        email:        %Schema{type: :string, nullable: true},
        bio:          %Schema{type: :string},
        avatar:       %Schema{type: :string},
        is_verified:  %Schema{type: :boolean},
        is_active:    %Schema{type: :boolean},
        is_admin:     %Schema{type: :boolean},
        is_moderator: %Schema{type: :boolean},
        created_at:   %Schema{type: :integer}
      }
    }
  end

  defp sessions_response_schema do
    %Schema{
      type: :object, title: "SessionsResponse",
      properties: %{
        sessions: %Schema{type: :array, items: %Schema{type: :object, additionalProperties: true}}
      }
    }
  end

  defp ok_response_schema do
    %Schema{
      type: :object, title: "OkResponse",
      properties: %{
        ok:        %Schema{type: :boolean, nullable: true},
        message:   %Schema{type: :string},
        status:    %Schema{type: :string, nullable: true},
        next_step: %Schema{type: :string, nullable: true},
        note:      %Schema{type: :string, nullable: true}
      }
    }
  end

  # ===========================================================================
  # Schemas — Files
  # ===========================================================================

  defp upload_blob_response_schema do
    %Schema{
      type: :object, title: "UploadBlobResponse",
      properties: %{
        cas_hash:   %Schema{type: :string},
        cas_uri:    %Schema{type: :string},
        status:     %Schema{type: :string, example: "stored"},
        size_bytes: %Schema{type: :integer},
        ref_count:  %Schema{type: :integer}
      }
    }
  end

  defp sync_record_request_schema do
    %Schema{
      type: :object, title: "SyncRecordRequest",
      required: [:did, :id],
      properties: %{
        did:   %Schema{type: :string, example: "did:example:alice"},
        id:    %Schema{type: :string, example: "file_001"},
        name:  %Schema{type: :string, example: "report.pdf"},
        space: %Schema{type: :string, enum: ["core", "commons", "circle"], default: "core"}
      }
    }
  end

  defp sync_record_response_schema do
    %Schema{
      type: :object, title: "SyncRecordResponse",
      properties: %{
        file_id: %Schema{type: :string},
        status:  %Schema{type: :string, example: "synced"},
        version: %Schema{type: :integer}
      }
    }
  end

  #defp list_remote_response_schema do
   # %Schema{
    #  type: :object, title: "ListRemoteResponse",
     # properties: %{
      #  files: %Schema{type: :array, items: %Schema{type: :object, additionalProperties: true}},
       # space: %Schema{type: :string},
        #count: %Schema{type: :integer}
      #}
    #}
  #end

  #defp list_cas_meta_response_schema do
   # %Schema{
    #  type: :object, title: "ListCasMetaResponse",
     # properties: %{
      #  cas_meta: %Schema{type: :array, items: %Schema{type: :object, additionalProperties: true}},
       # count:    %Schema{type: :integer}
     # }
    #}
  #end

  defp list_pending_response_schema do
    %Schema{
      type: :object, title: "ListPendingResponse",
      properties: %{
        pending_syncs: %Schema{type: :array, items: %Schema{type: :object, additionalProperties: true}},
        count:         %Schema{type: :integer}
      }
    }
  end

  defp mark_synced_request_schema do
    %Schema{
      type: :object, title: "MarkSyncedRequest",
      required: [:file_id, :space],
      properties: %{
        file_id: %Schema{type: :string},
        space:   %Schema{type: :string, default: "core"}
      }
    }
  end

  defp mark_synced_response_schema do
    %Schema{
      type: :object, title: "MarkSyncedResponse",
      properties: %{
        file_id: %Schema{type: :string},
        status:  %Schema{type: :string, example: "synced"}
      }
    }
  end

  # ===========================================================================
  # Schemas — Social
  # ===========================================================================

  defp sync_activity_request_schema do
    %Schema{
      type: :object, title: "SyncActivityRequest",
      required: [:id, :did, :actor, :activity_type, :space, :to, :raw_json, :user_type],
      properties: %{
        id:            %Schema{type: :string, example: "act_001"},
        did:           %Schema{type: :string, example: "did:example:alice"},
        actor:         %Schema{type: :string, example: "did:example:alice"},
        activity_type: %Schema{type: :string, example: "Create"},
        space:         %Schema{type: :string, example: "circle"},
        user_type: %Schema{
          type: :string, enum: ["person", "agent"],
          description: "Whether the actor performing this activity is a " <>
                       "human person or an automated agent.",
          example: "person"
        },
        to: %Schema{
          oneOf: [
            %Schema{type: :array, items: %Schema{type: :string}},
            %Schema{type: :string}
          ],
          description: "One or more recipient DIDs. A JSON array is " <>
                       "preferred; a bare string is also accepted and " <>
                       "wrapped server-side via List.wrap/1.",
          example: ["did:example:bob"]
        },
        object_cas: %Schema{
          type: :string, nullable: true,
          description: "BLAKE3 hash of a CAS object (from " <>
                       "POST /api/v1/files/sync/blob) this activity " <>
                       "points to. Required for the activity to later be " <>
                       "readable via GET .../view/{id} or POST .../save.",
          example: "deadbeef00000000000000000000000000000000000000000000000000beef"
        },
        raw_json: %Schema{type: :string, example: ~s({"type":"Note"})}
      }
    }
  end

  defp sync_activity_response_schema do
    %Schema{
      type: :object, title: "SyncActivityResponse",
      properties: %{
        id:        %Schema{type: :string},
        status:    %Schema{type: :string, example: "synced"},
        version:   %Schema{type: :integer},
        user_type: %Schema{type: :string, enum: ["person", "agent"], example: "person"}
      }
    }
  end

  defp list_inbox_response_schema do
    %Schema{
      type: :object, title: "ListInboxResponse",
      properties: %{
        activities: %Schema{type: :array, items: %Schema{type: :object, additionalProperties: true}},
        count:      %Schema{type: :integer}
      }
    }
  end

  defp list_outbox_response_schema do
    %Schema{
      type: :object, title: "ListOutboxResponse",
      properties: %{
        activities: %Schema{type: :array, items: %Schema{type: :object, additionalProperties: true}},
        count:      %Schema{type: :integer}
      }
    }
  end

  defp save_to_vault_request_schema do
    %Schema{
      type: :object, title: "SaveToVaultRequest",
      required: [:activity_id],
      properties: %{
        activity_id: %Schema{type: :string, example: "act_001"}
      }
    }
  end

  defp save_to_vault_response_schema do
    %Schema{
      type: :object, title: "SaveToVaultResponse",
      properties: %{
        status:  %Schema{type: :string, example: "saved"},
        new_hash: %Schema{type: :string},
        cas_uri: %Schema{type: :string}
      }
    }
  end

  # ===========================================================================
  # Schemas — Circles
  # ===========================================================================

  defp create_circle_request_schema do
    %Schema{
      type: :object, title: "CreateCircleRequest",
      required: [:name],
      properties: %{
        name: %Schema{type: :string, example: "College Friends"},
        join_approval_required: %Schema{type: :boolean, default: true},
        max_members: %Schema{type: :integer, default: 256}
      }
    }
  end

  defp circle_response_schema do
    %Schema{
      type: :object, title: "CircleResponse",
      properties: %{
        id: %Schema{type: :string},
        owner_did: %Schema{type: :string},
        name: %Schema{type: :string},
        member_count: %Schema{type: :integer},
        audience_count: %Schema{type: :integer},
        invite_code: %Schema{type: :string},
        invite_link: %Schema{type: :string},
        join_approval_required: %Schema{type: :boolean},
        max_members: %Schema{type: :integer},
        status: %Schema{type: :string, enum: ["active", "deleted", "transferred"], nullable: true},
        created_at: %Schema{type: :integer},
        updated_at: %Schema{type: :integer}
      }
    }
  end

  defp join_circle_request_schema do
    %Schema{
      type: :object, title: "JoinCircleRequest",
      required: [:invite_code],
      properties: %{invite_code: %Schema{type: :string, example: "x7Kp2M"}}
    }
  end

  defp join_circle_response_schema do
    %Schema{
      type: :object, title: "JoinCircleResponse",
      properties: %{
        status: %Schema{type: :string, enum: ["active", "pending"]},
        circle_id: %Schema{type: :string},
        role: %Schema{type: :string, enum: ["member", "audience"], nullable: true}
      }
    }
  end

  defp my_circles_response_schema do
    %Schema{
      type: :object, title: "MyCirclesResponse",
      properties: %{
        circles: %Schema{type: :array, items: %Schema{type: :object, additionalProperties: true}},
        count: %Schema{type: :integer}
      }
    }
  end

  defp members_response_schema do
    %Schema{
      type: :object, title: "MembersResponse",
      properties: %{
        members: %Schema{type: :array, items: %Schema{type: :object, additionalProperties: true}},
        count: %Schema{type: :integer}
      }
    }
  end

  defp pending_response_schema do
    %Schema{
      type: :object, title: "PendingResponse",
      properties: %{
        pending: %Schema{type: :array, items: %Schema{type: :object, additionalProperties: true}},
        count:   %Schema{type: :integer}
      }
    }
  end

  defp member_did_request_schema do
    %Schema{
      type: :object, title: "MemberDidRequest",
      required: [:member_did],
      properties: %{member_did: %Schema{type: :string, example: "did:przma:teju"}}
    }
  end

  defp member_response_schema do
    %Schema{
      type: :object, title: "MemberResponse",
      properties: %{
        id: %Schema{type: :string},
        circle_id: %Schema{type: :string},
        member_did: %Schema{type: :string},
        owner_did: %Schema{type: :string},
        role: %Schema{type: :string, enum: ["owner", "admin", "member", "restricted", "audience"]},
        status: %Schema{type: :string, enum: ["pending", "active", "removed", "left"]},
        joined_at: %Schema{type: :integer},
        updated_at: %Schema{type: :integer}
      }
    }
  end

  defp send_circle_message_request_schema do
    %Schema{
      type: :object, title: "SendCircleMessageRequest",
      required: [:raw_json],
      properties: %{
        id: %Schema{type: :string, nullable: true},
        raw_json: %Schema{type: :string, example: ~s({"type":"Note","content":"hi all"})}
      }
    }
  end

  defp send_circle_message_response_schema do
    %Schema{
      type: :object, title: "SendCircleMessageResponse",
      properties: %{
        id: %Schema{type: :string},
        status: %Schema{type: :string, example: "synced"},
        version: %Schema{type: :integer}
      }
    }
  end

  defp transfer_ownership_request_schema do
    %Schema{
      type: :object, title: "TransferOwnershipRequest",
      required: [:new_owner_did],
      properties: %{
        new_owner_did: %Schema{type: :string, example: "did:przma:teju"}
      }
    }
  end

  defp pins_response_schema do
    %Schema{
      type: :object, title: "PinsResponse",
      properties: %{
        pins: %Schema{type: :array, items: %Schema{type: :object, additionalProperties: true}},
        count: %Schema{type: :integer}
      }
    }
  end

  # ===========================================================================
  # Shared schema
  # ===========================================================================

  defp error_response_schema do
    %Schema{
      type: :object, title: "ErrorResponse",
      required: [:error],
      properties: %{
        error: %Schema{type: :string, example: "did_mismatch"}
      }
    }
  end

  # ===========================================================================
  # Helper builders
  # ===========================================================================

  defp op_files(summary, op_id, desc, responses) do
    %OpenApiSpex.Operation{
      summary: summary, tags: ["Files"], operationId: op_id,
      description: desc,
      security: [%{"BearerAuth" => []}],
      responses: responses
    }
  end

  defp op_files_body(summary, op_id, desc, schema_name, responses) do
    %OpenApiSpex.Operation{
      summary: summary, tags: ["Files"], operationId: op_id,
      description: desc,
      security: [%{"BearerAuth" => []}],
      requestBody: OpenApiSpex.Operation.request_body(
        "Request body", "application/json",
        %Reference{"$ref": "#/components/schemas/#{schema_name}"},
        required: true
      ),
      responses: responses
    }
  end

  defp op_social_body(summary, op_id, desc, schema_name, responses) do
    %OpenApiSpex.Operation{
      summary: summary, tags: ["Social"], operationId: op_id,
      description: desc, security: [%{"BearerAuth" => []}],
      requestBody: OpenApiSpex.Operation.request_body(
        "Request body", "application/json",
        %Reference{"$ref": "#/components/schemas/#{schema_name}"},
        required: true
      ),
      responses: responses
    }
  end

  defp op_auth_body(summary, op_id, desc, schema_name, responses) do
    %OpenApiSpex.Operation{
      summary: summary, tags: ["Auth"], operationId: op_id,
      description: desc,
      requestBody: OpenApiSpex.Operation.request_body(
        "Request body", "application/json",
        %Reference{"$ref": "#/components/schemas/#{schema_name}"},
        required: true
      ),
      responses: responses
    }
  end

  defp op_circles_body(summary, op_id, desc, schema_name, responses) do
    %OpenApiSpex.Operation{
      summary: summary, tags: ["Circles"], operationId: op_id,
      description: desc, security: [%{"BearerAuth" => []}],
      requestBody: OpenApiSpex.Operation.request_body(
        "Request body", "application/json",
        %Reference{"$ref": "#/components/schemas/#{schema_name}"},
        required: true
      ),
      responses: responses
    }
  end

  defp op_circles_body_with_path(summary, op_id, desc, path_param, schema_name, responses) do
    %OpenApiSpex.Operation{
      summary: summary, tags: ["Circles"], operationId: op_id,
      description: desc, security: [%{"BearerAuth" => []}],
      parameters: [
        %OpenApiSpex.Parameter{name: path_param, in: :path, required: true, schema: %Schema{type: :string}}
      ],
      requestBody: OpenApiSpex.Operation.request_body(
        "Request body", "application/json",
        %Reference{"$ref": "#/components/schemas/#{schema_name}"},
        required: true
      ),
      responses: responses
    }
  end

  defp resp(desc, schema_name) do
    OpenApiSpex.Operation.response(desc, "application/json",
      %Reference{"$ref": "#/components/schemas/#{schema_name}"}
    )
  end
end