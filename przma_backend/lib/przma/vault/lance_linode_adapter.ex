defmodule Przma.Vault.LanceLinodeAdapter do
  @moduledoc """
  Implements Przma.Vault.NifAdapter against the REAL przma_pzdb_nif —
  found in the mentor's other repo (phoenix-chat-app-circle) at
  native/przma_pzdb_nif/src/lib.rs, with matching Elixir wrapper
  lib/przma/pzdb/{nif,pzdb}.ex, copied verbatim into this project.
  Replaces the earlier ExAws-JSON placeholder — this now calls real
  LanceDB write/read via PRZMA.PzDb.

  TWO REAL ARCHITECTURAL DECISIONS THIS FILE MAKES — flag both with
  your supervisor, not just take them on my say-so:

  1. NO tenant_uuid IN THE PHYSICAL PATH. PRZMA.PzDb.resolve/1's real,
     confirmed-working URI shape is
       pzdb://{did}/{service}/{space}/{table}/{record_id}
     — four segments, and tenant_uuid is NOT one of them anywhere in
     that code. Every S3 path shown earlier in this project's design
     (e.g. "{tenant_uuid}/{did}/vault/profile.lance/") does NOT match
     what the real NIF actually produces. This adapter drops
     tenant_id from the PHYSICAL path to match reality — tenant_uuid
     still flows through PzdbAuthorization and gets stamped into the
     row itself (`gid` field, see profile.ex) for app-level bookkeeping,
     it just isn't part of where the file lands in S3.

  2. "space" DEFAULTS TO "core". The real URI has a 4th segment
     ("space") this project's PzdbUri struct has no equivalent field
     for — our `namespace` (vault/public/professional) maps onto the
     real system's "service" position, not "space". Rather than
     invent a value with no basis, every write here defaults space to
     "core" (the value used in the real pzdb.ex's own example comment)
     until your team decides whether personas/circles need a real
     second axis here.

  Resulting real S3 path, e.g. keerthi's profile:
     s3://perkeep/did_przma_keerthi/vault/core/profile.lance
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

  # Our PzdbUri -> real pzdb://{did}/{service}/{space}/{table} — see
  # moduledoc for why tenant_id is dropped and space is "core".
  defp to_real_pzdb_uri(%PzdbUri{did: did, namespace: service, table: table}) do
    "pzdb://#{did}/#{service}/core/#{table}"
  end

  defp stringify_keys(row) when is_map(row) do
    Map.new(row, fn {k, v} -> {to_string(k), v} end)
  end

  defp escape(s), do: String.replace(s, "'", "''")
end
