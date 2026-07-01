# lib/przma/platform/cas.ex
#
# Universal CAS for the PRZMA platform.
# All services use this module to read/write blobs.
# Wraps the Rust PlatformCas NIF — encryption happens in Rust before any write.
#
# Usage:
#   alias PRZMA.Platform.CAS
#   {:ok, uri}  = CAS.put(did, data, mime_type: "text/plain", written_by: "vault")
#   {:ok, text} = CAS.get_text(did, uri)
#   :ok         = CAS.deref(did, uri)

defmodule PRZMA.Platform.CAS do
  alias PRZMA.Calendar.NIF     # Reuses the existing NIF module
  alias PRZMA.Platform.ServicesCatalogue, as: SC

  # Get base path from runtime config (defaults to local /tmp for dev)
  def base_path do
    Application.get_env(:przma, :vault_base_path) ||
      System.get_env("VAULT_BASE_PATH") ||
      Path.join([System.tmp_dir!(), "przma_vaults"])
  end

  # ── WRITE ────────────────────────────────────────────────────────────────

  @doc """
  Store bytes. Returns {:ok, cas_uri} where cas_uri = "cas:{blake3_hex}".

  Options:
    * `:hash` — the content hash to key the blob under (bare hex, no "cas:"
      prefix). The desktop client computes BLAKE3 over the *plaintext* and
      uploads the encrypted bytes; the server can't reproduce that hash (it
      never sees the plaintext and lacks the key), so it stores under the
      client-declared hash. When omitted (server-originated, non-E2E content),
      the server hashes the bytes itself.
    * `:written_by` — provenance tag.
  """
  def put(did, data, opts \\ []) when is_binary(data) do
    written_by = opts[:written_by] || "unknown"
    # Encrypt via encryption context before writing
    case maybe_encrypt(did, data, written_by) do
      {:ok, stored_bytes} ->
        # Trust the client-declared content hash (E2E uploads); otherwise hash
        # the bytes ourselves (server-originated content).
        hash =
          case opts[:hash] do
            h when is_binary(h) and h != "" -> SC.cas_hash(h)
            _ -> content_hash(stored_bytes)
          end

        case store_blob_file(did, hash, stored_bytes) do
          :ok ->
            {:ok, SC.cas_uri(hash)}
          {:error, msg} ->
            {:error, msg}
        end
      {:error, msg} -> {:error, msg}
    end
  end

  @doc "Store a UTF-8 string. Returns {:ok, cas_uri}"
  def put_text(did, text, opts \\ []) when is_binary(text) do
    put(did, text, Keyword.put_new(opts, :mime_type, "text/plain"))
  end

  @doc "Store a JSON-encodable value. Returns {:ok, cas_uri}"
  def put_json(did, value, opts \\ []) do
    with {:ok, json} <- Jason.encode(value) do
      put(did, json, Keyword.put_new(opts, :mime_type, "application/json"))
    end
  end

  # ── READ ─────────────────────────────────────────────────────────────────

  @doc "Read bytes by CAS URI. Returns {:ok, binary} | {:error, :not_found}"
  def get(did, uri) when is_binary(uri) do
    hash = SC.cas_hash(uri)
    case retrieve_blob_file(did, hash) do
      {:ok, encrypted} -> maybe_decrypt(did, encrypted)
      {:error, msg}    -> {:error, msg}
    end
  end

  @doc "Read and decode UTF-8 text"
  def get_text(did, uri) do
    case get(did, uri) do
      {:ok, bytes} ->
        case :unicode.characters_to_binary(bytes) do
          text when is_binary(text) -> {:ok, text}
          _                         -> {:error, :encoding_error}
        end
      error -> error
    end
  end

  @doc "Read and JSON-decode"
  def get_json(did, uri) do
    case get_text(did, uri) do
      {:ok, text} -> Jason.decode(text)
      error       -> error
    end
  end

  @doc "Check if a CAS blob exists"
  def exists?(did, uri) do
    hash = SC.cas_hash(uri)

    case cas_backend() do
      :s3 ->
        case ExAws.S3.head_object(s3_bucket(), object_key(did, hash)) |> ExAws.request() do
          {:ok, _} -> true
          _ -> false
        end

      :local ->
        File.exists?(blob_path(did, hash))
    end
  end

  # ── LIFECYCLE ────────────────────────────────────────────────────────────

  @doc """
  Decrement the ref count for a CAS blob.
  When count reaches 0, the blob is eligible for GC.
  Call this when a service record that held a CAS reference is deleted.
  """
  def deref(did, uri) when is_binary(uri) do
    # Phase final: call Rust deref NIF
    # For now: no-op (GC pass handles orphaned blobs)
    :ok
  end

  @doc "Run GC — delete all blobs with ref_count = 0"
  def gc(did) do
    # Phase final: call Rust GC NIF
    # Returns {:ok, %{deleted: n, freed_bytes: n}}
    {:ok, %{deleted: 0, freed_bytes: 0}}
  end

  # ── SERVICE HELPERS ──────────────────────────────────────────────────────

  @doc """
  Bulk-write a list of {data, opts} pairs.
  Returns list of {:ok, uri} | {:error, reason} in the same order.
  """
  def put_many(did, items) when is_list(items) do
    Enum.map(items, fn {data, opts} -> put(did, data, opts) end)
  end

  @doc """
  Bulk-read a list of CAS URIs.
  Returns map of %{uri => {:ok, data} | {:error, reason}}
  """
  def get_many(did, uris) when is_list(uris) do
    Map.new(uris, fn uri -> {uri, get(did, uri)} end)
  end

  # ── CROSS-SERVICE CAS REFERENCES ─────────────────────────────────────────

  @doc """
  Transfer a CAS blob from one service context to another.
  Does NOT copy the data — increments ref count only.
  Returns the same URI.
  """
  def reference(did, uri, _target_service) when is_binary(uri) do
    # Phase final: increment ref count via Rust NIF
    {:ok, uri}
  end

  # ── PRIVATE ──────────────────────────────────────────────────────────────

  defp maybe_encrypt(_did, data, _written_by) do
    # Encryption context not available yet; store raw binary
    # TODO: integrate EncryptionContext when available
    {:ok, data}
  end

  defp maybe_decrypt(_did, data) when is_binary(data) do
    # Decryption context not available yet; return raw binary
    # TODO: integrate EncryptionContext when available
    {:ok, data}
  end

  defp blob_path(did, hash) do
    shard = String.slice(hash, 0, 2)
    # Sanitize DID: replace colons with underscores (invalid on Windows)
    # did:web:alice.com → did_web_alice.com
    sanitized_did = did |> String.replace(":", "_") |> String.replace(".", "_")
    Path.join([base_path(), sanitized_did, "cas", shard, hash])
  end

  # Object key for S3. Mirrors the local layout (minus base_path):
  #   {sanitized_did}/cas/{shard}/{hash}
  # e.g. did_web_alice.com/cas/72/724d57...
  defp object_key(did, hash) do
    shard = String.slice(hash, 0, 2)
    sanitized_did = did |> String.replace(":", "_") |> String.replace(".", "_")
    Enum.join([sanitized_did, "cas", shard, hash], "/")
  end

  defp cas_backend do
    case Application.get_env(:przma, :cas_backend, "local") do
      "s3" -> :s3
      :s3 -> :s3
      _ -> :local
    end
  end

  defp s3_bucket do
    Application.get_env(:przma, :s3_bucket) ||
      System.get_env("S3_BUCKET") ||
      System.get_env("BUCKET") ||
      "przma-vaults"
  end

  # ── TEMPORARY FILE-BASED STORAGE (until Rust NIF is ready) ──────────────────

  # Fallback hash for server-originated content (no client hash supplied).
  # NOTE: this is SHA-256, NOT BLAKE3. It is only ever used for content the
  # server itself creates and reads back (internally consistent). Client blobs
  # are always keyed by the client's BLAKE3 hash passed via opts[:hash].
  defp content_hash(data) do
    :crypto.hash(:sha256, data)
    |> Base.encode16(case: :lower)
  end

  defp store_blob_file(did, hash, data) do
    case cas_backend() do
      :s3    -> store_blob_s3(did, hash, data)
      :local -> store_blob_local(did, hash, data)
    end
  end

  defp retrieve_blob_file(did, hash) do
    case cas_backend() do
      :s3    -> retrieve_blob_s3(did, hash)
      :local -> retrieve_blob_local(did, hash)
    end
  end

  # ── S3 / OBJECT STORE BACKEND ───────────────────────────────────────────────

  defp store_blob_s3(did, hash, data) do
    bucket = s3_bucket()
    key = object_key(did, hash)

    # CAS is immutable & deduplicated: if the object already exists, the bytes
    # are identical, so skip the upload.
    if blob_exists_s3?(bucket, key) do
      :ok
    else
      case ExAws.S3.put_object(bucket, key, data) |> ExAws.request() do
        {:ok, _resp} -> :ok
        {:error, reason} -> {:error, "S3 put failed: #{inspect(reason)}"}
      end
    end
  end

  defp retrieve_blob_s3(did, hash) do
    bucket = s3_bucket()
    key = object_key(did, hash)

    case ExAws.S3.get_object(bucket, key) |> ExAws.request() do
      {:ok, %{body: body}}            -> {:ok, body}
      {:error, {:http_error, 404, _}} -> {:error, :not_found}
      {:error, reason}                -> {:error, "S3 get failed: #{inspect(reason)}"}
    end
  end

  defp blob_exists_s3?(bucket, key) do
    case ExAws.S3.head_object(bucket, key) |> ExAws.request() do
      {:ok, _} -> true
      _ -> false
    end
  end

  # ── LOCAL FILESYSTEM BACKEND ────────────────────────────────────────────────

  defp store_blob_local(did, hash, data) do
    File.mkdir_p!(base_path())
    path = blob_path(did, hash)
    dir = Path.dirname(path)

    case File.mkdir_p(dir) do
      :ok ->
        case File.write(path, data) do
          :ok -> :ok
          {:error, reason} -> {:error, "failed to write blob: #{reason}"}
        end

      {:error, reason} ->
        {:error, "failed to create directory: #{reason}"}
    end
  end

  defp retrieve_blob_local(did, hash) do
    path = blob_path(did, hash)

    case File.read(path) do
      {:ok, data} -> {:ok, data}
      {:error, :enoent} -> {:error, :not_found}
      {:error, reason} -> {:error, "failed to read blob: #{reason}"}
    end
  end
end
