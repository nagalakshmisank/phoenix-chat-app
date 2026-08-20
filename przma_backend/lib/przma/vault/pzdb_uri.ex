defmodule Przma.Vault.PzdbUri do
  @moduledoc """
  Parses and constructs pzdb:// URIs, reconciling the two shapes from
  prior sessions into one: pzdb://{transport}/{tenant_id}/{did}/{namespace}/{table}[/{chunk_address}]

  Does not implement the actual LanceDB connection — that's the
  existing Rustler NIF (przma_vault_nif). This module only handles the
  string <-> struct boundary and namespace-prefix construction, which
  is what the authorization layer (PzdbAuthorization) and the existing
  NIF wrapper both need a shared, correct parse of.
  """

  @enforce_keys [:transport, :tenant_id, :did, :namespace, :table]
  defstruct [:transport, :tenant_id, :did, :namespace, :table, :chunk_address]

  @type transport :: :local | :s3 | :flight
  @type t :: %__MODULE__{
          transport: transport(),
          tenant_id: String.t(),
          did: String.t(),
          namespace: String.t(),
          table: String.t(),
          chunk_address: String.t() | nil
        }

  @spec parse(String.t()) :: {:ok, t()} | {:error, atom()}
  def parse("pzdb://" <> rest) do
    case String.split(rest, "/", trim: true) do
      [transport, tenant_id, did, namespace, table] ->
        build(transport, tenant_id, did, namespace, table, nil)

      [transport, tenant_id, did, namespace, table, chunk_address] ->
        build(transport, tenant_id, did, namespace, table, chunk_address)

      _ ->
        {:error, :malformed_pzdb_uri}
    end
  end

  def parse(_), do: {:error, :not_a_pzdb_uri}

  defp build(transport_str, tenant_id, did, namespace, table, chunk_address) do
    case parse_transport(transport_str) do
      {:ok, transport} ->
        {:ok,
         %__MODULE__{
           transport: transport,
           tenant_id: tenant_id,
           did: did,
           namespace: namespace,
           table: table,
           chunk_address: chunk_address
         }}

      :error ->
        {:error, :unknown_transport}
    end
  end

  defp parse_transport("local"), do: {:ok, :local}
  defp parse_transport("s3"), do: {:ok, :s3}
  defp parse_transport("flight"), do: {:ok, :flight}
  defp parse_transport(_), do: :error

  @spec to_string(t()) :: String.t()
  def to_string(%__MODULE__{} = uri) do
    base = "pzdb://#{uri.transport}/#{uri.tenant_id}/#{uri.did}/#{uri.namespace}/#{uri.table}"
    if uri.chunk_address, do: base <> "/#{uri.chunk_address}", else: base
  end

  @doc """
  Tenant-aware S3/local-path prefix for a DID's namespace — extends
  did_registry.lance_namespace_prefix (session 1) with tenant_id.
  Instance is not part of this path: the S3 bucket itself is already
  instance-scoped, so repeating instance_id inside every key would be
  redundant.
  """
  @spec namespace_prefix(tenant_id :: String.t(), did :: String.t(), namespace :: String.t()) ::
          String.t()
  def namespace_prefix(tenant_id, did, namespace) do
    "#{tenant_id}/#{did}/#{namespace}"
  end
end
