defmodule PRZMA.PzDb do
  @moduledoc """
  Lean pzdb:// facade over PRZMA.PzDb.NIF (LanceDB, S3-capable).
  """

  alias PRZMA.PzDb.NIF
  require Logger

  defp global_base, do: Application.get_env(:przma, :vault_base_path, "/var/przma/vaults")

  # ── WRITE ─────────────────────────────────────────────────────────────────

  @doc "Upsert a record at a pzdb:// URI. Backfills required `files` columns — only for the files table."
  def write(pzdb_uri, record, _opts \\ []) when is_binary(pzdb_uri) and is_map(record) do
    {base, table} = resolve(pzdb_uri)
    record        = if table == "files", do: backfill(record), else: record

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

  def ensure_table(pzdb_table_uri) when is_binary(pzdb_table_uri) do
    {base, table} = resolve(pzdb_table_uri)

    case NIF.pzdb_provision_table(base, table, table) |> to_result() do
      {:ok, _}         -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # ── COMPACT (NEW) ─────────────────────────────────────────────────────────

  @doc "Merge small Lance fragments in a table into fewer, larger files. Safe to call on a hot table."
  def compact(pzdb_table_uri) when is_binary(pzdb_table_uri) do
    {base, table} = resolve(pzdb_table_uri)

    NIF.pzdb_compact(base, table)
    |> to_result()
  end

  # ── PRIVATE ───────────────────────────────────────────────────────────────

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

  defp seg(s), do: String.replace(s, [":", " "], "_")

  defp to_result({:ok, json}) when is_binary(json), do: decode_json(json)
  defp to_result({:error, reason}), do: {:error, reason}
  defp to_result(json) when is_binary(json), do: decode_json(json)
  defp to_result(other), do: {:error, "unexpected NIF return: #{inspect(other)}"}

  defp decode_json(json) do
    case Jason.decode(json) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _ -> {:ok, %{}}
    end
  end

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