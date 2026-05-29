# lib/przma/stubs.ex
#
# Minimal stubs for the 3 external modules that pzdb files call.
# These replace the real Rust NIF, EncryptionContext, and MetadataIndex
# so the 7 pzdb files can compile and run without the full Phoenix app.

# ── 1. NIF stub ──────────────────────────────────────────────────────────────
# pzdb.ex and compaction.ex call PRZMA.Calendar.NIF for storage operations.
# These stubs return fake but valid JSON responses.

defmodule PRZMA.Calendar.NIF do
  @moduledoc "Stub — returns fake storage responses so pzdb files compile."

  def pzdb_upsert(_base, _path, _json, _opts),
    do: {:ok, ~s({"record_id":"stub-id","version":1,"attempts":1,"latency_us":100})}

  def pzdb_batch_upsert(_base, _path, _json, _opts),
    do: {:ok, ~s({"count":1,"version":1,"latency_us":100})}

  def pzdb_read(_base, _path, _id, _min_ver),
    do: {:ok, ~s({"record":null,"version":1,"found":false})}

  def pzdb_read_many(_base, _path, _filter, _limit, _ver),
    do: {:ok, ~s({"records":[],"version":1})}

  def pzdb_soft_delete(_base, _path, _id, _by),
    do: {:ok, ~s({"record_id":"stub-id","version":2})}

  def pzdb_compact(_base, _path),
    do: {:ok, ~s({"rows_compacted":0,"duration_ms":1})}

  def pzdb_version(_base, _path),
    do: {:ok, "1"}

  def pzdb_provision_table(_base, _path, _schema),
    do: {:ok, ~s({"created":true})}
end

# ── 2. EncryptionContext stub ─────────────────────────────────────────────────
# pzdb.ex calls this to encrypt/decrypt field values before writing to Lance.
# Stub just passes data through unchanged (no encryption in dev mode).

defmodule PRZMA.Calendar.Storage.EncryptionContext do
  @moduledoc "Stub — passes data through without encryption."

  def encryption_available?(_did), do: false

  def encrypt(_did, _namespace, value),
    do: {:ok, value}

  def decrypt(_did, _namespace, value),
    do: {:ok, value}
end

# ── 3. MetadataIndex stub ─────────────────────────────────────────────────────
# pzdb.ex calls this (async, in a Task) after every write to update the
# cross-service search index. Stub does nothing — safe to ignore in dev.

defmodule PRZMA.Platform.MetadataIndex do
  @moduledoc "Stub — ignores index/deindex calls."

  def index(_did, _uri, _opts \\ []), do: :ok
  def deindex(_did, _uri),           do: :ok
end
