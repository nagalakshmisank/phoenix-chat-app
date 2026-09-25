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
        title: "PRZMA Backend API — Registration & Profile",
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
        `POST /registration/complete` (safe to repeat) creates the user's
        CouchDB database `przma_{did}` and the profile document
        `vault:private:profile`, and provisions the Lance `_meta` tables
        for `public` and `professional` exactly as before.

        ## Storage
        Profile: CouchDB document `vault:private:profile` (source of truth)
        in the user's own database, plus a read-only JSON mirror in S3 at
        `{did}/vault/private/profile.couch.json`. Every read/write goes
        through the pzdb URI, NamespacePolicy and PzdbAuthorization.
        Files and `_meta` still use Lance (unchanged).

        The same operations are available in GraphQL at `/api/graphql`
        (`completeRegistration`, `profile`, `updateProfile`).
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
        }
      },
      components: %Components{
        schemas: %{
          "RegistrationRequest"  => registration_request_schema(),
          "RegistrationResponse" => registration_response_schema(),
          "ProfileAttrs"         => profile_attrs_schema(),
          "ProfileResponse"      => profile_response_schema(),
          "StatusResponse"       => status_response_schema(),
          "ErrorResponse"        => error_response_schema()
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
        database: %Schema{type: :string, description: "The user's CouchDB database",
                          example: "przma_did_przma_keerthi"}
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
          description: "Fields of the CouchDB document vault:private:profile.",
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

  # ===========================================================================
  # Helper
  # ===========================================================================

  defp resp(desc, schema_name) do
    OpenApiSpex.Operation.response(desc, "application/json",
      %Reference{"$ref": "#/components/schemas/#{schema_name}"}
    )
  end
end