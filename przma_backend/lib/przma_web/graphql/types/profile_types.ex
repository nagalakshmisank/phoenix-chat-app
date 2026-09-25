defmodule PRZMAWeb.Graphql.Types.ProfileTypes do
  use Absinthe.Schema.Notation

  @desc "User profile — stored in namespace vault, space private (CouchDB doc vault:private:profile)."
  object :profile do
    field :did, :string
    field :email, :string
    field :nickname, :string
    field :display_name, :string
    field :bio, :string
    field :avatar_cid, :string
    @desc "ISO-8601 UTC"
    field :created_at, :string
    @desc "ISO-8601 UTC"
    field :updated_at, :string
  end
end
