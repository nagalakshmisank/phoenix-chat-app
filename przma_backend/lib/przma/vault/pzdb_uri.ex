defmodule Przma.Vault.PzdbUri do
  @moduledoc """
  Parses and constructs pzdb:// URIs:
    pzdb://{transport}/{tenant_id}/{did}/{namespace}/{space}/{table}[/{chunk_address}]

  `space` is one of "private" (default, owner-only by default but
  grantable), "public" (shareable), or "personal" (absolute, never
  grantable under any circumstance — see PzdbAuthorization).
  """

  @enforce_keys [:transport, :tenant_id, :did, :namespace, :table]
  defstruct [:transport, :tenant_id, :did, :namespace, :table, :chunk_address, space: "private"]

  @type transport :: :local | :s3 | :flight
  @type space :: String.t()
  @type t :: %__MODULE__{
          transport: transport(), tenant_id: String.t(), did: String.t(),
          namespace: String.t(), table: String.t(),
          chunk_address: String.t() | nil, space: space()
        }

  @spec parse(String.t()) :: {:ok, t()} | {:error, atom()}
  def parse("pzdb://" <> rest) do
    case String.split(rest, "/", trim: true) do
      [transport, tenant_id, did, namespace, space, table] ->
        build(transport, tenant_id, did, namespace, space, table, nil)
      [transport, tenant_id, did, namespace, space, table, chunk_address] ->
        build(transport, tenant_id, did, namespace, space, table, chunk_address)
      _ -> {:error, :malformed_pzdb_uri}
    end
  end
  def parse(_), do: {:error, :not_a_pzdb_uri}

  defp build(transport_str, tenant_id, did, namespace, space, table, chunk_address) do
    case parse_transport(transport_str) do
      {:ok, transport} ->
        {:ok, %__MODULE__{transport: transport, tenant_id: tenant_id, did: did,
                           namespace: namespace, space: space, table: table, chunk_address: chunk_address}}
      :error -> {:error, :unknown_transport}
    end
  end

  defp parse_transport("local"), do: {:ok, :local}
  defp parse_transport("s3"), do: {:ok, :s3}
  defp parse_transport("flight"), do: {:ok, :flight}
  defp parse_transport(_), do: :error

  @spec to_string(t()) :: String.t()
  def to_string(%__MODULE__{} = uri) do
    base = "pzdb://#{uri.transport}/#{uri.tenant_id}/#{uri.did}/#{uri.namespace}/#{uri.space}/#{uri.table}"
    if uri.chunk_address, do: base <> "/#{uri.chunk_address}", else: base
  end

  @spec namespace_prefix(tenant_id :: String.t(), did :: String.t(), namespace :: String.t()) :: String.t()
  def namespace_prefix(tenant_id, did, namespace), do: "#{tenant_id}/#{did}/#{namespace}"
end