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
  """

  alias Przma.Vault.{NifAdapter, PzdbAuthorization, PzdbUri}

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
      NifAdapter.adapter().query(uri, opts)
    end
  end

  @spec write(actor(), uri_string :: String.t(), rows :: [map()] | binary()) ::
          :ok | {:error, term()}
  def write(actor, uri_string, rows) do
    with {:ok, uri} <- PzdbUri.parse(uri_string),
         :ok <- PzdbAuthorization.authorize(actor, uri, :write) do
      NifAdapter.adapter().insert(uri, rows)
    end
  end

  @spec upsert(actor(), uri_string :: String.t(), rows :: [map()] | binary(), on :: [atom()]) ::
          :ok | {:error, term()}
  def upsert(actor, uri_string, rows, on) do
    with {:ok, uri} <- PzdbUri.parse(uri_string),
         :ok <- PzdbAuthorization.authorize(actor, uri, :write) do
      NifAdapter.adapter().merge_insert(uri, rows, on)
    end
  end

  @spec compact(actor(), uri_string :: String.t()) :: :ok | {:error, term()}
  def compact(actor, uri_string) do
    with {:ok, uri} <- PzdbUri.parse(uri_string),
         :ok <- PzdbAuthorization.authorize(actor, uri, :compact) do
      NifAdapter.adapter().compact(uri)
    end
  end
end
