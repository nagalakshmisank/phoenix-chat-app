defmodule Przma.Vault.BackendRouter do
  @moduledoc """
  Picks the storage adapter for a pzdb URI, AFTER PzdbConnector has
  parsed and authorized it. Authorization is identical for every
  backend; only the final storage call differs.

      {namespace, table} in doc_store_tables  -> DocStoreAdapter (CouchDB + S3 mirror)
      anything else                           -> NifAdapter.adapter() (Lance, untouched)

  Current CouchDB table: vault/profile. Moving another service later means
  adding its {namespace, table} here — or in config
  :przma, :doc_store_tables — not rewriting the service.
  """

  alias Przma.Vault.{NifAdapter, PzdbUri}

  @default_doc_store_tables [{"vault", "profile"}]

  @spec adapter_for(PzdbUri.t()) :: module()
  def adapter_for(%PzdbUri{namespace: namespace, table: table}) do
    if {namespace, table} in doc_store_tables(), do: doc_store_adapter(), else: NifAdapter.adapter()
  end

  @spec doc_store_tables() :: [{String.t(), String.t()}]
  def doc_store_tables, do: Application.get_env(:przma, :doc_store_tables, @default_doc_store_tables)

  # Configurable so tests can swap in a fake adapter.
  @spec doc_store_adapter() :: module()
  def doc_store_adapter, do: Application.get_env(:przma, :doc_store_adapter, Przma.Vault.DocStoreAdapter)
end
