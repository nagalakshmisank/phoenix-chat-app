defmodule PRZMA.PzDb do
  @moduledoc """
  Lean pzdb:// facade over PRZMA.PzDb.NIF (LanceDB, S3-capable).

  This is the slim production path used by the file-sync API: it calls the NIF
  directly — no WriteRouter / VaultWriter / HealthMonitor supervision stack and
  no encryption layer. Enough to write file records and CAS blobs to remote
  Lance (Linode S3 when base_path is an s3:// URI).

  URI form:  pzdb://{did}/{service}/{space}/{table}/{record_id}
  Table path: {sanitized_did}_{service}_{space}_{table}  (flat, S3-key safe)
  """

  alias PRZMA.PzDb.NIF
  require Logger

  # Resolved at runtime so it can point at an s3:// URI (Linode) set in runtime.exs.
  defp global_base, do: Application.get_env(:przma, :vault_base_path, "/var/przma/vaults")

  # ── WRITE ─────────────────────────────────────────────────────────────────

  @doc "Upsert a record at a pzdb:// URI. Backfills required `files` columns."
  def write(pzdb_uri, record, _opts \\ []) when is_binary(pzdb_uri) and is_map(record) do
    {base, table} = resolve(pzdb_uri)
    record        = backfill(record)

    NIF.pzdb_upsert(base, table, Jason.encode!(record), Jason.encode!(["id"]))
    |> to_result()
  end

  # ── QUERY ─────────────────────────────────────────────────────────────────

  @doc "Query many records under a table URI with an optional SQL filter."
  def query(pzdb_table_uri, opts \\ []) when is_binary(pzdb_table_uri) do
    {base, table} = resolve(pzdb_table_uri)
    filter        = Keyword.get(opts, :filter, "")
    limit         = Keyword.get(opts, :limit, 500)

    NIF.pzdb_read_many(base, table, filter, limit, 0)
    |> to_result()
  end

  # ── ENSURE TABLE ──────────────────────────────────────────────────────────

  @doc """
  Create the table if missing. The schema name is the table segment of the URI
  (e.g. "files"), which must match a known schema in the NIF's `schema_for/1`.
  """
  def ensure_table(pzdb_table_uri) when is_binary(pzdb_table_uri) do
    {base, table} = resolve(pzdb_table_uri)

    case NIF.pzdb_provision_table(base, table, table) |> to_result() do
      {:ok, _}         -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # ── PRIVATE ───────────────────────────────────────────────────────────────

  # pzdb://{did}/{service}/{space}/{table}/{record_id}
  #
  #   connection URI : {global_base}/{did}/{service}/{space}
  #   table (dataset): {table}   →  {connection_uri}/{table}.lance
  #
  # The hierarchy lives in the CONNECTION URI, not the table name, because
  # LanceDB rejects "/" inside a table name. This yields a clean, browsable
  # object-store layout that mirrors the CAS blobs, e.g.:
  #
  #   s3://perkeep/did_web_alice.com/files/core/files.lance
  #
  # (DID colons are sanitised to underscores; the global base — which contains
  # "s3://" — is never sanitised.)
  defp resolve(pzdb_uri) do
    "pzdb://" <> rest = pzdb_uri

    case String.split(rest, "/") do
      [did, service, space, table | _] ->
        base = Enum.join([global_base(), seg(did), seg(service), seg(space)], "/")
        {base, seg(table)}

      parts ->
        {global_base(), seg(Enum.join(parts, "_"))}
    end
  end

  # Sanitise a single path segment. Never introduces "/", so each segment stays
  # one level deep (colons in DIDs and spaces → underscores).
  defp seg(s), do: String.replace(s, [":", " "], "_")

  # Normalise NIF return values. Different NIF builds return either a tagged
  # tuple ({:ok, json} | {:error, reason}) or a bare JSON string on success —
  # accept both so we don't depend on a specific NIF build.
  defp to_result({:ok, json}) when is_binary(json), do: decode_json(json)
  defp to_result({:error, reason}), do: {:error, reason}
  defp to_result(json) when is_binary(json), do: decode_json(json)
  defp to_result(other), do: {:error, "unexpected NIF return: #{inspect(other)}"}

  defp decode_json(json) do
    case Jason.decode(json) do
      {:ok, map} when is_map(map) -> {:ok, map}
      # Non-JSON (or non-object) success payload — treat as an opaque success.
      _ -> {:ok, %{}}
    end
  end

  # Fill non-nullable `files` schema columns the client may omit, so the
  # runtime JSON→RecordBatch conversion never hits a NULL on a required field.
  defp backfill(record) do
    now = System.os_time(:microsecond)

    defaults = %{
      "space"           => "core",
      "name"            => "",
      "path"            => "",
      "mime_type"       => "application/octet-stream",
      "size_bytes"      => 0,
      "content_cas"     => "",
      "versions_json"   => "[]",
      "current_version" => 1,
      "tags_json"       => "[]",
      "is_public"       => false,
      "is_encrypted"    => false,
      "upload_status"   => "synced",
      "created_at"      => now,
      "updated_at"      => now
    }

    Map.merge(defaults, record)
  end
end
