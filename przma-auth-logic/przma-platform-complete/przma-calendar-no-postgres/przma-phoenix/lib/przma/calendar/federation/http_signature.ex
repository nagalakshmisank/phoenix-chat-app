# lib/przma/calendar/federation/http_signature.ex
#
# HTTP Message Signatures (draft-ietf-httpbis-message-signatures)
# for ActivityPub delivery and DID-based authentication.
#
# Signs outbound ActivityPub requests with the user's DID key.
# Verifies inbound requests against the sender's DID document.

defmodule PRZMA.Calendar.Federation.HTTPSignature do
  require Logger

  @algorithm "ecdsa-p256-sha256"
  @signed_headers "(request-target) host date content-digest"

  # ── SIGNING ────────────────────────────────────────────────────────────────

  @doc """
  Build HTTP Signature headers for an outbound ActivityPub POST.
  Returns a map of headers to add to the request.
  """
  def sign_request(method, url, body, key_id, private_key_pem) do
    uri     = URI.parse(url)
    host    = uri.host
    date    = http_date()
    digest  = body_digest(body)
    target  = "#{String.downcase(method)} #{uri.path}"

    signing_string = build_signing_string(target, host, date, digest)

    case sign_ecdsa(signing_string, private_key_pem) do
      {:ok, sig_b64} ->
        signature = build_signature_header(key_id, sig_b64)
        {:ok, %{
          "host"           => host,
          "date"           => date,
          "content-digest" => "sha-256=:#{digest}:",
          "authorization"  => "Signature #{signature}",
          "content-type"   => "application/activity+json",
        }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── VERIFICATION ──────────────────────────────────────────────────────────

  @doc """
  Verify an inbound HTTP Signature.
  Resolves the DID document to get the public key.
  Returns {:ok, did} or {:error, reason}.
  """
  def verify_request(conn) do
    with {:ok, auth_header}  <- get_header(conn, "authorization"),
         {:ok, key_id, sig}  <- parse_signature_header(auth_header),
         {:ok, did}           <- extract_did(key_id),
         {:ok, public_key}   <- resolve_public_key(did, key_id),
         {:ok, date}          <- get_header(conn, "date"),
         :ok                  <- check_date_freshness(date),
         {:ok, digest}        <- get_header(conn, "content-digest"),
         :ok                  <- verify_body_digest(conn, digest),
         :ok                  <- verify_signature(conn, public_key, sig) do
      {:ok, did}
    end
  end

  # ── KEY MANAGEMENT ─────────────────────────────────────────────────────────

  @doc "Load the private key for a DID from the vault key store"
  def load_private_key(did) do
    # Phase 3: loads from encrypted key store in vault
    # For now: reads from config (dev mode only)
    case Application.get_env(:przma, [:keys, did]) do
      nil     -> {:error, :key_not_found}
      key_pem -> {:ok, key_pem}
    end
  end

  @doc "Get the key_id for a DID's primary signing key"
  def key_id_for_did(did, instance_url) do
    encoded = URI.encode(did)
    "#{instance_url}/ap/actor/#{encoded}#key-1"
  end

  # ── PRIVATE ────────────────────────────────────────────────────────────────

  defp build_signing_string(target, host, date, digest) do
    """
    (request-target): #{target}
    host: #{host}
    date: #{date}
    content-digest: sha-256=:#{digest}:
    """ |> String.trim()
  end

  defp build_signature_header(key_id, sig_b64) do
    ~s(keyId="#{key_id}",algorithm="#{@algorithm}",) <>
    ~s(headers="#{@signed_headers}",signature="#{sig_b64}")
  end

  defp parse_signature_header(header) do
    header_body = header |> String.replace_prefix("Signature ", "")

    with {:ok, key_id} <- extract_param(header_body, "keyId"),
         {:ok, sig}    <- extract_param(header_body, "signature") do
      {:ok, key_id, sig}
    end
  end

  defp extract_param(header, param) do
    case Regex.run(~r/#{param}="([^"]+)"/, header) do
      [_, value] -> {:ok, value}
      _          -> {:error, {:missing_param, param}}
    end
  end

  defp extract_did(key_id) do
    # key_id format: https://host/ap/actor/did%3Aweb%3Aalice.com#key-1
    # or: did:web:alice.com#key-1
    cond do
      String.starts_with?(key_id, "did:") ->
        did = key_id |> String.split("#") |> hd()
        {:ok, did}
      true ->
        case Regex.run(~r|/ap/actor/([^#]+)#|, key_id) do
          [_, encoded_did] ->
            {:ok, URI.decode(encoded_did)}
          _ ->
            {:error, :cannot_extract_did}
        end
    end
  end

  defp resolve_public_key(did, key_id) do
    with {:ok, doc} <- PRZMA.Calendar.Federation.DIDResolver.resolve(did) do
      methods = doc["verificationMethod"] || []
      case Enum.find(methods, fn m -> m["id"] == key_id end) do
        nil    -> {:error, :key_not_found}
        method -> {:ok, method["publicKeyPem"] || method["publicKeyJwk"]}
      end
    end
  end

  defp check_date_freshness(date_str) do
    case Timex.parse(date_str, "{RFC1123}") do
      {:ok, dt} ->
        diff = DateTime.diff(DateTime.utc_now(), DateTime.from_naive!(dt, "Etc/UTC"), :second)
        if abs(diff) <= 300, do: :ok, else: {:error, :date_out_of_window}
      _ ->
        {:error, :invalid_date}
    end
  end

  defp verify_body_digest(conn, digest_header) do
    # digest_header format: sha-256=:base64hash:
    body = conn.assigns[:raw_body] || ""
    computed = body_digest(body)
    expected = digest_header |> String.replace("sha-256=:", "") |> String.replace_suffix(":", "")
    if computed == expected, do: :ok, else: {:error, :body_digest_mismatch}
  end

  defp verify_signature(_conn, _public_key, _sig) do
    # Phase 3: full ECDSA P-256 verification
    # For now: accept all valid-looking signatures
    :ok
  end

  defp sign_ecdsa(message, _private_key_pem) do
    # Phase 3: real ECDSA P-256 signing via :crypto
    # For now: HMAC-SHA256 placeholder
    sig = :crypto.mac(:hmac, :sha256, "dev-key", message)
    {:ok, Base.encode64(sig)}
  end

  defp body_digest(body) do
    :crypto.hash(:sha256, body) |> Base.encode64()
  end

  defp http_date do
    Calendar.strftime(DateTime.utc_now(), "%a, %d %b %Y %H:%M:%S GMT")
  end

  defp get_header(conn, name) do
    case Plug.Conn.get_req_header(conn, name) do
      [v | _] -> {:ok, v}
      []      -> {:error, {:missing_header, name}}
    end
  end
end
