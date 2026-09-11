defmodule PRZMAWeb.Graphql.Schema do
  use Absinthe.Schema
  import_types Absinthe.Plug.Types
  import_types PRZMAWeb.Graphql.Types.ProfileTypes
  import_types PRZMAWeb.Graphql.Types.FilesTypes
  alias PRZMAWeb.Graphql.Resolvers.{ProfileResolver, FilesResolver}

  query do
    field :profile, :profile do
      resolve &ProfileResolver.show/2
    end

    field :files, list_of(:file_metadata) do
      arg :space, :string
      arg :owner_did, :string
      resolve &FilesResolver.list/2
    end
  end

  mutation do
    field :create_profile, :profile do
      arg :display_name, :string
      arg :bio, :string
      arg :avatar_cid, :string
      resolve &ProfileResolver.create/2
    end

    field :update_profile, :profile do
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
  end
end