defmodule PRZMA.PzDb.NIF do
  @moduledoc """
  Rustler NIF wrapper for the lean `przma_pzdb_nif` crate.

  LanceDB-backed pzdb:// primitives. When base_path is an s3:// URI, writes go
  straight to the object store (Linode/AWS/MinIO) via AWS_* env vars.
  No DuckDB, no calendar service.

  Each function returns {:ok, json_string} | {:error, reason}.
  """

  use Rustler,
    otp_app: :przma,
    crate:   "przma_pzdb_nif"

  def pzdb_upsert(_base_path, _table_path, _record_json, _merge_keys),
    do: :erlang.nif_error(:nif_not_loaded)

  def pzdb_batch_upsert(_base_path, _table_path, _records_json, _merge_keys),
    do: :erlang.nif_error(:nif_not_loaded)

  def pzdb_read(_base_path, _table_path, _record_id),
    do: :erlang.nif_error(:nif_not_loaded)

  def pzdb_read_many(_base_path, _table_path, _filter, _limit, _offset),
    do: :erlang.nif_error(:nif_not_loaded)

  def pzdb_soft_delete(_base_path, _table_path, _record_id, _deleted_by),
    do: :erlang.nif_error(:nif_not_loaded)

  def pzdb_version(_base_path, _table_path),
    do: :erlang.nif_error(:nif_not_loaded)

  def pzdb_provision_table(_base_path, _table_path, _schema_name),
    do: :erlang.nif_error(:nif_not_loaded)

  def pzdb_cache_invalidate(_base_path, _table_path),
    do: :erlang.nif_error(:nif_not_loaded)
end
