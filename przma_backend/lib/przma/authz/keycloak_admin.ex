defmodule Przma.Authz.KeycloakAdmin do
  @moduledoc """
  Keeps the Keycloak tier role in step when an admin changes a plan
  (backend = the one place roles are changed; Keycloak follows).

  Needs a Keycloak client with a service account that has the
  realm-management role `manage-users`:

      export KEYCLOAK_ADMIN_CLIENT_ID=przma-backend-admin
      export KEYCLOAK_ADMIN_CLIENT_SECRET=...

  When these are not set this module does nothing (logs once per call),
  and the backend tables still decide access — only the tier role shown
  in new tokens stays as it was.
  """

  require Logger

  @tier_roles %{1 => "tier1-user", 2 => "tier2-user", 3 => "tier3-user"}

  def set_tier_async(nil, _tier), do: :ok

  def set_tier_async(keycloak_user_id, tier) do
    if Process.whereis(Przma.Authz.TaskSupervisor) do
      Task.Supervisor.start_child(Przma.Authz.TaskSupervisor, fn -> set_tier(keycloak_user_id, tier) end)
    end

    :ok
  end

  @doc "Removes the other tier roles and adds the one for `tier`."
  def set_tier(keycloak_user_id, tier) do
    with {:ok, token} <- admin_token(),
         {:ok, roles} <- realm_roles(token, Map.values(@tier_roles)) do
      wanted = Map.fetch!(@tier_roles, tier)
      {add, remove} = Enum.split_with(roles, &(&1["name"] == wanted))
      url = "#{base()}/admin/realms/#{realm()}/users/#{keycloak_user_id}/role-mappings/realm"

      with :ok <- request(:delete, url, token, remove),
           :ok <- request(:post, url, token, add) do
        Logger.info("KeycloakAdmin: #{keycloak_user_id} now #{wanted}")
        :ok
      end
    else
      {:error, :not_configured} ->
        Logger.info("KeycloakAdmin: KEYCLOAK_ADMIN_CLIENT_ID not set, tier role not changed in Keycloak")
        :ok

      {:error, reason} = err ->
        Logger.error("KeycloakAdmin: tier change failed: #{inspect(reason)}")
        err
    end
  end

  defp admin_token do
    conf = Application.get_env(:przma, :keycloak, [])

    case {conf[:admin_client_id], conf[:admin_client_secret]} do
      {id, secret} when is_binary(id) and id != "" and is_binary(secret) ->
        body =
          URI.encode_query(%{"grant_type" => "client_credentials", "client_id" => id, "client_secret" => secret})

        url = "#{base()}/realms/#{realm()}/protocol/openid-connect/token"

        case :httpc.request(:post, {String.to_charlist(url), [], ~c"application/x-www-form-urlencoded", body}, [timeout: 5000], []) do
          {:ok, {{_, 200, _}, _, resp}} -> {:ok, Jason.decode!(IO.iodata_to_binary(resp))["access_token"]}
          {:ok, {{_, status, _}, _, _}} -> {:error, {:token_status, status}}
          {:error, reason} -> {:error, reason}
        end

      _ ->
        {:error, :not_configured}
    end
  end

  defp realm_roles(token, names) do
    roles =
      Enum.flat_map(names, fn name ->
        url = "#{base()}/admin/realms/#{realm()}/roles/#{name}"

        case :httpc.request(:get, {String.to_charlist(url), [auth(token)]}, [timeout: 5000], []) do
          {:ok, {{_, 200, _}, _, body}} -> [Jason.decode!(IO.iodata_to_binary(body))]
          _ -> []
        end
      end)

    {:ok, roles}
  end

  defp request(_method, _url, _token, []), do: :ok

  defp request(method, url, token, roles) do
    body = Jason.encode!(Enum.map(roles, &Map.take(&1, ["id", "name"])))

    case :httpc.request(method, {String.to_charlist(url), [auth(token)], ~c"application/json", body}, [timeout: 5000], []) do
      {:ok, {{_, status, _}, _, _}} when status in 200..299 -> :ok
      {:ok, {{_, status, _}, _, _}} -> {:error, {:keycloak_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp auth(token), do: {~c"authorization", String.to_charlist("Bearer " <> token)}
  defp base, do: Application.get_env(:przma, :keycloak, [])[:url]
  defp realm, do: Application.get_env(:przma, :keycloak, [])[:realm]
end
