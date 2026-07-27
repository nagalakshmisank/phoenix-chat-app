# lib/przma_web/controllers/file_sync_controller.ex
#
# File Sync Controller for offline client synchronization.

defmodule PRZMAWeb.FileSyncController do
  use PRZMAWeb, :controller

  alias PRZMA.PzDb
  alias PRZMA.PzDbV2
  alias PRZMA.Platform.CAS
  alias PRZMA.Platform.ServicesCatalogue, as: SC
  require Logger

  # ── BLOB UPLOAD (CAS WITH DEDUP) ────────────────────────────────────────────

  @doc """
  Upload a file blob to CAS.

  `did` and `blake3_hash` are read from HTTP headers (x-przma-did,
  x-przma-blake3), with a fallback to request params. This avoids depending on
  the :api pipeline's Plug.Parsers to populate conn.params — headers are read
  straight from the connection adapter, so the upload works even when running
  the Router directly via Plug.Cowboy.

  Supports two body formats:
  1. Raw body:        POST /api/v1/files/sync/blob   (octet-stream body)
  2. Multipart field: POST /api/v1/files/sync/blob   (blob form field)

  Response (200):
    {
      "cas_hash": "...",
      "cas_uri": "cas:...",
      "status": "stored",
      "size_bytes": 5242880,
      "ref_count": 1
    }
  """
  def upload_blob(conn, params) do
    did   = get_header(conn, "x-przma-did")    || params["did"]
    hash  = get_header(conn, "x-przma-blake3") || params["blake3_hash"]
    space = get_header(conn, "x-przma-space")  || params["space"] || "core"

    IO.inspect(params, label: "PARAMS_RECEIVED")
    IO.inspect(did, label: "DID_VALUE")
    IO.inspect(hash, label: "HASH_VALUE")

    case {did, hash, params["blob"]} do
      {did, provided_hash, %Plug.Upload{path: tmp_path}}
      when is_binary(did) and is_binary(provided_hash) ->
        store_multipart_blob(conn, did, provided_hash, tmp_path, space)

      {did, hash, _} when is_binary(did) and is_binary(hash) ->
        store_raw_blob(conn, did, hash, space)

      _ ->
        conn
        |> put_status(400)
        |> json(%{error: "missing fields: did, blake3_hash"})
    end
  end

  # Raw octet-stream body — body streamed straight from the adapter.
  defp store_raw_blob(conn, did, hash, space) do
    auth_did = conn.assigns[:did]
    bare_hash = SC.cas_hash(hash)

    with :ok <- verify_did(auth_did, did),
         {:ok, blob_data, _conn} <- read_full_body(conn),
         {:ok, cas_uri} <- CAS.put(did, blob_data, written_by: "files", hash: bare_hash) do

      size_bytes = byte_size(blob_data)
      ref_count = record_cas_meta(did, bare_hash, size_bytes, cas_uri, space)
      Logger.info("[FileSyncController] blob uploaded (raw body) did=#{did} hash=#{bare_hash} size=#{size_bytes}")

      json(conn, %{
        cas_hash: bare_hash,
        cas_uri: cas_uri,
        status: "stored",
        size_bytes: size_bytes,
        ref_count: ref_count
      })
    else
      {:error, :did_mismatch} ->
        conn |> put_status(403) |> json(%{error: "did_mismatch"})

      {:error, reason} ->
        Logger.error("[FileSyncController] blob upload failed did=#{did} reason=#{inspect(reason)}")
        conn |> put_status(500) |> json(%{error: inspect(reason)})
    end
  end

  # Multipart form-data upload (legacy/compat path). Stored under the
  # client-declared hash — the server can't recompute it for E2E content.
  defp store_multipart_blob(conn, did, provided_hash, tmp_path, space) do
    auth_did = conn.assigns[:did]
    bare_hash = SC.cas_hash(provided_hash)

    with :ok <- verify_did(auth_did, did),
         {:ok, blob_data} <- File.read(tmp_path),
         {:ok, cas_uri} <- CAS.put(did, blob_data, written_by: "files", hash: bare_hash) do

      size_bytes = byte_size(blob_data)
      ref_count = record_cas_meta(did, bare_hash, size_bytes, cas_uri, space)
      Logger.info("[FileSyncController] blob uploaded did=#{did} hash=#{bare_hash} size=#{size_bytes}")

      json(conn, %{
        cas_hash: bare_hash,
        cas_uri: cas_uri,
        status: "stored",
        size_bytes: size_bytes,
        ref_count: ref_count
      })
    else
      {:error, :did_mismatch} ->
        conn |> put_status(403) |> json(%{error: "did_mismatch"})

      {:error, reason} ->
        Logger.error("[FileSyncController] blob upload failed did=#{did} reason=#{inspect(reason)}")
        conn |> put_status(500) |> json(%{error: inspect(reason)})
    end
  end

  # ── FILE RECORD SYNC (METADATA TO LANCE) ────────────────────────────────────

  def sync_record(conn, params) do
    # Fall back to decoding the raw JSON body when conn.params is empty (the
    # :api pipeline's Plug.Parsers may not have populated it).
    {conn, params} = ensure_json_params(conn, params)

    auth_did = conn.assigns[:did]
    rec_did = params["did"]
    file_id = params["id"]
    space = params["space"] || "core"

    with :ok <- verify_did(auth_did, rec_did),
         pzdb_uri = "pzdb://#{rec_did}/files/#{space}/file/#{file_id}",
         :ok <- PzDb.ensure_table(pzdb_uri),
         {:ok, result} <- PzDb.write(pzdb_uri, params, [
           encrypt: true,
           index_opts: %{
             title: params["name"],
             snippet: "File: #{params["name"]}",
             source: "files"
           }
         ]) do

      version = result["version"]
      Logger.info("[FileSyncController] record synced did=#{rec_did} file=#{file_id} space=#{space} version=#{version}")

      # Mirror to przma-common if this is a commons record
      if space == "commons", do: mirror_to_przma_common(rec_did, file_id, params)

      json(conn, %{
        file_id: file_id,
        status: "synced",
        version: version
      })
    else
      {:error, :did_mismatch} ->
        conn |> put_status(403) |> json(%{error: "did_mismatch"})

      {:error, reason} ->
        Logger.error("[FileSyncController] record sync failed did=#{rec_did} reason=#{inspect(reason)}")
        conn |> put_status(500) |> json(%{error: inspect(reason)})
    end
  end

  # ── MARK SYNCED (UPDATE QUEUE + FILE) ───────────────────────────────────────

  def mark_synced(conn, %{"file_id" => file_id, "space" => space}) do
    did = conn.assigns[:did]
    now_micros = System.os_time(:microsecond)

    queue_uri = "pzdb://#{did}/files/core/sync_queue/#{file_id}"
    queue_record = %{
      "id" => file_id,
      "status" => "synced",
      "synced_at" => now_micros
    }

    file_uri = "pzdb://#{did}/files/#{space}/file/#{file_id}"

    # Read-modify-write: PzDb.write backfills any missing field with a blank
    # default, so writing a 3-field partial record would wipe name/content_cas/
    # etc. back to empty on every mark_synced call. Fetch the existing record
    # first and only flip the fields that actually changed.
    existing_record =
      case PzDb.query(file_uri, filter: "id = '#{file_id}'", limit: 1) do
        {:ok, %{"records" => [record | _]}} -> record
        _ -> %{"id" => file_id}
      end

    file_update =
      existing_record
      |> Map.merge(%{
        "upload_status" => "synced",
        "updated_at" => now_micros
      })

    with {:ok, _} <- PzDb.write(queue_uri, queue_record),
         {:ok, _} <- PzDb.write(file_uri, file_update) do

      Logger.info("[FileSyncController] marked synced did=#{did} file=#{file_id} space=#{space}")

      json(conn, %{
        file_id: file_id,
        status: "synced"
      })
    else
      {:error, reason} ->
        Logger.error("[FileSyncController] mark_synced failed reason=#{inspect(reason)}")
        conn |> put_status(500) |> json(%{error: inspect(reason)})
    end
  end

  # ── LIST REMOTE FILES ───────────────────────────────────────────────────────

  def list_remote(conn, params) do
    did = conn.assigns[:did]
    IO.inspect(did, label: "LIST_REMOTE_DID_VALUE")
    space = params["space"] || "core"
    limit = parse_limit(params["limit"])

    pzdb_table_uri = "pzdb://#{did}/files/#{space}/file/placeholder"

#cas_meta has no upload_status field — use no filter
filter = if space == "cas_meta", do: "", else: "upload_status = 'synced'"

    case PzDb.query(pzdb_table_uri,
      filter: "upload_status = 'synced'",
      limit: limit
    ) do
      {:ok, %{"records" => records}} ->
        json(conn, %{
          files: records,
          space: space,
          count: length(records)
        })

      {:error, reason} ->
        Logger.error("[FileSyncController] list_remote failed space=#{space} reason=#{inspect(reason)}")
        conn |> put_status(500) |> json(%{error: inspect(reason)})
    end
  end

  # ── DOWNLOAD BLOB (CAS RETRIEVAL) ───────────────────────────────────────────

  def download_blob(conn, %{"hash" => hash} = params) do
    requester_did = conn.assigns[:did]
    owner_did     = params["owner"] || requester_did

    case CAS.get(owner_did, SC.cas_uri(hash)) do
      {:ok, data} ->
        conn
        |> put_resp_content_type("application/octet-stream")
        |> put_resp_header("x-przma-blake3", hash)
        |> send_resp(200, data)

      {:error, reason} ->
        Logger.error("[FileSyncController] blob download failed hash=#{hash} reason=#{inspect(reason)}")
        conn |> put_status(404) |> json(%{error: "not_found", hash: hash})
    end
  end

  # ── LIST PENDING SYNCS (FROM QUEUE) ─────────────────────────────────────────

  def list_pending(conn, params) do
    did = conn.assigns[:did]
    limit = parse_limit(params["limit"])

    pzdb_queue_uri = "pzdb://#{did}/files/core/sync_queue/placeholder"

    case PzDb.query(pzdb_queue_uri,
      filter: "status = 'pending'",
      limit: limit
    ) do
      {:ok, %{"records" => pending}} ->
        json(conn, %{
          pending_syncs: pending,
          count: length(pending)
        })

      {:error, reason} ->
        Logger.error("[FileSyncController] list_pending failed reason=#{inspect(reason)}")
        conn |> put_status(500) |> json(%{error: inspect(reason)})
    end
  end

  # ── PRIVATE HELPERS ─────────────────────────────────────────────────────────

  defp ensure_json_params(conn, params) do
    if is_map(params) and Map.has_key?(params, "did") do
      {conn, params}
    else
      case read_full_body(conn) do
        {:ok, body, conn} when byte_size(body) > 0 ->
          case Jason.decode(body) do
            {:ok, decoded} when is_map(decoded) -> {conn, Map.merge(params, decoded)}
            _ -> {conn, params}
          end

        {:ok, _empty, conn} ->
          {conn, params}

        {:error, _reason} ->
          {conn, params}
      end
    end
  end

  defp get_header(conn, name) do
    case Plug.Conn.get_req_header(conn, name) do
      [value | _] -> value
      [] -> nil
    end
  end

  defp read_full_body(conn, acc \\ []) do
    case Plug.Conn.read_body(conn, length: 100_000_000, read_length: 1_000_000) do
      {:ok, chunk, conn} ->
        {:ok, IO.iodata_to_binary([acc, chunk]), conn}

      {:more, chunk, conn} ->
        read_full_body(conn, [acc, chunk])

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp verify_did(nil, _req_did), do: :ok
  defp verify_did(auth_did, req_did) when auth_did == req_did, do: :ok
  defp verify_did(_auth, _req), do: {:error, :did_mismatch}

  defp parse_limit(nil), do: 500
  defp parse_limit(n) when is_binary(n), do: String.to_integer(n)
  defp parse_limit(n) when is_integer(n), do: n

  # Mirror commons record to shared przma-common analytics table.
  # Every user's commons file gets a copy at:
  #   s3://perkeep/przma-common/files/commons/files.lance/
  # The row id is namespaced as "did:file_id" so two users with the
  # same file_id never clobber each other in the shared table.
  # Fire-and-forget — failure here never fails the user's own sync.
  defp mirror_to_przma_common(did, file_id, params) do
    shared_id  = "#{did}:#{file_id}"
    shared_uri = "pzdb://przma-common/files/commons/file/#{shared_id}"

    shared_params =
      params
      |> Map.put("id", shared_id)
      |> Map.put("did", did)

    case PzDb.write(shared_uri, shared_params) do
      {:ok, _} ->
        Logger.info("[FileSyncController] mirrored to przma-common file=#{file_id} did=#{did}")

      {:error, reason} ->
        Logger.warning("[FileSyncController] przma-common mirror failed file=#{file_id} reason=#{inspect(reason)}")
    end
  end

  # CAS metadata — records uri, uri_type, s3_uri and space for every blob.
  # Stored at: s3://perkeep/{did}/files/core/cas_meta.lance/
  #
  # Fields:
  #   id         → hash (natural dedup key — one row per unique blob)
  #   hash       → BLAKE3 hash of the blob content
  #   cas_uri    → internal CAS reference e.g. "cas:alice_report_001"
  #   uri        → shareable Phoenix API URL — safe for circle/commons sharing
  #   uri_type   → "api" — confirms uri goes through DID auth
  #   s3_uri     → actual S3 location — internal/analytics only, never expose
  #   space      → "core" | "commons" | "circle:xyz"
  #   did        → owner DID
  #   ref_count  → how many file records reference this blob (for GC)
  #   size_bytes → blob size in bytes
  #   created_at → unix microseconds
  #   updated_at → unix microseconds# ── LIST CAS METADATA (for demo/inspection) ────────────────────────────────
  def list_cas_meta(conn, params) do
    did = conn.assigns[:did]
    limit = parse_limit(params["limit"])

    pzdb_table_uri = "pzdb://#{did}/files/core/cas_meta/placeholder"

    case PzDb.query(pzdb_table_uri, limit: limit) do
      {:ok, %{"records" => records}} ->
        json(conn, %{
          cas_meta: records,
          count: length(records)
        })

      {:error, reason} ->
        Logger.error("[FileSyncController] list_cas_meta failed reason=#{inspect(reason)}")
        conn |> put_status(500) |> json(%{error: inspect(reason)})
    end
  end
  defp record_cas_meta(did, hash, size_bytes, cas_uri, space) do
    meta_uri = "pzdb://#{did}/files/core/cas_meta/#{hash}"

    # Check existing ref_count for dedup
    existing_ref_count =
      case PzDb.query(meta_uri, filter: "hash = '#{hash}'", limit: 1) do
        {:ok, %{"records" => [%{"ref_count" => rc} | _]}} -> rc
        _ -> 0
      end

    # Shareable URI — goes through Phoenix DID auth, safe for circle/commons
    base_url = System.get_env("PRZMA_PUBLIC_BASE_URL") || "http://localhost:4000"
    uri      = "#{base_url}/api/v1/files/sync/blob/#{hash}?owner=#{did}"

    # S3 URI — actual storage location, internal/analytics use only
    endpoint      = System.get_env("AWS_ENDPOINT") || "https://in-maa-1.linodeobjects.com"
    bucket        = (System.get_env("VAULT_BASE_PATH") || "s3://perkeep") |> String.replace("s3://", "")
    shard         = String.slice(hash, 0, 2)
    sanitized_did = String.replace(did, ":", "_") |> String.replace(".", "_")
    s3_uri        = "#{endpoint}/#{bucket}/#{sanitized_did}/cas/#{shard}/#{hash}"

    meta_record = %{
      "id"         => hash,
      "hash"       => hash,
      "cas_uri"    => cas_uri,
      "uri"        => uri,
      "uri_type"   => "api",
      "s3_uri"     => s3_uri,
      "space"      => space,
      "did"        => did,
      "ref_count"  => existing_ref_count + 1,
      "size_bytes" => size_bytes,
      "created_at" => System.os_time(:microsecond),
      "updated_at" => System.os_time(:microsecond)
    }

    with :ok <- PzDbV2.ensure_table(meta_uri, "cas_meta"),
         {:ok, _} <- PzDbV2.write(meta_uri, meta_record, encrypt: false) do
      Logger.info("[FileSyncController] cas_meta recorded (PzDbV2 trial) hash=#{hash} space=#{space} ref_count=#{existing_ref_count + 1}")
      existing_ref_count + 1
    else
      {:error, reason} ->
        Logger.warning("[FileSyncController] cas_meta failed hash=#{hash} reason=#{inspect(reason)}")
    end
  rescue
    e -> Logger.warning("[FileSyncController] cas_meta error #{inspect(e)}")
    1
  end

end
