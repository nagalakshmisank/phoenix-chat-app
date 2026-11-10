defmodule PRZMAWeb.Plugs.KeycloakAuth do
  @moduledoc """
  Identifies the caller. Two ways in:

    * `Authorization: Bearer <Keycloak JWT>` — apps, GraphiQL.
      Verified locally via JWKS (Przma.Auth.JwksCache): signature, expiry
      and issuer (`iss` must be our realm).
    * `X-API-Key: pk_live_…` — scripts and integrations
      (Przma.Authz.AccessKeys). The key acts as its owner, limited to the
      key's scopes.

  Sets conn.assigns:
    :did, :tenant_uuid, :storage_tier, :token_claims  (as before)
    :auth_method  :jwt | :api_key
    :sid          Keycloak session id (JWT only)
    :access_key   %{id, did, scopes} (API key only)
    :client_ip, :user_agent

  This plug only says WHO is calling. WHAT they may call is decided per
  API by PRZMAWeb.Graphql.Middleware.Authz and PRZMAWeb.Plugs.Authorize.
  """
  import Plug.Conn
  require Logger

  def init(opts), do: opts

  def call(conn, _opts) do
    conn = conn |> assign(:client_ip, conn.remote_ip) |> assign(:user_agent, user_agent(conn))

    case {get_req_header(conn, "authorization"), get_req_header(conn, "x-api-key")} do
      {["Bearer " <> token], _} -> jwt(conn, token)
      {[], [key | _]} -> api_key(conn, key)
      _ -> unauthorized(conn, "unauthorized")
    end
  end

  defp jwt(conn, token) do
    case verify(token) do
      {:ok, claims} ->
        did = "did:przma:#{claims["preferred_username"]}"

        conn
        |> assign(:did, did)
        |> assign(:tenant_uuid, claims["sub"])
        |> assign(:storage_tier, extract_tier(claims))
        |> assign(:token_claims, claims)
        |> assign(:auth_method, :jwt)
        |> assign(:sid, claims["sid"])

      _ ->
        unauthorized(conn, "unauthorized")
    end
  end

  defp api_key(conn, key) do
    with {:ok, k} <- Przma.Authz.verify_access_key(key, conn.remote_ip),
         {:ok, %{} = profile} <- Przma.Authz.profile(k.did) do
      conn
      |> assign(:did, k.did)
      |> assign(:tenant_uuid, profile.keycloak_user_id)
      |> assign(:storage_tier, profile.storage[:tier] || 1)
      |> assign(:token_claims, %{"preferred_username" => profile.username})
      |> assign(:auth_method, :api_key)
      |> assign(:access_key, k)
    else
      {:error, code} when is_atom(code) -> unauthorized(conn, Atom.to_string(code))
      _ -> unauthorized(conn, "key_invalid")
    end
  end

  defp unauthorized(conn, code) do
    status = if code == "authz_unavailable", do: 503, else: 401

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{error: code}))
    |> halt()
  end

  @doc """
  Verifies a Keycloak access token and returns its claims. Public so the
  websocket (PRZMAWeb.UserSocket) checks tokens exactly the way HTTP does.
  """
  @spec verify(String.t()) :: {:ok, map()} | {:error, atom()}
  def verify(token) do
    case verify_signature(token) do
      {:ok, claims} ->
        with :ok <- check_expiry(claims), :ok <- check_issuer(claims), do: {:ok, claims}

      _ ->
        # Signature check failed — could be genuinely invalid, or the
        # realm key rotated since boot. Refresh once and retry.
        Przma.Auth.JwksCache.refresh()

        with {:ok, claims} <- verify_signature(token),
             :ok <- check_expiry(claims),
             :ok <- check_issuer(claims) do
          {:ok, claims}
        else
          {:error, _} = err -> err
          _ -> {:error, :invalid_token}
        end
    end
  end

  defp verify_signature(token) do
    with {:ok, jwk} <- Przma.Auth.JwksCache.current_jwk(),
         {true, %JOSE.JWT{fields: claims}, _} <- JOSE.JWT.verify_strict(jwk, ["RS256"], token) do
      {:ok, claims}
    else
      _ -> {:error, :invalid_token}
    end
  rescue
    _ -> {:error, :invalid_token}
  end

  defp check_expiry(%{"exp" => exp}) when is_integer(exp) do
    if exp > System.system_time(:second), do: :ok, else: {:error, :expired}
  end

  defp check_expiry(_), do: {:error, :expired}

  # Accepted issuers: KEYCLOAK_ISSUERS (comma separated) or <KEYCLOAK_URL>/realms/<realm>.
  # Tokens fetched through another hostname (e.g. auth.przma.com after the
  # DNS change) need that issuer added to KEYCLOAK_ISSUERS.
  defp check_issuer(%{"iss" => iss}) do
    if iss in issuers() do
      :ok
    else
      Logger.warning("KeycloakAuth: token from unexpected issuer #{inspect(iss)}")
      {:error, :wrong_issuer}
    end
  end

  defp check_issuer(_), do: {:error, :wrong_issuer}

  defp issuers do
    conf = Application.get_env(:przma, :keycloak, [])

    case conf[:issuers] do
      list when is_list(list) and list != [] -> list
      _ -> ["#{conf[:url]}/realms/#{conf[:realm]}"]
    end
  end

  defp extract_tier(claims) do
    roles = get_in(claims, ["realm_access", "roles"]) || []

    cond do
      "tier3-user" in roles -> 3
      "tier2-user" in roles -> 2
      true -> 1
    end
  end

  defp user_agent(conn) do
    case get_req_header(conn, "user-agent") do
      [ua | _] -> String.slice(ua, 0, 300)
      _ -> nil
    end
  end
end
