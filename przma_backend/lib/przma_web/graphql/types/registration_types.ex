defmodule PRZMAWeb.Graphql.Types.RegistrationTypes do
  use Absinthe.Schema.Notation

  @desc "Result of completing registration after Keycloak sign-up."
  object :registration_result do
    field :status, :string
    field :did, :string
    @desc "Keycloak sub (tenant_uuid)"
    field :gid, :string
    @desc "The user's CouchDB database name"
    field :database, :string
    field :profile, :profile
  end
end
