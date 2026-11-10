defmodule PRZMAWeb.Graphql.Middleware.Authz do
  @moduledoc """
  Runs before EVERY root query and mutation field (added in
  PRZMAWeb.Graphql.Schema.middleware/3). Looks the field up in the
  endpoint registry and asks Przma.Authz.authorize/1.

  A refused call returns a GraphQL error like

      {"message": "scope_denied",
       "extensions": {"code": "scope_denied", "status": 403,
                      "needed": "calendar:plus", "hint": "…"}}

  and the resolver is never run.
  """
  @behaviour Absinthe.Middleware

  alias Przma.Authz.Endpoints

  @impl true
  def call(%{state: :resolved} = resolution, _opts), do: resolution

  def call(%{context: context} = resolution, field_identifier) do
    case context do
      %{did: did} when is_binary(did) ->
        req = %{
          did: did,
          kind: kind(resolution),
          endpoint: Endpoints.graphql_name(field_identifier),
          method: context[:auth_method] || :jwt,
          key: context[:access_key],
          sid: context[:sid],
          claims: context[:token_claims] || %{},
          ip: context[:client_ip],
          user_agent: context[:user_agent]
        }

        case Przma.Authz.authorize(req) do
          :ok -> resolution
          {:error, code, details} -> Absinthe.Resolution.put_result(resolution, {:error, error(code, details)})
        end

      _ ->
        Absinthe.Resolution.put_result(resolution, {:error, error(:unauthorized, %{})})
    end
  end

  defp kind(%{parent_type: %{identifier: :mutation}}), do: "graphql_mutation"
  defp kind(_), do: "graphql_query"

  defp error(code, details) do
    extensions =
      details
      |> Map.take([:needed, :plan, :limit_per_min, :key_scopes])
      |> Map.merge(%{code: Atom.to_string(code), status: Przma.Authz.http_status(code)})
      |> then(fn ext -> if h = Przma.Authz.hint(code), do: Map.put(ext, :hint, h), else: ext end)

    %{message: Atom.to_string(code), extensions: extensions}
  end
end
