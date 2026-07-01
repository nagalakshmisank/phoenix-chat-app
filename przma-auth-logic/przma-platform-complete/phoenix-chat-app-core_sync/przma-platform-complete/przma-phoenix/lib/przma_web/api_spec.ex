	defmodule PRZMAWeb.ApiSpec do
  @moduledoc """
  OpenAPI/Swagger specification for the PRZMA Platform API.

  Scope: ONLY the routes that are actually live in lib/przma_web/router.ex —
  /api/v1/files/* and /api/v1/social/*.

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
        title: "PRZMA Platform API — Files & Social",
        version: "1.0.0",
        description: """
        Live endpoints only: /api/v1/files/* and /api/v1/social/*.

        ## Auth
        - `/api/v1/files/*` — NO auth pipeline applied (`:api` only). The
          controller reads `did` / `blake3_hash` from headers
          (`x-przma-did`, `x-przma-blake3`) or from the JSON body.
        - `/api/v1/social/*` — requires `:require_did_auth`
          (`PRZMAWeb.Plugs.DIDAuth`). This is a TEST STUB plug: it accepts
          ANY `Authorization: Bearer demo-<value>` token and sets
          `conn.assigns[:did]` to `<value>` — no signature check happens.
        """
      },
      servers: [
        %Server{url: "http://172.235.18.126:4201", description: "Development"}
      ],
      paths: %{
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

        "/api/v1/social/sync/save" => %OpenApiSpex.PathItem{
          post: op_social_body("Save Activity To Vault", "save_to_vault",
            "Copy an inbox activity's object into the caller's own vault. " <>
            "Requires the activity to have a non-null object_cas field.",
            "SaveToVaultRequest",
            %{200 => resp("Saved", "SaveToVaultResponse"),
              401 => resp("Unauthorized", "ErrorResponse"),
              404 => resp("activity_not_found", "ErrorResponse")})
        }
      },
      components: %Components{
        schemas: %{
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
          "SaveToVaultRequest"   => save_to_vault_request_schema(),
          "SaveToVaultResponse"  => save_to_vault_response_schema(),

          # Shared
          "ErrorResponse"        => error_response_schema()
        },
        securitySchemes: %{
          "BearerAuth" => %OpenApiSpex.SecurityScheme{
            type: "http", scheme: "bearer",
            description: ~s(TEST STUB — any "Bearer demo-<value>" token is accepted. ) <>
                          ~s(Sets conn.assigns[:did] to <value>.)
          }
        }
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
      required: [:id, :did, :actor, :activity_type, :space, :to, :raw_json],
      properties: %{
        id:            %Schema{type: :string, example: "act_001"},
        did:           %Schema{type: :string, example: "did:example:alice"},
        actor:         %Schema{type: :string, example: "did:example:alice"},
        activity_type: %Schema{type: :string, example: "Create"},
        space:         %Schema{type: :string, example: "circle"},
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
        id:      %Schema{type: :string},
        status:  %Schema{type: :string, example: "synced"},
        version: %Schema{type: :integer}
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
      description: desc, responses: responses
    }
  end

  defp op_files_body(summary, op_id, desc, schema_name, responses) do
    %OpenApiSpex.Operation{
      summary: summary, tags: ["Files"], operationId: op_id,
      description: desc,
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

  defp resp(desc, schema_name) do
    OpenApiSpex.Operation.response(desc, "application/json",
      %Reference{"$ref": "#/components/schemas/#{schema_name}"}
    )
  end
end
