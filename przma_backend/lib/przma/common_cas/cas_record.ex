defmodule Przma.CommonsCas.CasRecord do
  @moduledoc """
  Schema for przma_commons_cas.cas_table — a read-mostly analytics
  copy of PUBLIC-space CAS metadata. NOT the source of truth for
  anything; the real record lives in the uploader's own Lance CAS
  ledger (Przma.Vault.CasMeta). created_at/updated_at reflect
  REPLICATION time, not the original Lance upload time.
  """
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "cas_table" do
    field :hash, :string
    field :did, :string
    field :mime_type, :string
    field :size_bytes, :integer
    field :deleted_at, :utc_datetime_usec
    field :created_by, :string
    field :ref_count, :integer
    field :is_encrypted, :boolean, default: false
    field :s3_uri, :string
    field :file_origin, :string

    timestamps(type: :utc_datetime_usec)
  end
end