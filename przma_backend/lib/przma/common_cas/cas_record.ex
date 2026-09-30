defmodule Przma.CommonsCas.CasRecord do
  @moduledoc """
  Schema for przma_commons_cas.cas_table — a read-mostly copy of the CAS
  metadata of PUBLIC files (one row per owner DID + content hash).
  created_at/updated_at are replication times. The table is created by
  the Ecto migration priv/commons_cas/migrations/*_create_cas_table.exs.
  """
  use Ecto.Schema
  import Ecto.Changeset

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

    timestamps(inserted_at: :created_at, updated_at: :updated_at, type: :utc_datetime_usec)
  end

  @fields ~w(hash did mime_type size_bytes deleted_at created_by ref_count is_encrypted s3_uri file_origin)a

  @spec changeset(t :: %__MODULE__{}, attrs :: map()) :: Ecto.Changeset.t()
  def changeset(record, attrs) do
    record
    |> cast(attrs, @fields)
    |> validate_required([:hash, :did])
  end
end
