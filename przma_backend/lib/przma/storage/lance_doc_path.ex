defmodule Przma.Storage.LanceDocPath do
  @moduledoc """
  The ONLY place a doc-store location is built (replaces CouchDbName).

  A %PzdbUri{} becomes the same 4-segment form PRZMA.PzDb already uses
  for every Lance table, so doc tables sit in the same S3 tree as
  `_meta.lance` and the CAS blobs:

      pzdb://s3/{tenant}/did:przma:kc_user1/chat/private/inbox     (PzdbUri, authorized)
        -> pzdb://did:przma:kc_user1/chat/private/inbox              (table_uri/1)
        -> s3://perkeep/did_przma_kc_user1/chat/private/inbox.lance  (PRZMA.PzDb.resolve/1)

  tenant_uuid is NOT part of the path (same decision as
  LanceLinodeAdapter); it is stored in each row's `gid` column.
  """

  alias Przma.Vault.PzdbUri

  @doc "Lean pzdb:// table URI understood by PRZMA.PzDb (did/namespace/space/table)."
  @spec table_uri(PzdbUri.t()) :: String.t()
  def table_uri(%PzdbUri{did: did, namespace: ns, space: space, table: table}) do
    "pzdb://#{did}/#{ns}/#{space}/#{table}"
  end

  @doc "Full .lance location of a table, for logs, API responses and tests."
  @spec location(PzdbUri.t()) :: String.t()
  def location(%PzdbUri{did: did, namespace: ns, space: space, table: table}) do
    Enum.join([base(), seg(did), seg(ns), seg(space), seg(table) <> ".lance"], "/")
  end

  @doc "A user's root folder in S3, e.g. s3://perkeep/did_przma_kc_user1/"
  @spec user_prefix(String.t()) :: String.t()
  def user_prefix(did) when is_binary(did), do: base() <> "/" <> seg(did) <> "/"

  # Same base and sanitising as PRZMA.PzDb (global_base/0, seg/1).
  defp base, do: Application.get_env(:przma, :vault_base_path, "/var/przma/vaults")
  defp seg(s), do: String.replace(s, [":", " "], "_")
end
