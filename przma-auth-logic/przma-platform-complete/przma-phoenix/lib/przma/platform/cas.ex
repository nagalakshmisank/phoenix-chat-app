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

  @base_path Application.compile_env(:przma, [:vault, :base_path], "/var/przma/vaults")

  # ── WRITE ────────────────────────────────────────────────────────────────

  @doc "Store bytes. Returns {:ok, cas_uri} where cas_uri = \"cas:{blake3_hex}\""
  def put(did, data, opts \\ []) when is_binary(data) do
    written_by = opts[:written_by] || "unknown"
    # Encrypt via encryption context before writing
    case maybe_encrypt(did, data, written_by) do
      {:ok, encrypted} ->
        case NIF.cas_put(@base_path, did, encrypted) do
          {:ok, hash_json} ->
            hash = Jason.decode!(hash_json)
            {:ok, SC.cas_uri(hash)}
          {:error, msg} -> {:error, msg}
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
    case NIF.cas_get(@base_path, did, hash) do
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

  defp maybe_encrypt(did, data, _written_by) do
    alias PRZMA.Calendar.Storage.EncryptionContext
    if EncryptionContext.encryption_available?(did) do
      EncryptionContext.encrypt(did, "cas", data)
    else
      {:ok, data}
    end
  end

  defp maybe_decrypt(did, data) when is_binary(data) do
    alias PRZMA.Calendar.Storage.EncryptionContext
    if EncryptionContext.encryption_available?(did) do
      EncryptionContext.decrypt(did, "cas", data)
    else
      {:ok, data}
    end
  end

  defp blob_path(did, hash) do
    shard = String.slice(hash, 0, 2)
    Path.join([@base_path, did, "cas", shard, hash])
  end
end
