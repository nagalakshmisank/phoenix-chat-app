# lib/przma/pzdb/pzdb.ex
#
# Lean pzdb:// facade over PRZMA.PzDb.NIF (LanceDB, S3-capable).
#
# Layout now goes through PRZMA.Platform.Namespace, so the backend mirrors the
# local desktop vault exactly: LanceDB connects at a nested per-(did, service,
# space) prefix and uses a simple table name, producing
#   {root}/{did}/files/{space}/files.lance/
# which equals the local
#   {base}/{did}/files/{space}/files.lance/.
#
# When :vault_base_path is an s3:// URI (Linode), the NIF writes straight to S3.

defmodule PRZMA.PzDb do
  alias PRZMA.PzDb.NIF
  alias PRZMA.Platform.Namespace
  require Logger

  # Resolved at runtime so it can be an s3:// URI (set in runtime.exs).
  defp root, do: Application.get_env(:przma, :vault_base_path, "/var/przma/vaults")

  # ── WRITE ──────────────────────────────────────────────────────────────────

  @doc "Upsert a record at a pzdb:// URI. Backfills required `files` columns."
  def write(pzdb_uri, record, _opts \\ []) when is_binary(pzdb_uri) and is_map(record) do
    {dir, table} = Namespace.resolve(root(), pzdb_uri)
    record = backfill(record)

    case NIF.pzdb_upsert(dir, table, Jason.encode!(record), "id") do
      {:ok, json} -> {:ok, Jason.decode!(json)}
      {:error, msg} -> {:error, msg}
    end
  end

  # ── QUERY ──────────────────────────────────────────────────────────────────

  @doc "Query many records under a table URI with an optional SQL filter."
  def query(pzdb_table_uri, opts \\ []) when is_binary(pzdb_table_uri) do
    {dir, table} = Namespace.resolve(root(), pzdb_table_uri)
    filter = Keyword.get(opts, :filter, "")
    limit = Keyword.get(opts, :limit, 500)

    case NIF.pzdb_read_many(dir, table, filter, limit, 0) do
      {:ok, json} -> {:ok, Jason.decode!(json)}
      {:error, msg} -> {:error, msg}
    end
  end

  # ── ENSURE TABLE ─────────────────────────────────────────────────────────────

  @doc """
  Create the table if missing. `schema_name` defaults to "files" so the existing
  1-arg callers in the controller keep working.
  """
  def ensure_table(pzdb_table_uri, schema_name \\ "files") when is_binary(pzdb_table_uri) do
    {dir, table} = Namespace.resolve(root(), pzdb_table_uri)

    case NIF.pzdb_provision_table(dir, table, schema_name) do
      {:ok, _} -> :ok
      {:error, msg} -> {:error, msg}
    end
  end

  # ── PRIVATE ──────────────────────────────────────────────────────────────────

  # Fill non-nullable `files` columns the client may omit so the JSON->RecordBatch
  # conversion in the NIF never hits a NULL on a required field. The client sends
  # the full 22-field record on /sync/record, so these are just safety defaults.
  defp backfill(record) do
    now = System.os_time(:microsecond)

    defaults = %{
      "space" => "core",
      "name" => "",
      "path" => "",
      "mime_type" => "application/octet-stream",
      "size_bytes" => 0,
      "content_cas" => "",
      "versions_json" => "[]",
      "current_version" => 1,
      "tags_json" => "[]",
      "is_public" => false,
      "is_encrypted" => false,
      "upload_status" => "synced",
      "synced" => true,
      "created_at" => now,
      "updated_at" => now,
      "embedding" => List.duplicate(0.0, 768)
    }

    Map.merge(defaults, record)
  end
end