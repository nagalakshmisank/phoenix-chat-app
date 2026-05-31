# lib/przma/calendar/nif.ex
defmodule PRZMA.Calendar.NIF do
  @moduledoc "Real Rust NIF — delegates to LanceDB via Rustler."

  use Rustler,
    otp_app: :pzdb,
    crate:   :pzdb_nif

  # Each function body is the fallback when the NIF is not loaded.
  # (Rustler replaces them at runtime with the real Rust implementation.)

  def pzdb_upsert(_base, _path, _json, _opts),
    do: :erlang.nif_error(:nif_not_loaded)

  def pzdb_batch_upsert(_base, _path, _json, _opts),
    do: :erlang.nif_error(:nif_not_loaded)

  def pzdb_read(_base, _path, _id, _min_ver),
    do: :erlang.nif_error(:nif_not_loaded)

  def pzdb_read_many(_base, _path, _filter, _limit, _ver),
    do: :erlang.nif_error(:nif_not_loaded)

  def pzdb_soft_delete(_base, _path, _id, _by),
    do: :erlang.nif_error(:nif_not_loaded)

  def pzdb_compact(_base, _path),
    do: :erlang.nif_error(:nif_not_loaded)

  def pzdb_version(_base, _path),
    do: :erlang.nif_error(:nif_not_loaded)

  def pzdb_provision_table(_base, _path, _schema),
    do: :erlang.nif_error(:nif_not_loaded)
end