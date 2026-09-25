defmodule PRZMAWeb.ProfileController do
  use PRZMAWeb, :controller
  alias Przma.Vault.Profile

  def create(conn, params) do
    attrs = Map.put(profile_attrs(params), "tier", conn.assigns[:storage_tier] || 1)

    case Profile.create(actor(conn), conn.assigns.tenant_uuid, attrs) do
      :ok -> json(conn, %{status: "created"})
      {:error, :already_exists} -> conn |> put_status(409) |> json(%{error: "profile already exists"})
      {:error, reason} -> conn |> put_status(422) |> json(%{error: inspect(reason)})
    end
  end

  def show(conn, _params) do
    with {:ok, raw} <- Profile.get(actor(conn), conn.assigns.tenant_uuid),
         {:ok, profile} <- Jason.decode(raw) do
      json(conn, %{profile: profile})
    else
      {:error, reason} -> conn |> put_status(404) |> json(%{error: inspect(reason)})
    end
  end

  def update(conn, params) do
    case Profile.update(actor(conn), conn.assigns.tenant_uuid, profile_attrs(params)) do
      :ok -> json(conn, %{status: "updated"})
      {:error, reason} -> conn |> put_status(422) |> json(%{error: inspect(reason)})
    end
  end

  # actor built solely from conn.assigns (set by KeycloakAuth from the
  # verified JWT) — never from client-supplied params.
  defp actor(conn), do: %{did: conn.assigns.did, origin_instance_id: nil, portable_grant: nil}

  # Whitelist: clients can never set did, gid, email, tier or timestamps.
  defp profile_attrs(params), do: Map.take(params, ~w(display_name bio avatar_cid nickname))
end
