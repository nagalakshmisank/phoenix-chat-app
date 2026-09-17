defmodule Przma.Vault.CasMeta do
  @moduledoc """
  Dedup ledger for Przma.Vault.Cas — the metadata table equivalent of
  the old przma-phoenix `cas_meta` Lance table.

  Cas.put/3 already dedups the physical bytes (one S3 object per
  unique hash per {did, namespace}), but the physical store alone
  can't answer "how many file records point at this blob" or "what's
  the external-facing URI for this hash". That's this module's job:
  one row per unique content hash, `ref_count` incremented every time
  any space's file record references that hash.

  Deliberately keyed the same way Cas keys physical bytes — by
  {did, namespace} only, NOT by space (see Cas moduledoc): a blob
  uploaded into "private" and later referenced from "public" is still
  one physical object and one ledger row, `ref_count` 2.

  Lives in a FIXED space — `"cas"` — regardless of which space(s)
  actually reference the blob. `"cas"` is the same folder Cas.put/3
  already writes raw blob shards into (see Cas moduledoc: dedup is
  per {did, namespace}, not per space), so the ledger sits right next
  to the bytes it describes rather than nested inside one of the
  three real spaces. Ledger reads/writes are always same-DID (owner
  reading/writing their own dedup ledger), which is authorized under
  PzdbAuthorization.check_owner_or_grant/3 regardless of the space
  string on the URI — so this placement doesn't change authorization
  at all. Which space(s) actually referenced the blob is instead
  carried as a plain FIELD on each row (see record/4).

  Physical path (via LanceLinodeAdapter): pzdb://{did}/files/cas/cas_meta
    -> s3://<bucket>/{sanitized_did}/files/cas/cas_meta.lance/
       (a sibling of files/cas/{shard}/{hash} — the raw blob shards)

  Table name "cas_meta" is not just a label — it's the literal string
  the Rust NIF's schema_for/1 and pzdb_upsert/4 match on
  (native/przma_pzdb_nif/src/lib.rs) to pick cas_meta_schema() and
  json_to_cas_meta_batch/1 instead of falling through to the generic
  files-table path. Renaming @table would silently misroute writes.
  """

  alias Przma.Vault.{PzdbConnector, PzdbUri}

  @namespace "files"
  @ledger_space "cas"
  @table "cas_meta"

  @type row :: %{
          id: String.t(),
          hash: String.t(),
          cas_uri: String.t(),
          uri: String.t(),
          uri_type: String.t(),
          s3_uri: String.t(),
          space: String.t(),
          did: String.t(),
          ref_count: integer(),
          size_bytes: integer(),
          created_at: integer(),
          updated_at: integer()
        }

  @doc """
  Records that `digest` was just written (or re-referenced) by `space`
  under `owner_did`. Read-modify-write, same pattern as the old
  controller's record_cas_meta/5 — the real pzdb_upsert NIF has no
  atomic increment, so the current ref_count is read first.

  Not itself an authorization gate for the CAS write that preceded
  it — Cas.put/3 already ran that check against `uri` before any
  bytes touched S3. This call authorizes separately (same actor,
  ledger's own pseudo-URI) purely to reach the ledger table.
  """
  @spec record(
          actor :: PzdbConnector.actor(),
          tenant_uuid :: String.t(),
          owner_did :: String.t(),
          digest :: String.t(),
          size_bytes :: integer(),
          space :: String.t()
        ) :: {:ok, non_neg_integer()} | {:error, term()}
  def record(actor, tenant_uuid, owner_did, digest, size_bytes, space) do
    uri_string = build_uri(tenant_uuid, owner_did)
    ref_count = current_ref_count(actor, uri_string, digest) + 1

    row = %{
      id: digest,
      hash: digest,
      cas_uri: "cas:#{digest}",
      uri: shareable_uri(digest, owner_did),
      uri_type: "graphql",
      s3_uri: internal_s3_uri(owner_did, digest),
      space: space,
      did: owner_did,
      gid: tenant_uuid,
      ref_count: ref_count,
      size_bytes: size_bytes,
      created_at: System.os_time(:microsecond),
      updated_at: System.os_time(:microsecond)
    }

    case PzdbConnector.write(actor, uri_string, [row]) do
      :ok -> {:ok, ref_count}
      {:error, _} = err -> err
    end
  end

  @doc "Lists every ledger row (one per unique blob) for `owner_did` — the CAS-meta equivalent of Files.list_recent/3."
  @spec list(actor :: PzdbConnector.actor(), tenant_uuid :: String.t(), owner_did :: String.t()) ::
          {:ok, [map()]} | {:error, term()}
  def list(actor, tenant_uuid, owner_did) do
    uri_string = build_uri(tenant_uuid, owner_did)

    case PzdbConnector.read_many(actor, uri_string) do
      {:ok, raw} -> {:ok, decode_rows(raw)}
      {:error, _} = err -> err
    end
  end

  # -- private -------------------------------------------------------

  defp current_ref_count(actor, uri_string, digest) do
    case PzdbConnector.read_by_id(actor, uri_string, digest) do
      {:ok, raw} ->
        case Jason.decode(raw) do
          {:ok, %{"ref_count" => rc}} when is_integer(rc) -> rc
          _ -> 0
        end

      {:error, _} ->
        0
    end
  end

  defp build_uri(tenant_uuid, did) do
    %PzdbUri{
      transport: :s3,
      tenant_id: tenant_uuid,
      did: did,
      namespace: @namespace,
      space: @ledger_space,
      table: @table
    }
    |> PzdbUri.to_string()
  end

  # Client-facing reference — routed through the GraphQL blobDownloadUrl
  # query (see FilesResolver), which re-authorizes before ever touching
  # S3. Never the s3_uri below.
  defp shareable_uri(digest, owner_did) do
    "/api/graphql#blobDownloadUrl(hash:\"#{digest}\",owner:\"#{owner_did}\")"
  end

  # Internal/analytics only — mirrors Cas's own cas_key/2 shape.
  # NEVER returned over GraphQL (see FilesTypes.cas_meta_row — no
  # s3_uri field is exposed there on purpose).
  defp internal_s3_uri(did, digest) do
    shard = String.slice(digest, 0, 2)
    sanitized_did = String.replace(did, [":", " "], "_")
    endpoint = vault_config(:s3_endpoint) || ""
    bucket = vault_config(:s3_bucket)
    "#{endpoint}/#{bucket}/#{sanitized_did}/#{@namespace}/cas/#{shard}/#{digest}"
  end

  defp vault_config(key), do: Application.get_env(:przma, :vault) |> Keyword.get(key)

  defp decode_rows(raw) do
    case Jason.decode(raw) do
      {:ok, decoded} when is_list(decoded) -> decoded
      {:ok, decoded} when is_map(decoded) -> [decoded]
      _ -> []
    end
  end
end
