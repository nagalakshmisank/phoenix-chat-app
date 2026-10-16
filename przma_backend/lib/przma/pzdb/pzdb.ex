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

  # ── DOC STORE (used only by Przma.Vault.LanceDocAdapter) ──────────────────
  #
  # Same resolve/1 as write/query above, so a doc table lands next to every
  # other pzdb table:  pzdb://{did}/{service}/{space}/{table}
  #                 -> {global_base}/{did}/{service}/{space}/{table}.lance
  # No backfill/2 here: doc tables use doc_schema (lib.rs), not files_schema.

  @doc "Upsert doc rows (list of maps) by id in ONE Lance commit."
  def doc_upsert(pzdb_table_uri, rows) when is_binary(pzdb_table_uri) and is_list(rows) do
    {base, table} = resolve(pzdb_table_uri)

    NIF.pzdb_doc_upsert(base, table, Jason.encode!(rows))
    |> to_result()
  end

  @doc "Doc rows matching an SQL filter (\"\" = all), unordered, at most `limit`."
  def doc_query(pzdb_table_uri, filter, limit) when is_binary(pzdb_table_uri) and is_binary(filter) do
    {base, table} = resolve(pzdb_table_uri)

    NIF.pzdb_doc_query(base, table, filter, limit)
    |> to_result()
  end

  @doc "Compact small files and prune versions older than `keep_hours`."
  def doc_optimize(pzdb_table_uri, keep_hours) when is_binary(pzdb_table_uri) and is_integer(keep_hours) do
    {base, table} = resolve(pzdb_table_uri)

    NIF.pzdb_doc_optimize(base, table, keep_hours)
    |> to_result()
  end

  @doc "Row count and current version of a doc table (tests / monitoring)."
  def doc_stats(pzdb_table_uri) when is_binary(pzdb_table_uri) do
    {base, table} = resolve(pzdb_table_uri)

    NIF.pzdb_doc_stats(base, table)
    |> to_result()
  end

  # ── VECTOR SEARCH (used only by Przma.Search) ─────────────────────────────
  #
  #   pzdb://{did}/search/{space}/chunks -> {global_base}/{did}/search/{space}/chunks.lance
  #
  # The NIF embeds the text itself (model inside the NIF). Writes must run
  # inside Przma.Storage.DocWriter.

  @doc "Loads the embedding model; returns its name, vector size and load time."
  def vec_model_info, do: NIF.pzdb_vec_model_info() |> to_result()

  @doc "Embeds a list of texts. Vectors are returned only when include_vectors is true."
  def vec_embed(texts, include_vectors \\ false) when is_list(texts) do
    NIF.pzdb_vec_embed(Jason.encode!(texts), include_vectors) |> to_result()
  end

  @doc "Embeds each row's `text` and upserts the rows by id in ONE commit."
  def vec_upsert(pzdb_table_uri, rows) when is_binary(pzdb_table_uri) and is_list(rows) do
    {base, table} = resolve(pzdb_table_uri)
    NIF.pzdb_vec_upsert(base, table, Jason.encode!(rows)) |> to_result()
  end

  @doc "Closest rows to `query_text` (cosine), optional SQL filter, nprobes for indexed tables."
  def vec_search(pzdb_table_uri, query_text, limit, filter \\ "", nprobes \\ 20)
      when is_binary(pzdb_table_uri) and is_binary(query_text) do
    {base, table} = resolve(pzdb_table_uri)
    NIF.pzdb_vec_search(base, table, query_text, limit, filter, nprobes) |> to_result()
  end

  @doc "Rows matching an SQL filter (no vectors), e.g. keyword LIKE search."
  def vec_query(pzdb_table_uri, filter, limit) when is_binary(pzdb_table_uri) and is_binary(filter) do
    {base, table} = resolve(pzdb_table_uri)
    NIF.pzdb_vec_query(base, table, filter, limit) |> to_result()
  end

  @doc "Deletes rows matching an SQL filter (must not be empty)."
  def vec_delete(pzdb_table_uri, filter) when is_binary(pzdb_table_uri) and is_binary(filter) do
    {base, table} = resolve(pzdb_table_uri)
    NIF.pzdb_vec_delete(base, table, filter) |> to_result()
  end

  @doc "Builds the IVF-PQ vector index (0 = automatic value)."
  def vec_index(pzdb_table_uri, num_partitions \\ 0, num_sub_vectors \\ 0) when is_binary(pzdb_table_uri) do
    {base, table} = resolve(pzdb_table_uri)
    NIF.pzdb_vec_index(base, table, num_partitions, num_sub_vectors) |> to_result()
  end

  @doc "Compacts small files and prunes old versions of a vector table."
  def vec_optimize(pzdb_table_uri, keep_hours) when is_binary(pzdb_table_uri) and is_integer(keep_hours) do
    {base, table} = resolve(pzdb_table_uri)
    NIF.pzdb_vec_optimize(base, table, keep_hours) |> to_result()
  end

  @doc "Row count, version, vector size and index names of a vector table."
  def vec_stats(pzdb_table_uri) when is_binary(pzdb_table_uri) do
    {base, table} = resolve(pzdb_table_uri)
    NIF.pzdb_vec_stats(base, table) |> to_result()
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
