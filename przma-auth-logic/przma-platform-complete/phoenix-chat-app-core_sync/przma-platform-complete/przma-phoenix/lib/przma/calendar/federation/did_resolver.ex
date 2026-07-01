# lib/przma/calendar/federation/did_resolver.ex
#
# DID Document resolution for DID:web and DID:key.
# Caches resolved documents with configurable TTL.
# Used by HTTP Signature verification and ActivityPub delivery.

defmodule PRZMA.Calendar.Federation.DIDResolver do
  use GenServer
  require Logger

  @cache_ttl_secs 300     # 5 minutes in-memory cache
  @http_timeout   5_000   # 5 second HTTP timeout

  # ── PUBLIC API ────────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @doc """
  Resolve a DID to its DID document.
  Returns {:ok, document_map} or {:error, reason}.
  Caches results for @cache_ttl_secs seconds.
  """
  def resolve(did) do
    GenServer.call(__MODULE__, {:resolve, did}, 10_000)
  end

  @doc "Force refresh a cached DID document"
  def invalidate(did) do
    GenServer.cast(__MODULE__, {:invalidate, did})
  end

  # ── GENSERVER ─────────────────────────────────────────────────────────────

  @impl true
  def init(_), do: {:ok, %{}}

  @impl true
  def handle_call({:resolve, did}, _from, cache) do
    case Map.get(cache, did) do
      {doc, cached_at} when is_integer(cached_at) ->
        age = System.os_time(:second) - cached_at
        if age < @cache_ttl_secs do
          {:reply, {:ok, doc}, cache}
        else
          resolve_and_cache(did, cache)
        end
      _ ->
        resolve_and_cache(did, cache)
    end
  end

  @impl true
  def handle_cast({:invalidate, did}, cache) do
    {:noreply, Map.delete(cache, did)}
  end

  # ── RESOLUTION LOGIC ──────────────────────────────────────────────────────

  defp resolve_and_cache(did, cache) do
    case do_resolve(did) do
      {:ok, doc} ->
        new_cache = Map.put(cache, did, {doc, System.os_time(:second)})
        {:reply, {:ok, doc}, new_cache}

      {:error, reason} = err ->
        Logger.warning("DID resolution failed", did: did, reason: inspect(reason))
        {:reply, err, cache}
    end
  end

  defp do_resolve("did:key:" <> _key = did) do
    resolve_did_key(did)
  end

  defp do_resolve("did:web:" <> rest = did) do
    resolve_did_web(rest)
  end

  defp do_resolve(did) do
    {:error, {:unsupported_did_method, did}}
  end

  # ── DID:WEB RESOLUTION ────────────────────────────────────────────────────

  defp resolve_did_web(rest) do
    # did:web:alice.com → https://alice.com/.well-known/did.json
    # did:web:alice.com:users:alice → https://alice.com/users/alice/did.json
    url = did_web_to_url(rest)
    Logger.debug("Resolving DID:web", url: url)

    case HTTPoison.get(url,
          [{"Accept", "application/json"}],
          recv_timeout: @http_timeout, follow_redirect: true) do
      {:ok, %{status_code: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, doc}  -> {:ok, doc}
          {:error, e} -> {:error, {:json_decode, e}}
        end

      {:ok, %{status_code: 404}} ->
        {:error, :not_found}

      {:ok, %{status_code: code}} ->
        {:error, {:http_error, code}}

      {:error, reason} ->
        # Try PRZMA mirror as fallback
        try_mirror_fallback(rest, reason)
    end
  end

  defp did_web_to_url(rest) do
    parts = String.split(rest, ":")
    case parts do
      [domain] ->
        "https://#{domain}/.well-known/did.json"
      [domain | path_parts] ->
        path = Enum.join(path_parts, "/")
        "https://#{domain}/#{path}/did.json"
    end
  end

  defp try_mirror_fallback(rest, original_error) do
    mirror_url = "https://mirror.przma.net/v1/cache/did:web:#{rest}"
    case HTTPoison.get(mirror_url,
          [{"Accept", "application/json"}],
          recv_timeout: @http_timeout) do
      {:ok, %{status_code: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, doc} ->
            Logger.info("DID resolved from PRZMA mirror", did_rest: rest)
            {:ok, doc}
          _ ->
            {:error, original_error}
        end
      _ ->
        {:error, original_error}
    end
  end

  # ── DID:KEY RESOLUTION ────────────────────────────────────────────────────

  defp resolve_did_key(did) do
    # DID:key embeds the public key in the DID itself — no HTTP lookup needed
    # For Phase 3: return a synthetic DID document
    # Full multibase/multicodec decoding in Phase 5
    doc = %{
      "@context"           => ["https://www.w3.org/ns/did/v1"],
      "id"                 => did,
      "verificationMethod" => [%{
        "id"              => "#{did}#key-1",
        "type"            => "JsonWebKey2020",
        "controller"      => did,
        "publicKeyJwk"    => %{
          "kty"  => "OKP",
          "crv"  => "Ed25519",
          "x"    => did |> String.split(":") |> List.last() |> String.slice(0, 43),
        }
      }],
      "authentication"     => ["#{did}#key-1"],
    }
    {:ok, doc}
  end
end
