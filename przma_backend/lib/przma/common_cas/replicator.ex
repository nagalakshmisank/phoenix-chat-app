defmodule Przma.CommonsCas.Replicator do
  @moduledoc """
  Replicates CAS metadata for PUBLIC-space uploads into
  przma_commons_cas.cas_table, for analytics. Best-effort — a
  Postgres outage never fails a file upload whose bytes and Lance
  metadata already succeeded. Only ever called from
  Przma.Vault.Files.upload/5, AFTER Cas.put/3 has already run the
  real PzdbAuthorization check for the public-space write — this
  module performs no authorization check of its own, because it
  cannot be reached except as a direct consequence of one that
  already passed.

  ASSUMES `hash` has a UNIQUE constraint on cas_table (needed for
  on_conflict/conflict_target below to work as an upsert rather than
  error on a repeat upload of the same content). Confirm with:
    SELECT conname, pg_get_constraintdef(oid) FROM pg_constraint
    WHERE conrelid = 'cas_table'::regclass;
  If there's no such constraint, replace the Repo.insert call below
  with a manual Repo.get_by(CasRecord, hash: hash) + insert-or-update.
  """
  require Logger

  alias Przma.CommonsCas.{CasRecord, Repo}

  @spec replicate(
          owner_did :: String.t(),
          created_by_did :: String.t(),
          hash :: String.t(),
          mime_type :: String.t(),
          size_bytes :: integer(),
          ref_count :: integer(),
          s3_uri :: String.t()
        ) :: :ok
  def replicate(owner_did, created_by_did, hash, mime_type, size_bytes, ref_count, s3_uri) do
    attrs = %{
      hash: hash,
      did: owner_did,
      mime_type: mime_type,
      size_bytes: size_bytes,
      created_by: created_by_did,
      ref_count: ref_count,
      is_encrypted: false,
      s3_uri: s3_uri,
      file_origin: owner_did
    }

    %CasRecord{}
    |> Ecto.Changeset.cast(attrs, [
      :hash, :did, :mime_type, :size_bytes, :created_by, :ref_count, :is_encrypted, :s3_uri, :file_origin
    ])
    |> Repo.insert(
      on_conflict: {:replace, [:ref_count, :size_bytes, :updated_at]},
      conflict_target: :hash
    )
    |> case do
      {:ok, _} -> :ok
      {:error, reason} -> log_and_continue(reason, hash)
    end
  rescue
    e -> log_and_continue(e, hash)
  end

  defp log_and_continue(reason, hash) do
    Logger.warning("[Przma.CommonsCas.Replicator] replication failed hash=#{hash} reason=#{inspect(reason)}")
    :ok
  end
end