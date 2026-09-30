defmodule Przma.CommonsCas.Replicator do
  @moduledoc """
  Copies CAS metadata of PUBLIC-space uploads into Postgres
  przma_commons_cas.cas_table (one row per owner DID + hash).

  Called by Przma.Vault.Files for all three upload paths (upload/5,
  upload_blob/4, sync_record/5), only for space "public", and only
  after the CouchDB writes succeeded — so it needs no authorization of
  its own.

  WHY THE LANCE VERSION NEVER WROTE A ROW — fixed here:
    1. It was only called from upload/5; uploadBlob + syncFileRecord
       never replicated.
    2. It used `on_conflict: …, conflict_target: :hash`, which fails
       unless cas_table has a UNIQUE index on exactly (hash). Any error
       was caught and only logged as a warning, so it looked like
       success.
    3. Every error (table missing, wrong columns, database unreachable
       from the container) was swallowed the same way.

  This version: looks up (did, hash) first and then INSERTs or UPDATEs,
  so it works with or without a unique index; it never raises, but it
  RETURNS {:error, reason} and logs at error level, and Files puts the
  outcome into the upload response ("replicated" / "failed: …").
  """

  require Logger
  import Ecto.Query, only: [from: 2]

  alias Przma.CommonsCas.{CasRecord, Repo}

  @type attrs :: %{
          required(:hash) => String.t(),
          required(:did) => String.t(),
          optional(:created_by) => String.t(),
          optional(:file_origin) => String.t(),
          optional(:mime_type) => String.t(),
          optional(:size_bytes) => integer(),
          optional(:ref_count) => integer(),
          optional(:is_encrypted) => boolean(),
          optional(:s3_uri) => String.t()
        }

  @spec replicate(attrs()) :: :ok | {:error, String.t()}
  def replicate(%{hash: hash, did: did} = attrs) when is_binary(hash) and is_binary(did) do
    existing =
      Repo.one(from(r in CasRecord, where: r.did == ^did and r.hash == ^hash, limit: 1))

    result =
      case existing do
        nil -> %CasRecord{} |> CasRecord.changeset(attrs) |> Repo.insert()
        %CasRecord{} = row -> row |> CasRecord.changeset(Map.put(attrs, :deleted_at, nil)) |> Repo.update()
      end

    case result do
      {:ok, _row} ->
        Logger.info("[CommonsCas] public CAS row saved did=#{did} hash=#{hash}")
        :ok

      {:error, %Ecto.Changeset{} = cs} ->
        fail(hash, "invalid row: #{inspect(cs.errors)}")
    end
  rescue
    e -> fail(hash, Exception.message(e))
  end

  @doc "Old 7-argument form, kept so any other caller still compiles."
  @spec replicate(String.t(), String.t(), String.t(), String.t(), integer(), integer(), String.t()) ::
          :ok | {:error, String.t()}
  def replicate(owner_did, created_by_did, hash, mime_type, size_bytes, ref_count, s3_uri) do
    replicate(%{
      hash: hash,
      did: owner_did,
      created_by: created_by_did,
      file_origin: owner_did,
      mime_type: mime_type,
      size_bytes: size_bytes,
      ref_count: ref_count,
      is_encrypted: false,
      s3_uri: s3_uri
    })
  end

  @doc "Quick connectivity/table check: {:ok, row_count} or {:error, reason}."
  @spec health() :: {:ok, non_neg_integer()} | {:error, String.t()}
  def health do
    {:ok, Repo.aggregate(CasRecord, :count)}
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp fail(hash, reason) do
    Logger.error("[CommonsCas] public CAS replication FAILED hash=#{hash} reason=#{reason}")
    {:error, reason}
  end
end
