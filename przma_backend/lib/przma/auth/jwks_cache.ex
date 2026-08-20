defmodule Przma.Auth.JwksCache do
  @moduledoc """
  Fetches Keycloak's realm signing key (JWKS) once at boot and caches
  it, so every request verifies its JWT locally instead of round-
  tripping to Keycloak's /userinfo endpoint (the Keycloak guide's
  original suggestion — this is the faster local-verification upgrade
  flagged early in this build).

  Call current_jwk/0 from KeycloakAuth. Call refresh/0 once, on a
  verify failure, in case the key rotated.
  """
  use GenServer
  require Logger

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @spec current_jwk() :: {:ok, JOSE.JWK.t()} | {:error, term()}
  def current_jwk, do: GenServer.call(__MODULE__, :current_jwk)

  @spec refresh() :: :ok
  def refresh, do: GenServer.cast(__MODULE__, :refresh)

  @impl true
  def init(:ok) do
    send(self(), :fetch)
    {:ok, %{jwk: nil}}
  end

  @impl true
  def handle_call(:current_jwk, _from, %{jwk: nil} = state) do
    case fetch_jwks() do
      {:ok, jwk} -> {:reply, {:ok, jwk}, %{state | jwk: jwk}}
      {:error, _} = err -> {:reply, err, state}
    end
  end

  def handle_call(:current_jwk, _from, %{jwk: jwk} = state), do: {:reply, {:ok, jwk}, state}

  @impl true
  def handle_cast(:refresh, state) do
    case fetch_jwks() do
      {:ok, jwk} -> {:noreply, %{state | jwk: jwk}}
      {:error, _} -> {:noreply, state}
    end
  end

  @impl true
  def handle_info(:fetch, state) do
    case fetch_jwks() do
      {:ok, jwk} -> {:noreply, %{state | jwk: jwk}}
      {:error, reason} ->
        Logger.warning("JwksCache: initial fetch failed (#{inspect(reason)}), will retry lazily on first request")
        {:noreply, state}
    end
  end

  defp fetch_jwks do
    conf = Application.fetch_env!(:przma, :keycloak)
    url = "#{conf[:url]}/realms/#{conf[:realm]}/protocol/openid-connect/certs"

    case :httpc.request(:get, {String.to_charlist(url), []}, [], []) do
      {:ok, {{_, 200, _}, _headers, body}} ->
        keys = body |> IO.iodata_to_binary() |> Jason.decode!()
        # Realm certs endpoint returns a JWKS set; take the first RSA
        # signing key (use = "sig").
        case Enum.find(keys["keys"], &(&1["use"] == "sig")) do
          nil -> {:error, :no_signing_key}
          key -> {:ok, JOSE.JWK.from_map(key)}
        end

      {:ok, {{_, status, _}, _, _}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
