defmodule PRZMAWeb.Graphql.Types.RegistrationTypes do
  use Absinthe.Schema.Notation

  @desc "Result of completing registration after Keycloak sign-up."
  object :registration_result do
    field :status, :string
    field :did, :string
    @desc "Keycloak sub (tenant_uuid)"
    field :gid, :string
    @desc "The user's storage folder in S3 (kept as `database` for frontend compatibility)"
    field :database, :string
    @desc "The user's storage folder in S3, e.g. s3://perkeep/did_przma_kc_user1/"
    field :storage_path, :string
    field :profile, :profile
  end
end
