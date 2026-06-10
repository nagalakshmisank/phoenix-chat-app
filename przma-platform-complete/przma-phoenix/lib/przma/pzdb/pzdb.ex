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
  defp base_path, do: Application.get_env(:przma, :vault_base_path, "/var/przma/vaults")

  # ── WRITE ─────────────────────────────────────────────────────────────────

  @doc "Upsert a record at a pzdb:// URI. Backfills required `files` columns."
  def write(pzdb_uri, record, _opts \\ []) when is_binary(pzdb_uri) and is_map(record) do
    table_path = resolve_table_path(pzdb_uri)
    record     = backfill(record)

    case NIF.pzdb_upsert(base_path(), table_path, Jason.encode!(record), "id") do
      {:ok, json}   -> {:ok, Jason.decode!(json)}
      {:error, msg} -> {:error, msg}
    end
  end

  # ── QUERY ─────────────────────────────────────────────────────────────────

  @doc "Query many records under a table URI with an optional SQL filter."
  def query(pzdb_table_uri, opts \\ []) when is_binary(pzdb_table_uri) do
    table_path = resolve_table_path(pzdb_table_uri)
    filter     = Keyword.get(opts, :filter, "")
    limit      = Keyword.get(opts, :limit, 500)

    case NIF.pzdb_read_many(base_path(), table_path, filter, limit, 0) do
      {:ok, json}   -> {:ok, Jason.decode!(json)}
      {:error, msg} -> {:error, msg}
    end
  end

  # ── ENSURE TABLE ──────────────────────────────────────────────────────────

  @doc "Create the table if missing. schema_name is \"files\" or \"cas_blobs\"."
  def ensure_table(pzdb_table_uri, schema_name) when is_binary(pzdb_table_uri) do
    table_path = resolve_table_path(pzdb_table_uri)

    case NIF.pzdb_provision_table(base_path(), table_path, schema_name) do
      {:ok, _}      -> :ok
      {:error, msg} -> {:error, msg}
    end
  end

  # ── PRIVATE ───────────────────────────────────────────────────────────────

  # pzdb://did/service/space/table/record_id → "did_service_space_table"
  # (did colons sanitised to underscores so it is a valid Lance table name)
  defp resolve_table_path(pzdb_uri) do
    "pzdb://" <> rest = pzdb_uri
    parts = String.split(rest, "/")

    case parts do
      [did, service, space, table | _] ->
        [did, service, space, table]
        |> Enum.join("_")
        |> sanitize()

      _ ->
        sanitize(Enum.join(parts, "_"))
    end
  end

  defp sanitize(s), do: String.replace(s, [":", "/", " "], "_")

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
