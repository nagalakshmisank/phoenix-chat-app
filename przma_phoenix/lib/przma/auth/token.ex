defmodule PRZMA.Auth.Token do
  @moduledoc """
  Self-describing signed auth tokens.

  The DID is packed straight into the token (HMAC-signed via Phoenix.Token),
  so verifying a request is pure computation — no Lance read, no table, no
  lookup of any kind. This is what makes auth work with zero Postgres:
  there's nothing to "look up", only something to "unseal".

  IMPORTANT: we pass the secret_key_base as a raw binary (not
  `PRZMAWeb.Endpoint`) because `PRZMA.Application` boots `Plug.Cowboy`
  directly and never starts the Endpoint process — `Phoenix.Token.sign/verify`
  would crash trying to read live Endpoint config. Phoenix.Token accepts a
  binary secret directly, so this works with or without the Endpoint running.
  """

  @salt "przma-auth-v1"
  @max_age 86_400

  # Dev-only fallback so `mix phx.server` doesn't crash if SECRET_KEY_BASE
  # isn't exported yet. ALWAYS set SECRET_KEY_BASE in staging/prod.
  @dev_fallback_secret "przma_dev_insecure_secret_key_base_change_me_before_prod_0000000000"

  defp secret do
    case Application.get_env(:przma, PRZMAWeb.Endpoint) do
      nil -> @dev_fallback_secret
      cfg -> Keyword.get(cfg, :secret_key_base) || @dev_fallback_secret
    end
  end

  @doc "Issue a signed token that carries the DID. No DB write required."
  def sign(did) when is_binary(did) do
    Phoenix.Token.sign(secret(), @salt, %{did: did}, max_age: @max_age)
  end

  @doc "Unseal a token and return its DID. Pure computation, zero I/O."
  def verify(token) when is_binary(token) and byte_size(token) > 0 do
    case Phoenix.Token.verify(secret(), @salt, token, max_age: @max_age) do
      {:ok, %{did: did}} -> {:ok, did}
      {:error, reason} -> {:error, reason}
    end
  end

  def verify(_), do: {:error, :missing_token}

  @doc "How long (seconds) an issued token is valid for. Used in login response."
  def max_age, do: @max_age
end