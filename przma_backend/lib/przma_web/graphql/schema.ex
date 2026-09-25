defmodule PRZMAWeb.Graphql.Schema do
  use Absinthe.Schema
  import_types Absinthe.Plug.Types
  import_types PRZMAWeb.Graphql.Types.ProfileTypes
  import_types PRZMAWeb.Graphql.Types.FilesTypes
  import_types PRZMAWeb.Graphql.Types.RegistrationTypes
  alias PRZMAWeb.Graphql.Resolvers.{ProfileResolver, FilesResolver, RegistrationResolver}

  query do
    @desc "The caller's profile (vault namespace, private space)."
    field :profile, :profile do
      resolve &ProfileResolver.show/2
    end

    field :files, list_of(:file_metadata) do
      arg :space, :string
      arg :owner_did, :string
      resolve &FilesResolver.list/2
    end

    @desc "Old REST GET /sync/cas-meta equivalent."
    field :cas_meta, list_of(:cas_meta_row) do
      arg :owner_did, :string
      resolve &FilesResolver.list_cas_meta/2
    end

    @desc "Old REST GET /sync/blob/:hash equivalent — returns a presigned S3 URL, not inline bytes."
    field :blob_download_url, :blob_download_result do
      arg :hash, non_null(:string)
      arg :space, :string
      arg :owner_did, :string
      arg :expires_in, :integer
      resolve &FilesResolver.blob_download_url/2
    end
  end

  mutation do
    @desc """
    Call once right after Keycloak sign-up (safe to repeat). Creates the
    user's CouchDB database and the profile document vault:private:profile.
    """
    field :complete_registration, :registration_result do
      arg :nickname, :string
      resolve &RegistrationResolver.complete/2
    end

    field :create_profile, :profile do
      arg :nickname, :string
      arg :display_name, :string
      arg :bio, :string
      arg :avatar_cid, :string
      resolve &ProfileResolver.create/2
    end

    @desc "Field-level update — only the fields you send are changed."
    field :update_profile, :profile do
      arg :nickname, :string
      arg :display_name, :string
      arg :bio, :string
      arg :avatar_cid, :string
      resolve &ProfileResolver.update/2
    end

    field :upload_file, :file_upload_result do
      arg :file, non_null(:upload)
      arg :space, :string
      arg :owner_did, :string
      resolve &FilesResolver.upload/2
    end

    @desc "Old REST POST /sync/blob equivalent — content only, no index row."
    field :upload_blob, :blob_upload_result do
      arg :file, non_null(:upload)
      arg :space, :string
      arg :owner_did, :string
      resolve &FilesResolver.upload_blob/2
    end

    @desc "Old REST POST /sync/record equivalent — index row only, for a blob already uploaded via uploadBlob."
    field :sync_file_record, :file_sync_result do
      arg :input, non_null(:file_record_input)
      resolve &FilesResolver.sync_record/2
    end
  end
end