defmodule PRZMAWeb.ApiSpec do
  @moduledoc """
  OpenAPI/Swagger specification for this project's real endpoints.

  Same OpenApiSpex pattern as the real, already-working project
  (phoenix-chat-app-circle's lib/przma_web/api_spec.ex) — ported here
  rather than copied wholesale, since that file documents a much
  larger API (files/social/circles/contacts) that doesn't exist in
  this project. Scope here: registration + profile only.

  Routes live in lib/przma_web/router.ex — /api/v1/registration/complete
  and /api/v1/profile (POST/GET/PATCH). All 4 require Bearer auth via
  KeycloakAuth (JWT verified against Keycloak's JWKS, NOT Phoenix.Token
  like the real project's DIDAuth — different auth mechanism, same
  security scheme shape for Swagger's purposes).
  """

  alias OpenApiSpex.{Components, Info, OpenApi, Reference, Schema, Server}

  @behaviour OpenApi

  @impl OpenApi
  def spec do
    %OpenApi{
      info: %Info{
        title: "PRZMA Backend API — Registration, Profile & Search",
        version: "0.1.0",
        description: """
        Keycloak-authenticated registration and profile endpoints.

        ## Auth
        Every endpoint below requires a Bearer JWT issued by Keycloak
        (realm `przma`) — get one first via Keycloak's own
        `/realms/przma/protocol/openid-connect/token` endpoint (not
        part of this API; that's Keycloak's built-in login endpoint),
        then use the returned `access_token` here.

        ## Registration
        `POST /registration/complete` (safe to repeat) writes the user's
        profile to `{did}/vault/private/profile.lance` in S3 and provisions
        the Lance `_meta` tables for `public` and `professional` exactly as
        before.

        ## Storage
        All documents (profile, files, chat, circles, contacts) are LanceDB
        tables in S3: `s3://perkeep/{did}/{namespace}/{space}/{table}.lance`.
        Every read/write goes through the pzdb URI, NamespacePolicy and
        PzdbAuthorization. Public-file CAS metadata is also copied to
        Postgres (unchanged).

        The same operations are available in GraphQL at `/api/graphql`
        (`completeRegistration`, `profile`, `updateProfile`).

        ## Search
        Meaning-based (vector) and keyword search over the logged-in user's
        OWN content. Pieces of text are embedded inside the Rust NIF and
        stored in `s3://perkeep/{did}/search/{space}/chunks.lance`.
        Order to try it: `POST /search/index` (save some text) →
        `GET /search` (ask in other words) → `GET /search/stats`.
        """
      },
      servers: [
        %Server{url: "http://172.235.18.126:4201", description: "Local dev (mix phx.server)"}
      ],
      paths: %{
        "/api/v1/registration/complete" => %OpenApiSpex.PathItem{
          post: %OpenApiSpex.Operation{
            summary: "Complete Registration", tags: ["Registration"], operationId: "complete_registration",
            description: "Call once, right after Keycloak registration/first " <>
                         "login completes. Provisions vault (writes the " <>
                         "profile row) + public + professional (empty " <>
                         "_meta marker rows). Do NOT call on every login.",
            security: [%{"BearerAuth" => []}],
            requestBody: OpenApiSpex.Operation.request_body(
              "Optional nickname override", "application/json",
              %Reference{"$ref": "#/components/schemas/RegistrationRequest"},
              required: false
            ),
            responses: %{
              200 => resp("All 3 spaces provisioned", "RegistrationResponse"),
              401 => resp("Missing or invalid Bearer token", "ErrorResponse"),
              422 => resp("Provisioning failed", "ErrorResponse")
            }
          }
        },

        "/api/v1/profile" => %OpenApiSpex.PathItem{
          post: %OpenApiSpex.Operation{
            summary: "Create Profile", tags: ["Profile"], operationId: "create_profile",
            description: "Writes the profile row into the vault (private) space.",
            security: [%{"BearerAuth" => []}],
            requestBody: OpenApiSpex.Operation.request_body(
              "Profile fields", "application/json",
              %Reference{"$ref": "#/components/schemas/ProfileAttrs"},
              required: true
            ),
            responses: %{
              200 => resp("Created", "StatusResponse"),
              401 => resp("Missing or invalid Bearer token", "ErrorResponse"),
              422 => resp("Write failed", "ErrorResponse")
            }
          },
          get: %OpenApiSpex.Operation{
            summary: "Get Profile", tags: ["Profile"], operationId: "get_profile",
            description: "Fetches the caller's own profile. Internally goes " <>
                         "through a filtered pzdb_read_many query (did = " <>
                         "caller's did, limit 1) rather than a direct " <>
                         "single-record read — the real NIF's pzdb_read " <>
                         "is a stub that always returns null.",
            security: [%{"BearerAuth" => []}],
            responses: %{
              200 => resp("Profile found", "ProfileResponse"),
              401 => resp("Missing or invalid Bearer token", "ErrorResponse"),
              404 => resp("No profile yet", "ErrorResponse")
            }
          },
          patch: %OpenApiSpex.Operation{
            summary: "Update Profile", tags: ["Profile"], operationId: "update_profile",
            description: "Overwrites the caller's own profile row (real " <>
                         "upsert — delete-by-id then add — not a duplicate " <>
                         "insert).",
            security: [%{"BearerAuth" => []}],
            requestBody: OpenApiSpex.Operation.request_body(
              "Profile fields to change", "application/json",
              %Reference{"$ref": "#/components/schemas/ProfileAttrs"},
              required: true
            ),
            responses: %{
              200 => resp("Updated", "StatusResponse"),
              401 => resp("Missing or invalid Bearer token", "ErrorResponse"),
              422 => resp("Write failed", "ErrorResponse")
            }
          }
        },

        "/api/v1/search/index" => %OpenApiSpex.PathItem{
          post: %OpenApiSpex.Operation{
            summary: "Index Text", tags: ["Search"], operationId: "search_index",
            description: "Splits the text into pieces (~200 words), embeds them and saves " <>
                         "them in the caller's own search table. Sending the same " <>
                         "source_id again replaces its old pieces.",
            security: [%{"BearerAuth" => []}],
            requestBody: OpenApiSpex.Operation.request_body(
              "Text to make searchable", "application/json",
              %Reference{"$ref": "#/components/schemas/SearchIndexRequest"},
              required: true
            ),
            responses: %{
              200 => resp("Indexed", "SearchIndexResponse"),
              400 => resp("text is required", "ErrorResponse"),
              401 => resp("Missing or invalid Bearer token", "ErrorResponse"),
              422 => resp("Indexing failed", "ErrorResponse")
            }
          }
        },

        "/api/v1/search" => %OpenApiSpex.PathItem{
          get: %OpenApiSpex.Operation{
            summary: "Search", tags: ["Search"], operationId: "search",
            description: "Searches ONLY the caller's own pieces. vector = by meaning " <>
                         "(words may differ), keyword = words in the text, hybrid = both. " <>
                         "Higher score = better match.",
            security: [%{"BearerAuth" => []}],
            parameters: [
              %OpenApiSpex.Parameter{name: :q, in: :query, required: true,
                description: "The question / search text",
                schema: %Schema{type: :string}, example: "where did we stay in the hill station?"},
              %OpenApiSpex.Parameter{name: :mode, in: :query, required: false,
                description: "vector (default), keyword or hybrid",
                schema: %Schema{type: :string, enum: ["vector", "keyword", "hybrid"], default: "vector"}},
              %OpenApiSpex.Parameter{name: :limit, in: :query, required: false,
                description: "Max results (1-50)",
                schema: %Schema{type: :integer, default: 10, minimum: 1, maximum: 50}},
              %OpenApiSpex.Parameter{name: :space, in: :query, required: false,
                schema: %Schema{type: :string, enum: ["private", "personal", "public"], default: "private"}},
              %OpenApiSpex.Parameter{name: :source_type, in: :query, required: false,
                description: "Only this kind of source, e.g. doc, file, chat",
                schema: %Schema{type: :string}}
            ],
            responses: %{
              200 => resp("Results", "SearchResponse"),
              400 => resp("q is required", "ErrorResponse"),
              401 => resp("Missing or invalid Bearer token", "ErrorResponse"),
              422 => resp("Search failed", "ErrorResponse")
            }
          }
        },

        "/api/v1/search/stats" => %OpenApiSpex.PathItem{
          get: %OpenApiSpex.Operation{
            summary: "Search Table Stats", tags: ["Search"], operationId: "search_stats",
            description: "Rows, version, vector size and indexes of the caller's search table.",
            security: [%{"BearerAuth" => []}],
            parameters: [
              %OpenApiSpex.Parameter{name: :space, in: :query, required: false,
                schema: %Schema{type: :string, enum: ["private", "personal", "public"], default: "private"}}
            ],
            responses: %{
              200 => resp("Stats", "SearchStatsResponse"),
              401 => resp("Missing or invalid Bearer token", "ErrorResponse")
            }
          }
        }
      },
      components: %Components{
        schemas: %{
          "RegistrationRequest"  => registration_request_schema(),
          "RegistrationResponse" => registration_response_schema(),
          "ProfileAttrs"         => profile_attrs_schema(),
          "ProfileResponse"      => profile_response_schema(),
          "StatusResponse"       => status_response_schema(),
          "ErrorResponse"        => error_response_schema(),
          "SearchIndexRequest"   => search_index_request_schema(),
          "SearchIndexResponse"  => search_index_response_schema(),
          "SearchResponse"       => search_response_schema(),
          "SearchStatsResponse"  => search_stats_response_schema()
        },
        securitySchemes: %{
          "BearerAuth" => %OpenApiSpex.SecurityScheme{
            type: "http", scheme: "bearer",
            description: "Access token from Keycloak's own " <>
                         "/realms/przma/protocol/openid-connect/token " <>
                         "endpoint. Verified locally via JWKS " <>
                         "(Przma.Auth.JwksCache) — not a Phoenix.Token " <>
                         "like the real project's DIDAuth."
          }
        }
      }
    }
  end

  # ===========================================================================
  # Schemas
  # ===========================================================================

  defp registration_request_schema do
    %Schema{
      type: :object, title: "RegistrationRequest",
      properties: %{
        nickname: %Schema{
          type: :string, nullable: true,
          description: "Optional — defaults to the Keycloak preferred_username claim if omitted.",
          example: "keerthi"
        }
      }
    }
  end

  defp registration_response_schema do
    %Schema{
      type: :object, title: "RegistrationResponse",
      properties: %{
        status: %Schema{type: :string, example: "registered"},
        did:    %Schema{type: :string, example: "did:przma:keerthi"},
        gid:    %Schema{type: :string, description: "tenant_uuid, from the JWT sub claim",
                         example: "b656d159-9ad8-48f8-ae32-6969237e5fcc"},
        database: %Schema{type: :string, description: "The user's S3 folder (kept for compatibility)",
                          example: "s3://perkeep/did_przma_keerthi/"},
        storage_path: %Schema{type: :string, description: "The user's S3 folder",
                              example: "s3://perkeep/did_przma_keerthi/"}
      }
    }
  end

  defp profile_attrs_schema do
    %Schema{
      type: :object, title: "ProfileAttrs",
      properties: %{
        nickname:     %Schema{type: :string, nullable: true, example: "keerthi"},
        display_name: %Schema{type: :string, nullable: true, example: "keerthi"},
        bio:          %Schema{type: :string, nullable: true, example: "Backend developer at PRZMA"},
        avatar_cid:   %Schema{type: :string, nullable: true}
      }
    }
  end

  defp profile_response_schema do
    %Schema{
      type: :object, title: "ProfileResponse",
      properties: %{
        profile: %Schema{
          type: :object,
          description: "Fields of the profile row in vault/private/profile.lance.",
          properties: %{
            did:          %Schema{type: :string, example: "did:przma:keerthi"},
            email:        %Schema{type: :string, nullable: true},
            nickname:     %Schema{type: :string, nullable: true},
            display_name: %Schema{type: :string, nullable: true},
            bio:          %Schema{type: :string, nullable: true},
            avatar_cid:   %Schema{type: :string, nullable: true},
            namespace:    %Schema{type: :string, example: "vault"},
            space:        %Schema{type: :string, example: "private"},
            pzdb_uri:     %Schema{type: :string},
            doc_ver:      %Schema{type: :integer, example: 1},
            created_at:   %Schema{type: :integer, description: "Unix microseconds"},
            updated_at:   %Schema{type: :integer, description: "Unix microseconds"}
          }
        }
      }
    }
  end

  defp status_response_schema do
    %Schema{
      type: :object, title: "StatusResponse",
      properties: %{
        status:     %Schema{type: :string, example: "created"},
        visibility: %Schema{type: :string, enum: ["private"],
                             description: "Always \"private\" — vault is the only space Profile writes to."}
      }
    }
  end

  defp error_response_schema do
    %Schema{
      type: :object, title: "ErrorResponse",
      required: [:error],
      properties: %{error: %Schema{type: :string}}
    }
  end

  defp search_index_request_schema do
    %Schema{
      type: :object, title: "SearchIndexRequest",
      required: [:text],
      properties: %{
        text:        %Schema{type: :string, example: "Family trip to Ooty: toy train, tea gardens, three nights at Sterling resort near the lake."},
        source_type: %Schema{type: :string, default: "doc", example: "doc"},
        source_id:   %Schema{type: :string, description: "Same id again = replace old pieces", example: "ooty"},
        title:       %Schema{type: :string, nullable: true, example: "Ooty trip plan"},
        space:       %Schema{type: :string, enum: ["private", "personal", "public"], default: "private"}
      }
    }
  end

  defp search_index_response_schema do
    %Schema{
      type: :object, title: "SearchIndexResponse",
      properties: %{
        source_id: %Schema{type: :string, example: "ooty"},
        chunks:    %Schema{type: :integer, description: "Pieces saved", example: 1},
        batches:   %Schema{type: :integer, example: 1},
        embed_ms:  %Schema{type: :integer, example: 3},
        write_ms:  %Schema{type: :integer, example: 950}
      }
    }
  end

  defp search_response_schema do
    %Schema{
      type: :object, title: "SearchResponse",
      properties: %{
        mode:      %Schema{type: :string, example: "vector"},
        took_ms:   %Schema{type: :integer, example: 120},
        embed_ms:  %Schema{type: :integer, nullable: true},
        search_ms: %Schema{type: :integer, nullable: true},
        results: %Schema{
          type: :array,
          items: %Schema{
            type: :object,
            properties: %{
              id:          %Schema{type: :string, example: "doc:ooty#0"},
              source_type: %Schema{type: :string, example: "doc"},
              source_id:   %Schema{type: :string, example: "ooty"},
              title:       %Schema{type: :string, nullable: true, example: "Ooty trip plan"},
              chunk_index: %Schema{type: :integer, example: 0},
              text:        %Schema{type: :string},
              score:       %Schema{type: :number, example: 0.71}
            }
          }
        }
      }
    }
  end

  defp search_stats_response_schema do
    %Schema{
      type: :object, title: "SearchStatsResponse",
      properties: %{
        exists:  %Schema{type: :boolean},
        rows:    %Schema{type: :integer, example: 2},
        version: %Schema{type: :integer},
        dim:     %Schema{type: :integer, example: 256},
        indices: %Schema{type: :array, items: %Schema{type: :string}}
      }
    }
  end

  # ===========================================================================
  # Helper
  # ===========================================================================

  defp resp(desc, schema_name) do
    OpenApiSpex.Operation.response(desc, "application/json",
      %Reference{"$ref": "#/components/schemas/#{schema_name}"}
    )
  end
end
