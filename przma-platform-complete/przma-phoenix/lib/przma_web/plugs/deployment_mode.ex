# lib/przma_web/plugs/deployment_mode.ex
#
# Plug that injects deployment mode context into the connection.
# Sets conn.assigns.deployment for downstream use by storage and auth modules.

defmodule PRZMAWeb.Plugs.DeploymentMode do
  import Plug.Conn
  alias PRZMA.Deployment.Mode

  def init(opts), do: opts

  def call(conn, _opts) do
    config = Mode.config()
    conn
    |> assign(:deployment_mode,       config.mode)
    |> assign(:deployment_is_local,   config.is_local)
    |> assign(:vault_base_path,       config.vault_base_path)
    |> assign(:instance_url,          config.instance_url)
  end
end

# ─────────────────────────────────────────────────────────────────────────────

# lib/przma_web/plugs/license_check.ex
#
# Plug that verifies license validity for Local/Own Domain modes.
# Cloud SaaS and BYOS modes check subscription status via API instead.

defmodule PRZMAWeb.Plugs.LicenseCheck do
  import Plug.Conn
  alias PRZMA.Deployment.{Mode, License}

  def init(feature), do: feature

  def call(conn, feature) do
    license = conn.assigns[:license] || Mode.config().license

    cond do
      # Cloud SaaS / BYOS — subscription API handles entitlements
      Mode.cloud?() ->
        assign(conn, :license, license)

      # Local / Own Domain — check license file
      License.valid?(license) and License.feature_available?(license, feature) ->
        assign(conn, :license, license)

      not License.valid?(license) ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(402, Jason.encode!(%{
            error:   "License required",
            message: "A valid PRZMA license is required for this deployment mode",
            details: "Run `przma license activate <your-license-key>` to activate",
          }))
        |> halt()

      not License.feature_available?(license, feature) ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(403, Jason.encode!(%{
            error:   "Feature not available",
            feature: feature,
            tier:    license[:tier],
            message: "Upgrade your PRZMA license to access this feature",
          }))
        |> halt()
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────

# lib/przma_web/controllers/deployment/deployment_controller.ex
#
# Deployment configuration REST endpoints.
# Allows users to query mode, configure BYOS, and check license.

defmodule PRZMAWeb.Deployment.DeploymentController do
  use PRZMAWeb, :controller

  alias PRZMA.Deployment.{Mode, License, BYOSCredentials}
  alias PRZMA.Calendar.NIF

  # GET /api/v1/deployment/mode
  def show_mode(conn, _params) do
    config = Mode.config()
    json(conn, %{
      mode:            config.mode,
      is_local:        config.is_local,
      is_cloud:        config.is_cloud,
      instance_url:    config.instance_url,
      encryption:      %{
        enabled:    config.encryption.enabled,
        key_source: config.encryption.key_source,
      },
      license: License.summary(config.license),
    })
  end

  # GET /api/v1/deployment/license
  def license(conn, _params) do
    license = Mode.config().license
    json(conn, License.summary(license))
  end

  # POST /api/v1/deployment/byos/register
  # Register BYOS S3 credentials for the authenticated DID
  def register_byos(conn, params) do
    did = conn.assigns.did

    required = ~w(endpoint bucket region access_key_id secret_access_key)
    if Enum.any?(required, fn k -> is_nil(params[k]) end) do
      conn |> put_status(:bad_request) |> json(%{
        error: "Required: #{Enum.join(required, ", ")}"
      })
    else
      config = %{
        endpoint:          params["endpoint"],
        bucket:            params["bucket"],
        region:            params["region"],
        access_key_id:     params["access_key_id"],
        secret_access_key: params["secret_access_key"],
      }

      case BYOSCredentials.register(did, config) do
        {:ok, creds} ->
          conn |> put_status(:created) |> json(%{
            mode:        "byos",
            bucket:      config.bucket,
            path_prefix: BYOSCredentials.path_prefix(did),
            expires_at:  creds.expires_at,
          })
        {:error, reason} ->
          conn |> put_status(:unprocessable_entity) |> json(%{error: inspect(reason)})
      end
    end
  end

  # GET /api/v1/deployment/byos/validate
  def validate_byos(conn, _params) do
    did = conn.assigns.did
    case BYOSCredentials.validate(did) do
      {:ok, :valid} ->
        json(conn, %{valid: true, message: "S3 credentials are valid"})
      {:error, :not_registered} ->
        conn |> put_status(:not_found) |> json(%{
          valid: false, error: "No BYOS credentials registered for this DID"
        })
      {:error, reason} ->
        conn |> put_status(:bad_request) |> json(%{valid: false, error: inspect(reason)})
    end
  end

  # DELETE /api/v1/deployment/byos
  def revoke_byos(conn, _params) do
    did = conn.assigns.did
    BYOSCredentials.revoke(did)
    conn |> put_status(:no_content) |> send_resp(204, "")
  end

  # GET /api/v1/deployment/storage/status
  def storage_status(conn, _params) do
    did = conn.assigns.did

    with {:ok, mode_json} <- NIF.detect_storage_mode(conn.assigns.vault_base_path, did) do
      mode = Jason.decode!(mode_json)
      json(conn, Map.merge(mode, %{
        vault_base_path: conn.assigns.vault_base_path,
        instance_url:    conn.assigns.instance_url,
        encryption_available: PRZMA.Calendar.Storage.EncryptionContext.encryption_available?(did),
      }))
    else
      _ -> conn |> put_status(:internal_server_error) |> json(%{error: "Storage status unavailable"})
    end
  end

  # POST /api/v1/deployment/encryption/setup
  # Generate and save a new master encryption key for a DID
  def setup_encryption(conn, _params) do
    did = conn.assigns.did
    alias PRZMA.Calendar.Storage.EncryptionContext

    if EncryptionContext.encryption_available?(did) do
      conn |> put_status(:conflict) |> json(%{
        error: "Encryption already configured for this DID"
      })
    else
      case EncryptionContext.generate_and_save_master_key(did) do
        {:ok, _key} ->
          conn |> put_status(:created) |> json(%{
            configured: true,
            message: "Master encryption key generated and saved",
            warning: "Keep your key file secure — data encrypted with this key cannot be recovered without it",
          })
        {:error, reason} ->
          conn |> put_status(:internal_server_error) |> json(%{error: inspect(reason)})
      end
    end
  end
end
