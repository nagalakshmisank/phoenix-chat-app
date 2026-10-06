defmodule PRZMAWeb.Graphql.Resolvers.Helpers do
  @moduledoc """
  Shared by the chat / circle / social / notification resolvers.

  run/2 takes the Absinthe resolution, rejects unauthenticated calls,
  makes sure the caller has an account record in the shared directory,
  and hands the resolver body `me = %{did: ..., gid: ...}` built ONLY
  from the verified Keycloak token. It also turns error atoms from the
  context modules into GraphQL error messages ("forbidden", "not_found").
  """

  alias Przma.Social.Directory

  def run(%{context: %{did: did} = context}, fun) when is_binary(did) do
    Directory.ensure_account(did, context[:tenant_uuid])

    case fun.(%{did: did, gid: context[:tenant_uuid]}) do
      {:ok, value} -> {:ok, value}
      :ok -> {:ok, true}
      {:error, reason} when is_atom(reason) -> {:error, Atom.to_string(reason)}
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  def run(_resolution, _fun), do: {:error, "unauthorized"}

  @doc "Paging options shared by every list: before (id), limit."
  def paging(args), do: [before: args[:before], limit: args[:limit]]
end
