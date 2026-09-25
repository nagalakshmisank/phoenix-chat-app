defmodule PRZMAWeb.Graphql.Resolvers.RegistrationResolver do
  @moduledoc "GraphQL twin of POST /api/v1/registration/complete."
  alias Przma.Vault.Registration
  alias PRZMAWeb.Graphql.Resolvers.ProfileResolver

  def complete(args, %{context: %{did: did} = context}) when is_binary(did) do
    identity = %{
      did: did,
      tenant_uuid: context.tenant_uuid,
      storage_tier: context.storage_tier,
      token_claims: context.token_claims
    }

    with {:ok, result} <- Registration.complete(identity, args[:nickname]),
         {:ok, profile} <- ProfileResolver.fetch(context) do
      {:ok, Map.put(result, :profile, profile)}
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  def complete(_args, _resolution), do: {:error, "unauthorized"}
end
