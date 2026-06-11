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
  alias PRZMA.Platform.Namespace

  # Get base path from runtime config (defaults to local /tmp for dev)
  def base_path do
    Application.get_env(:przma, :vault_base_path) ||
      System.get_env("VAULT_BASE_PATH") ||
      Path.join([System.tmp_dir!(), "przma_vaults"])
  end

  # ── WRITE ────────────────────────────────────────────────────────────────

  @doc "Store bytes. Returns {:ok, cas_uri} where cas_uri = \"cas:{blake3_hex}\""
  def put(did, data, opts \\ []) when is_binary(data) do
    written_by = opts[:written_by] || "unknown"
    # Encrypt via encryption context before writing
    case maybe_encrypt(did, data, written_by) do
      {:ok, encrypted} ->
        # Calculate BLAKE3 hash (temporary: use file-based storage until NIF ready)
        hash = blake3_hash(encrypted)

        # Store blob to filesystem temporarily (MVP: until Rust NIF is available)
        case store_blob_file(did, hash, encrypted) do
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
    File.exists?(blob_path(did, hash))
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
    sanitized_did = String.replace(did, ":", "_")
    Path.join([base_path(), sanitized_did, "cas", shard, hash])
  end

  # ── TEMPORARY FILE-BASED STORAGE (until Rust NIF is ready) ──────────────────

  defp blake3_hash(data) do
    # Simple hash for MVP: SHA256 (replace with BLAKE3 when NIF ready)
    :crypto.hash(:sha256, data)
    |> Base.encode16(case: :lower)
  end

  defp store_blob_file(did, hash, data) do
    base = base_path()

    # If using S3 path, skip file operations (NIF handles S3 directly)
    if String.starts_with?(base, "s3://") do
      # TODO: Implement S3 storage via NIF when ready
      {:error, "S3 storage not yet implemented; set VAULT_BASE_PATH to local directory"}
    else
      # Local file storage
      File.mkdir_p!(base)
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
  end

  defp retrieve_blob_file(did, hash) do
    path = blob_path(did, hash)

    case File.read(path) do
      {:ok, data} -> {:ok, data}
      {:error, :enoent} -> {:error, :not_found}
      {:error, reason} -> {:error, "failed to read blob: #{reason}"}
    end
  end
  @doc "Store a blob keyed by the client-provided BLAKE3 hash."
  def put_blob(did, hash, data) when is_binary(hash) and is_binary(data) do
    base = base_path()
    shard = String.slice(hash, 0, 2)

    if s3?(base) do
      {bucket, prefix} = parse_s3(base)
      key = join_key([prefix, Namespace.sanitize_did(did), "cas", shard, hash])
      case ExAws.S3.put_object(bucket, key, data) |> ExAws.request() do
        {:ok, _} -> {:ok, "cas:#{hash}"}
        {:error, reason} -> {:error, "s3 put failed: #{inspect(reason)}"}
      end
    else
      path = Path.join([base, Namespace.sanitize_did(did), "cas", shard, hash])
      with :ok <- File.mkdir_p(Path.dirname(path)),
           :ok <- File.write(path, data) do
        bucket = System.get_env("PRZMA_S3_BUCKET", "perkeep")
        key = join_key([Namespace.sanitize_did(did), "cas", shard, hash])
        case ExAws.S3.put_object(bucket, key, data) |> ExAws.request() do
          {:ok, _} ->
            {:ok, "cas:#{hash}"}
          {:error, reason} ->
            require Logger
            Logger.warning("S3 sync failed for #{hash}: #{inspect(reason)}")
            {:ok, "cas:#{hash}"}
        end
      else
        {:error, reason} -> {:error, "blob write failed: #{inspect(reason)}"}
      end
    end
  end

  @doc "Read a blob by BLAKE3 hash from S3 or local disk."
  def get_blob(did, hash) when is_binary(hash) do
    base = base_path()
    shard = String.slice(hash, 0, 2)

    if s3?(base) do
      {bucket, prefix} = parse_s3(base)
      key = join_key([prefix, Namespace.sanitize_did(did), "cas", shard, hash])
      case ExAws.S3.get_object(bucket, key) |> ExAws.request() do
        {:ok, %{body: body}} -> {:ok, body}
        {:error, _} -> {:error, :not_found}
      end
    else
      path = Path.join([base, Namespace.sanitize_did(did), "cas", shard, hash])
      case File.read(path) do
        {:ok, data} -> {:ok, data}
        {:error, :enoent} -> {:error, :not_found}
        {:error, reason} -> {:error, "blob read failed: #{inspect(reason)}"}
      end
    end
  end

  defp s3?(p), do: String.starts_with?(p, "s3://")
  defp parse_s3("s3://" <> rest) do
    case String.split(rest, "/", parts: 2) do
      [bucket, prefix] -> {bucket, prefix}
      [bucket] -> {bucket, ""}
    end
  end
  defp join_key(parts), do: parts |> Enum.reject(&(&1 == "")) |> Enum.join("/")
end
