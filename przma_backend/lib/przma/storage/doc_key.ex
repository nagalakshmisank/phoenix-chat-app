defmodule Przma.Storage.DocKey do
  @moduledoc """
  Validates WHERE a document may be stored, from a %PzdbUri{} only.
  (Replaces CouchDocId. With LanceDB the namespace/space/table are part of
  the S3 path, so there is no "ns:space:table:record" id to build any more —
  the record id is stored as-is in the `id` column.)

  These checks were also CouchDB's validate_doc_update (CouchDesign). That
  second layer no longer exists, so this module is now the only place
  they run — LanceDocAdapter calls validate/2 before every read and write.

  Checks, all failing closed:
    * namespace must exist in NamespacePolicy (single source of truth)
    * space must be private | public | personal, or the internal "cas"
    * table must be lowercase a-z 0-9 _
    * record id, when present, must be A-Z a-z 0-9 _ - (ULIDs, UUIDs,
      hex hashes, url-safe base64 file ids, Social.Key ids)

  Because record ids may only contain those characters, they can be put
  inside a Lance SQL filter safely (quotes are still escaped as well).
  """

  alias Przma.Vault.{NamespacePolicy, PzdbUri}

  @spaces ~w(private public personal)
  # Internal, owner-only folders that are not user spaces: "cas" holds the
  # per-user content-addressed ledger (files/cas/cas_meta.lance).
  @internal_spaces ~w(cas)
  @table ~r/^[a-z0-9_]+$/
  @record ~r/^[A-Za-z0-9_\-]+$/

  @doc "The three user spaces."
  @spec spaces() :: [String.t()]
  def spaces, do: @spaces

  @doc "Every space a document may live in: the user spaces plus internal ones (cas)."
  @spec all_spaces() :: [String.t()]
  def all_spaces, do: @spaces ++ @internal_spaces

  @spec validate(PzdbUri.t(), String.t() | nil) :: :ok | {:error, atom()}
  def validate(%PzdbUri{namespace: ns, space: space, table: table}, record_id \\ nil) do
    with {:ok, _scope} <- NamespacePolicy.vault_scope(ns),
         :ok <- check(space in @spaces or space in @internal_spaces, :unknown_space),
         :ok <- check(is_binary(table) and Regex.match?(@table, table), :invalid_table),
         :ok <- check(valid_record?(record_id), :invalid_record_id) do
      :ok
    end
  end

  @doc "True for a non-empty string made only of record-id characters (also used for range bounds)."
  @spec valid_record?(term()) :: boolean()
  def valid_record?(nil), do: true
  def valid_record?(rec) when is_binary(rec), do: Regex.match?(@record, rec)
  def valid_record?(_), do: false

  defp check(true, _reason), do: :ok
  defp check(false, reason), do: {:error, reason}
end
