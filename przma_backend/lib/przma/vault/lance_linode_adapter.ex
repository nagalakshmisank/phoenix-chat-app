defmodule Przma.Vault.LanceLinodeAdapter do
  @moduledoc """
  Implements Przma.Vault.NifAdapter against the REAL przma_pzdb_nif —
  found in the mentor's other repo (phoenix-chat-app-circle) at
  native/przma_pzdb_nif/src/lib.rs, with matching Elixir wrapper
  lib/przma/pzdb/{nif,pzdb}.ex, copied verbatim into this project.

  ARCHITECTURAL DECISION, now resolved (was previously an open
  question flagged in this moduledoc — space defaulted to "core"):

  NO tenant_uuid IN THE PHYSICAL PATH. PRZMA.PzDb.resolve/1's real,
  confirmed-working URI shape is
    pzdb://{did}/{service}/{space}/{table}/{record_id}
  — four segments, tenant_uuid is not one of them. tenant_uuid still
  flows through PzdbAuthorization and gets stamped into the row itself
  (`gid` field, see profile.ex) for app-level bookkeeping — it just
  isn't part of where the file lands in S3.

  "space" now comes from PzdbUri.t()'s real `space` field (one of
  "private" | "public" | "personal") instead of a hardcoded "core" —
  every namespace/service gets these 3 physical sub-partitions.

  Resulting real S3 path, e.g. kc_user1's profile (private space):
     s3://perkeep/did_przma_kc_user1/vault/private/profile.lance
  """

  @behaviour Przma.Vault.NifAdapter

  alias Przma.Vault.PzdbUri

  @impl true
  def open(%PzdbUri{} = _uri), do: :ok

  @impl true
  def insert(%PzdbUri{} = uri, rows) when is_list(rows) do
    real_uri = to_real_pzdb_uri(uri)

    Enum.reduce_while(rows, :ok, fn row, :ok ->
      case PRZMA.PzDb.write(real_uri, stringify_keys(row)) do
        {:ok, _} -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  @impl true
  def merge_insert(%PzdbUri{} = uri, rows, _on) when is_list(rows) do
    # Real pzdb_upsert genuinely deletes-by-id then adds — a real
    # upsert, not the placeholder's plain overwrite. Same call as
    # insert/2; PzDb.write/2 always upserts.
    insert(uri, rows)
  end

  @impl true
  def query(%PzdbUri{did: did} = uri, _opts) do
    # IMPORTANT: the real pzdb_read (single-record fetch) is a STUB in
    # lib.rs — always returns {"record": null}, never wired to a real
    # lookup. So every read here goes through pzdb_read_many (which IS
    # real) with a `did = '...'` filter and limit 1, not a direct
    # single-record read. See lib.rs's own "STUBS" section comment.
    real_uri = to_real_pzdb_uri(uri)

    case PRZMA.PzDb.query(real_uri, filter: "id = '#{escape(did)}'", limit: 1) do
      {:ok, %{"records" => [record | _]}} -> {:ok, Jason.encode!(record)}
      {:ok, %{"records" => []}} -> {:error, :not_found}
      {:ok, _other} -> {:error, :not_found}
      {:error, _} = err -> err
    end
  end

  @impl true
  def query_since(%PzdbUri{} = _uri, _since), do: {:error, :not_implemented}

  @impl true
  def compact(%PzdbUri{} = _uri), do: :ok

  @impl true
  def fetch_chunk(%PzdbUri{} = _uri, _chunk_address), do: {:error, :not_implemented}

  # -- internal --------------------------------------------------------

  # Our PzdbUri -> real pzdb://{did}/{service}/{space}/{table}.
  # tenant_id dropped per moduledoc; space now real, not "core".
  defp to_real_pzdb_uri(%PzdbUri{did: did, namespace: service, space: space, table: table}) do
    "pzdb://#{did}/#{service}/#{space}/#{table}"
  end

  defp stringify_keys(row) when is_map(row) do
    Map.new(row, fn {k, v} -> {to_string(k), v} end)
  end

  defp escape(s), do: String.replace(s, "'", "''")
end