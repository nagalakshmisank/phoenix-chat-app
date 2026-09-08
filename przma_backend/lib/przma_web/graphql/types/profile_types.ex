defmodule PRZMAWeb.Graphql.Types.ProfileTypes do
  use Absinthe.Schema.Notation

  object :profile do
    field :did, :string
    field :display_name, :string
    field :bio, :string
    field :avatar_cid, :string
  end
end