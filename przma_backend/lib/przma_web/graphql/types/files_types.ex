defmodule PRZMAWeb.Graphql.Types.FilesTypes do
  use Absinthe.Schema.Notation

  object :file_metadata do
    field :id, :string
    field :name, :string
    field :mime_type, :string
    field :size_bytes, :integer
    field :content_cas, :string
  end

  object :file_upload_result do
    field :file_id, :string
  end

  @desc "Content-only upload result — old REST POST /sync/blob equivalent. No file_id yet: no index row was written, just bytes + the CAS ledger bump."
  object :blob_upload_result do
    field :content_cas, :string
    field :size_bytes, :integer
    field :ref_count, :integer
  end

  @desc "Old REST POST /sync/record equivalent — writes only the index row for a content_cas hash uploaded separately via uploadBlob."
  input_object :file_record_input do
    field :content_cas, non_null(:string)
    field :filename, non_null(:string)
    field :content_type, :string
    field :size_bytes, :integer
    field :space, :string
    field :owner_did, :string
    field :file_id, :string
  end

  object :file_sync_result do
    field :file_id, :string
    field :status, :string
  end

  @desc "One row of the CAS dedup ledger — old REST GET /sync/cas-meta equivalent. s3_uri is deliberately NOT exposed here (internal/analytics only, see CasMeta moduledoc)."
  object :cas_meta_row do
    field :id, :string
    field :hash, :string
    field :cas_uri, :string
    field :uri, :string
    field :uri_type, :string
    field :space, :string
    field :did, :string
    field :ref_count, :integer
    field :size_bytes, :integer
    field :created_at, :integer
    field :updated_at, :integer
  end

  @desc "Old REST GET /sync/blob/:hash equivalent, GraphQL-shaped: a short-lived presigned S3 URL instead of inline bytes (see Cas.presigned_get_url/4)."
  object :blob_download_result do
    field :url, :string
    field :expires_in, :integer
  end
end 