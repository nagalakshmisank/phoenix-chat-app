defmodule PRZMAWeb.Graphql.Resolvers.FilesResolver do
  @moduledoc """
  Upload/list/sync operations for the files service, plus the CAS
  ledger and blob-download queries.

  DOWNLOAD: exposed as `blob_download_url` (a query, not a
  mutation) that returns a short-lived presigned S3 URL rather than
  inline bytes. GraphQL responses are JSON, and returning raw file
  bytes would mean base64-encoding them inline, which is a poor fit
  for anything beyond small files — the client fetches straight from
  S3 with the returned URL instead. See Cas.presigned_get_url/4.

  `list/2` calls Przma.Vault.Files.list_recent/3, which goes through
  PzdbConnector.read_many/2 -> LanceLinodeAdapter.query_many/1 (a
  `did` COLUMN filter, no limit) instead of the old single-record
  query/2 path — this is the fix for files having many rows per did,
  each with its own generated id, unlike profile's one row per did.
  query/2 itself (used by profile.ex) is untouched by this.
  """

  alias Przma.Vault.{CasMeta, Files}

  def upload(%{file: %Plug.Upload{} = upload} = args, %{context: context}) do
    actor = actor(context)
    space = Map.get(args, :space, "private")
    owner_did = Map.get(args, :owner_did)

    with {:ok, bytes} <- File.read(upload.path),
         metadata = %{filename: upload.filename, content_type: upload.content_type, size_bytes: byte_size(bytes)},
         opts = [space: space] ++ if(owner_did, do: [owner_did: owner_did], else: []),
         {:ok, file_id} <- Files.upload(actor, context.tenant_uuid, bytes, metadata, opts) do
      {:ok, %{file_id: file_id}}
    else
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  def list(args, %{context: context}) do
    actor = actor(context)
    space = Map.get(args, :space, "private")
    owner_did = Map.get(args, :owner_did)
    opts = [space: space] ++ if(owner_did, do: [owner_did: owner_did], else: [])

    case Files.list_recent(actor, context.tenant_uuid, opts) do
      {:ok, raw} -> {:ok, decode_files(raw)}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  @doc "Content-only upload — old REST POST /sync/blob equivalent."
  def upload_blob(%{file: %Plug.Upload{} = upload} = args, %{context: context}) do
    actor = actor(context)
    space = Map.get(args, :space, "private")
    owner_did = Map.get(args, :owner_did)
    opts = [space: space] ++ if(owner_did, do: [owner_did: owner_did], else: [])

    with {:ok, bytes} <- File.read(upload.path),
         {:ok, result} <- Files.upload_blob(actor, context.tenant_uuid, bytes, opts) do
      {:ok, result}
    else
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  @doc "Record-only sync for a blob uploaded separately — old REST POST /sync/record equivalent."
  def sync_record(%{input: input}, %{context: context}) do
    actor = actor(context)
    space = Map.get(input, :space, "private")
    owner_did = Map.get(input, :owner_did)

    metadata = %{
      filename: input.filename,
      content_type: Map.get(input, :content_type),
      size_bytes: Map.get(input, :size_bytes)
    }

    opts =
      [space: space]
      |> Keyword.merge(if owner_did, do: [owner_did: owner_did], else: [])
      |> Keyword.merge(if input[:file_id], do: [file_id: input.file_id], else: [])

    case Files.sync_record(actor, context.tenant_uuid, input.content_cas, metadata, opts) do
      {:ok, file_id} -> {:ok, %{file_id: file_id, status: "synced"}}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  @doc "CAS dedup ledger listing — old REST GET /sync/cas-meta equivalent."
  def list_cas_meta(args, %{context: context}) do
    actor = actor(context)
    owner_did = Map.get(args, :owner_did, context.did)

    case CasMeta.list(actor, context.tenant_uuid, owner_did) do
      {:ok, rows} -> {:ok, Enum.map(rows, &normalize_cas_meta_row/1)}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  @doc "Presigned blob download URL — old REST GET /sync/blob/:hash equivalent."
  def blob_download_url(args, %{context: context}) do
    actor = actor(context)
    space = Map.get(args, :space, "private")
    owner_did = Map.get(args, :owner_did, context.did)
    expires_in = Map.get(args, :expires_in, 300)

    case Files.download_url(actor, context.tenant_uuid, owner_did, args.hash, space: space, expires_in: expires_in) do
      {:ok, url} -> {:ok, %{url: url, expires_in: expires_in}}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp actor(context), do: %{did: context.did, origin_instance_id: nil, portable_grant: nil, roles: context.roles}

  defp normalize_cas_meta_row(row) do
    %{
      id: row["id"],
      hash: row["hash"],
      cas_uri: row["cas_uri"],
      uri: row["uri"],
      uri_type: row["uri_type"],
      space: row["space"],
      did: row["did"],
      ref_count: row["ref_count"],
      size_bytes: row["size_bytes"],
      created_at: row["created_at"],
      updated_at: row["updated_at"]
    }
  end

  defp decode_files(raw) do
    case Jason.decode(raw) do
      {:ok, decoded} when is_list(decoded) -> Enum.map(decoded, &normalize_file/1)
      {:ok, decoded} when is_map(decoded) -> [normalize_file(decoded)]
      _ -> []
    end
  end

  defp normalize_file(row) do
    %{
      id: row["id"],
      name: row["name"],
      mime_type: row["mime_type"],
      size_bytes: row["size_bytes"],
      content_cas: row["content_cas"]
    }
  end
end