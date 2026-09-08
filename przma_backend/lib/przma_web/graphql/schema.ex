defmodule PRZMAWeb.Graphql.Schema do
  use Absinthe.Schema
  import_types PRZMAWeb.Graphql.Types.ProfileTypes
  alias PRZMAWeb.Graphql.Resolvers.ProfileResolver

  query do
    field :profile, :profile do
      resolve &ProfileResolver.show/2
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
  end
end