defmodule PRZMAWeb.Graphql.Resolvers.FilesResolver do
  @moduledoc """
  Upload and list operations for the files service. Download is
  deliberately NOT exposed here — GraphQL responses are JSON, and
  returning raw file bytes would mean base64-encoding them inline,
  which is a poor fit for anything beyond small files. A plain REST
  endpoint (streaming the bytes directly) is the better shape for
  download; not built in this pass — flagging so it isn't mistaken
  for an oversight.

  `list/2` calls Przma.Vault.Files.list_recent/3, which goes through
  PzdbConnector.read_many/2 -> LanceLinodeAdapter.query_many/1 (a
  `did` COLUMN filter, no limit) instead of the old single-record
  query/2 path — this is the fix for files having many rows per did,
  each with its own generated id, unlike profile's one row per did.
  query/2 itself (used by profile.ex) is untouched by this.
  """

  alias Przma.Vault.Files

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

  defp actor(context), do: %{did: context.did, origin_instance_id: nil, portable_grant: nil, roles: context.roles}

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