defmodule Przma.Vault.NifAdapter do
  @moduledoc """
  Behaviour boundary between the new authorization/connector layer
  (PzdbConnector, this module's caller) and the actual Rustler NIF.

  THIS EXISTS BECAUSE past design sessions produced at least three
  different NIF function signatures for what appears to be the same
  underlying operations:

    1. A thin surface: insert_batch/3, query_vector/4, compact/1, get_version/1
    2. A per-table, JSON-encoded, credentials-per-call version:
       LanceNIF.insert_perception_events/5, insert_preserve_events/5,
       initialize_vault/4
    3. The mobile devkit's generic version: open/insert/merge_insert/
       query_since/search/compact/current_version

  These don't fully agree with each other (JSON vs. Arrow IPC binary,
  credentials passed per-call vs. pooled by URI). Rather than guess
  which one is actually live in the current codebase and write
  PzdbConnector against it directly — risking new code that doesn't
  compile against real NIF exports — every NIF call in this package
  goes through this behaviour. Reconciling with the real signature is
  then a single-module fix (implement this behaviour against whatever
  the actual NIF exports), not a rewrite of the authorization or
  connector logic.

  Implement one module satisfying this behaviour per your actual NIF,
  and configure it via `config :przma, :vault_nif_adapter, YourModule`.
  """

  alias Przma.Vault.PzdbUri

  @type row :: map()
  @type arrow_ipc_binary :: binary()

  @doc "Open (or fetch from an existing pool) the store this URI resolves to. Idempotent."
  @callback open(PzdbUri.t()) :: :ok | {:error, term()}

  @doc "Insert/append rows. Implementation decides row encoding (JSON vs. Arrow IPC) — this behaviour is encoding-agnostic on purpose, since that's exactly the part unconfirmed."
  @callback insert(PzdbUri.t(), rows :: [row()] | arrow_ipc_binary()) :: :ok | {:error, term()}

  @doc "Upsert via merge_insert semantics — confirmed real LanceDB Rust API (Table::merge_insert) across every past session that reached the sync-design stage."
  @callback merge_insert(PzdbUri.t(), rows :: [row()] | arrow_ipc_binary(), on :: [atom()]) ::
              :ok | {:error, term()}

  @doc "Query, optionally with an SQL predicate (QueryBase::only_if) and/or vector search."
  @callback query(PzdbUri.t(), opts :: keyword()) :: {:ok, arrow_ipc_binary()} | {:error, term()}

  @doc """
  Query ALL rows matching this URI's did — a `did` COLUMN filter, not
  `id`, and no limit. Separate from query/2 on purpose: query/2 is
  built for one-row-per-did tables (profile) and is relied on,
  unchanged, by existing code; this is for many-rows-per-did tables
  (files, and future chat/calendar/AI) where each row has its own
  distinct id and `did` only identifies the OWNER, not the row.
  """
  @callback query_many(PzdbUri.t()) :: {:ok, arrow_ipc_binary()} | {:error, term()}
  
  @doc "Cursor-based sync query — rows with updated_at after `since`, per the confirmed timestamp-cursor sync design (Lance has no row-level version-diff API)."
  @callback query_since(PzdbUri.t(), since :: DateTime.t()) :: {:ok, arrow_ipc_binary()} | {:error, term()}

  @doc "Compact fragments — periodic maintenance, not per-write."
  @callback compact(PzdbUri.t()) :: :ok | {:error, term()}

  @doc "Fetch a single chunk by its BLAKE3 CAS address — content-addressed, immutable."
  @callback fetch_chunk(PzdbUri.t(), chunk_address :: String.t()) ::
              {:ok, arrow_ipc_binary()} | {:error, :not_found | term()}

  @spec adapter() :: module()
  def adapter, do: Application.fetch_env!(:przma, :vault_nif_adapter)
end
