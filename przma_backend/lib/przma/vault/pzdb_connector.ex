defmodule Przma.Vault.PzdbConnector do
  @moduledoc """
  The single public entry point for pzdb:// access. Every caller —
  Profile, SpaceProvisioner, any future domain module — goes through
  here, never calls Przma.Vault.NifAdapter directly, so authorization
  always runs before any LanceDB/S3 operation.

  DEVIATION FROM THE MENTOR'S ZIP: the original route_write/route_upsert
  called Przma.LanceWriter.for_did/1, a per-DID GenServer whose
  existence was never confirmed against the real codebase (flagged
  repeatedly in this build's chat history). For this standalone,
  Tier-1-default project, writes call NifAdapter directly instead —
  simpler, and correct until/unless a real per-DID write-serialization
  GenServer is confirmed to exist and reintroduced deliberately.

  BACKEND ROUTING (CouchDB phase): after parse + authorize, the adapter
  comes from BackendRouter.adapter_for/1 instead of the single global
  NifAdapter.adapter(). vault/profile goes to DocStoreAdapter
  (CouchDB + S3 JSON mirror); everything else still goes
  to the Lance adapter, unchanged. Authorization runs identically for
  both — no backend is reachable without passing it first.
  """

  alias Przma.Vault.{BackendRouter, PzdbAuthorization, PzdbUri}

  @type actor :: %{
          did: String.t(),
          origin_instance_id: String.t() | nil,
          portable_grant: Przma.Federation.PortableGrant.t() | nil
        }

  @spec read(actor(), uri_string :: String.t(), opts :: keyword()) ::
          {:ok, binary()} | {:error, term()}
  def read(actor, uri_string, opts \\ []) do
    with {:ok, uri} <- PzdbUri.parse(uri_string),
         :ok <- PzdbAuthorization.authorize(actor, uri, :read) do
      BackendRouter.adapter_for(uri).query(uri, opts)
    end
  end

  @doc """
  Reads ALL rows belonging to this URI's did — for many-rows-per-did
  tables (files, and future chat/calendar/AI). Same authorization
  chain as read/3, only the final NifAdapter callback differs.
  """
  @spec read_many(actor(), uri_string :: String.t()) :: {:ok, binary()} | {:error, term()}
  def read_many(actor, uri_string) do
    with {:ok, uri} <- PzdbUri.parse(uri_string),
        :ok <- PzdbAuthorization.authorize(actor, uri, :read) do
      BackendRouter.adapter_for(uri).query_many(uri)
    end
  end

  @doc """
  Reads ONE row by its `id` COLUMN — distinct from read/3 (which is
  hardcoded to filter by `did` and only fits one-row-per-did tables
  like profile). For tables such as cas_meta, whose row id is a
  content hash unrelated to `did`. Same authorization chain as
  read/3, only the final NifAdapter callback differs.
  """
  @spec read_by_id(actor(), uri_string :: String.t(), id :: String.t()) ::
          {:ok, binary()} | {:error, term()}
  def read_by_id(actor, uri_string, id) do
    with {:ok, uri} <- PzdbUri.parse(uri_string),
         :ok <- PzdbAuthorization.authorize(actor, uri, :read) do
      BackendRouter.adapter_for(uri).get_by_id(uri, id)
    end
  end

  @doc """
  Ordered, paged read of a table (see DocStoreAdapter.query_range/2 for
  the options). Same authorization chain as read_many/2. Only adapters
  that export query_range/2 support it (CouchDB does; Lance does not).
  """
  @spec read_range(actor(), uri_string :: String.t(), opts :: keyword()) ::
          {:ok, binary()} | {:error, term()}
  def read_range(actor, uri_string, opts \\ []) do
    with {:ok, uri} <- PzdbUri.parse(uri_string),
         :ok <- PzdbAuthorization.authorize(actor, uri, :read) do
      adapter = BackendRouter.adapter_for(uri)

      if Code.ensure_loaded?(adapter) and function_exported?(adapter, :query_range, 2) do
        adapter.query_range(uri, opts)
      else
        {:error, :range_read_not_supported}
      end
    end
  end

  @spec write(actor(), uri_string :: String.t(), rows :: [map()] | binary()) ::
          :ok | {:error, term()}
  def write(actor, uri_string, rows) do
    with {:ok, uri} <- PzdbUri.parse(uri_string),
         :ok <- PzdbAuthorization.authorize(actor, uri, :write) do
      BackendRouter.adapter_for(uri).insert(uri, rows)
    end
  end

  @spec upsert(actor(), uri_string :: String.t(), rows :: [map()] | binary(), on :: [atom()]) ::
          :ok | {:error, term()}
  def upsert(actor, uri_string, rows, on) do
    with {:ok, uri} <- PzdbUri.parse(uri_string),
         :ok <- PzdbAuthorization.authorize(actor, uri, :write) do
      BackendRouter.adapter_for(uri).merge_insert(uri, rows, on)
    end
  end

  @spec compact(actor(), uri_string :: String.t()) :: :ok | {:error, term()}
  def compact(actor, uri_string) do
    with {:ok, uri} <- PzdbUri.parse(uri_string),
         :ok <- PzdbAuthorization.authorize(actor, uri, :compact) do
      BackendRouter.adapter_for(uri).compact(uri)
    end
  end
end
