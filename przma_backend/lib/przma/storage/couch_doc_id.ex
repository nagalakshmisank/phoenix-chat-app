defmodule Przma.Storage.CouchDocId do
  @moduledoc """
  Builds CouchDB document ids from a %PzdbUri{} — and ONLY from a
  %PzdbUri{}. No module writes a CouchDB id by hand.

  Format (Option B, namespace first):

      {namespace}:{space}:{table}[:{record_id}]
      └partition┘

      pzdb://s3/{tenant}/did:przma:kc_user1/vault/private/profile
        -> "vault:private:profile"

      a table with many records (e.g. chat later), record "01JC2M8Q"
        -> "chat:private:inbox:01JC2M8Q"

  Checks, all failing closed:
    * namespace must exist in NamespacePolicy (single source of truth)
    * space must be private | public | personal
    * table must be lowercase a-z 0-9 _ (no ":" — it would break the id)
    * record id, when present, must be A-Z a-z 0-9 _ - (ULIDs, UUIDs)

  NOTE: the space check lives here, not in PzdbUri.parse/1, on purpose.
  CasMeta (files namespace) uses the internal space "cas" for its
  ledger, so a global check in PzdbUri would break the files feature.
  Only CouchDB-bound URIs are restricted to the three vault spaces.
  """

  alias Przma.Vault.{NamespacePolicy, PzdbUri}

  @spaces ~w(private public personal)
  @table ~r/^[a-z0-9_]+$/
  @record ~r/^[A-Za-z0-9_\-]+$/

  @doc "The three vault spaces a CouchDB document may live in."
  @spec spaces() :: [String.t()]
  def spaces, do: @spaces

  @spec from_uri(PzdbUri.t(), String.t() | nil) :: {:ok, String.t()} | {:error, atom()}
  def from_uri(%PzdbUri{namespace: ns, space: space, table: table}, record_id \\ nil) do
    with {:ok, _scope} <- NamespacePolicy.vault_scope(ns),
         :ok <- check(space in @spaces, :unknown_space),
         :ok <- check(is_binary(table) and Regex.match?(@table, table), :invalid_table),
         :ok <- check(valid_record?(record_id), :invalid_record_id) do
      {:ok, [ns, space, table, record_id] |> Enum.reject(&is_nil/1) |> Enum.join(":")}
    end
  end

  @doc "Splits an id back into its parts. For tests and debugging."
  @spec parse(String.t()) :: {:ok, map()} | {:error, :malformed_doc_id}
  def parse(id) when is_binary(id) do
    case String.split(id, ":") do
      [ns, space, table] -> {:ok, %{namespace: ns, space: space, table: table, record_id: nil}}
      [ns, space, table, rec] -> {:ok, %{namespace: ns, space: space, table: table, record_id: rec}}
      _ -> {:error, :malformed_doc_id}
    end
  end

  defp valid_record?(nil), do: true
  defp valid_record?(rec) when is_binary(rec), do: Regex.match?(@record, rec)
  defp valid_record?(_), do: false

  defp check(true, _reason), do: :ok
  defp check(false, reason), do: {:error, reason}
end
