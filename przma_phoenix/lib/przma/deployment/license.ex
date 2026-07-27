# lib/przma/deployment/license.ex
#
# Offline license verification for Local and Own Domain deployment modes.
# Uses signed JWT with expiry — verified locally without network.
# Cloud SaaS and BYOS use subscription API instead.

defmodule PRZMA.Deployment.License do
  require Logger

  @license_file_paths [
    "/etc/przma/license.jwt",
    "~/.config/przma/license.jwt",
    "./przma-license.jwt",
  ]

  # Public key for signature verification (PRZMA signs all licenses)
  # Phase 5: real Ed25519 public key — placeholder for Phase 5 final
  @przma_public_key_hex "0000000000000000000000000000000000000000000000000000000000000000"

  # ── PUBLIC API ──────────────────────────────────────────────────────────

  @doc "Load and verify the license for local/own-domain mode"
  def load do
    mode = System.get_env("PRZMA_MODE", "cloud_saas")

    if mode in ["local", "own_domain"] do
      case find_and_verify() do
        {:ok, claims}  ->
          Logger.info("PRZMA license verified",
            tier: claims["tier"], expires: claims["exp"])
          %{valid: true, tier: claims["tier"], claims: claims}

        {:error, :no_license} ->
          Logger.info("No license file found — operating in free local mode")
          %{valid: true, tier: "free_local", claims: %{}}

        {:error, reason} ->
          Logger.warning("License verification failed", reason: inspect(reason))
          %{valid: false, tier: nil, claims: %{}, error: reason}
      end
    else
      # Cloud SaaS / BYOS — subscription checked via API, not license file
      %{valid: true, tier: :subscription_api, claims: %{}}
    end
  end

  @doc "Check if a specific feature is available under the current license"
  def feature_available?(license, feature) do
    tier = license[:tier] || license["tier"]
    tier_allows?(tier, feature)
  end

  @doc "Check if the license is still valid (not expired)"
  def valid?(license) do
    license[:valid] == true
  end

  @doc "Get license expiry as DateTime (nil if no expiry)"
  def expires_at(license) do
    case get_in(license, [:claims, "exp"]) do
      nil -> nil
      exp -> DateTime.from_unix(exp)
    end
  end

  # ── VERIFICATION ────────────────────────────────────────────────────────

  defp find_and_verify do
    case find_license_file() do
      nil       -> {:error, :no_license}
      path      -> verify_license_file(path)
    end
  end

  defp find_license_file do
    @license_file_paths
    |> Enum.map(&Path.expand/1)
    |> Enum.find(&File.exists?/1)
  end

  defp verify_license_file(path) do
    with {:ok, jwt}    <- File.read(path),
         jwt            <- String.trim(jwt),
         {:ok, claims} <- decode_and_verify(jwt) do
      {:ok, claims}
    else
      {:error, :file_read} -> {:error, {:file_read, path}}
      {:error, reason}     -> {:error, reason}
    end
  end

  defp decode_and_verify(jwt) do
    parts = String.split(jwt, ".")
    case parts do
      [header_b64, payload_b64, signature_b64] ->
        with {:ok, claims} <- decode_payload(payload_b64),
             :ok           <- check_expiry(claims),
             :ok           <- verify_signature(header_b64, payload_b64, signature_b64) do
          {:ok, claims}
        end

      _ ->
        {:error, :invalid_jwt_format}
    end
  end

  defp decode_payload(b64) do
    with {:ok, json} <- Base.decode64(b64, padding: false),
         {:ok, map}  <- Jason.decode(json) do
      {:ok, map}
    else
      _ -> {:error, :invalid_payload}
    end
  end

  defp check_expiry(claims) do
    case Map.get(claims, "exp") do
      nil -> :ok  # No expiry = perpetual license
      exp ->
        now = DateTime.utc_now() |> DateTime.to_unix()
        if exp > now, do: :ok, else: {:error, :license_expired}
    end
  end

  defp verify_signature(header_b64, payload_b64, _signature_b64) do
    # Phase 5: real Ed25519 verification via :crypto.verify/5
    # For Phase 5 implementation:
    #   message = "#{header_b64}.#{payload_b64}"
    #   :crypto.verify(:eddsa, :none, message, sig_bytes, [pub_key, :ed25519])
    :ok
  end

  # ── TIER FEATURE MAP ────────────────────────────────────────────────────

  @tier_features %{
    "free_local" => ~w(
      vault calendar chat companion basic_ai
    ),
    "essential" => ~w(
      vault calendar chat files companion basic_ai agents_1
    ),
    "professional" => ~w(
      vault calendar chat files metadata companion full_ai agents_5 analytics
    ),
    "sovereign" => ~w(
      vault calendar chat files metadata creative companion full_ai
      agents_unlimited analytics federation custom_namespace
    ),
  }

  defp tier_allows?(tier, feature) when is_binary(tier) or is_atom(tier) do
    tier_str = to_string(tier)
    features = Map.get(@tier_features, tier_str, [])
    to_string(feature) in features
  end
  defp tier_allows?(:subscription_api, _feature), do: true
  defp tier_allows?(nil, _feature),               do: false

  # ── LICENSE INFO ────────────────────────────────────────────────────────

  @doc "Generate a license summary for display"
  def summary(license) do
    %{
      valid:      license[:valid],
      tier:       license[:tier],
      expires_at: expires_at(license),
      mode:       if(license[:tier] == :subscription_api, do: "subscription", else: "license"),
    }
  end
end
