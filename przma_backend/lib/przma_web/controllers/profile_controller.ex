defmodule PRZMAWeb.ProfileController do
  use PRZMAWeb, :controller
  alias Przma.Vault.Profile

  def create(conn, params) do
    case Profile.create(actor(conn), conn.assigns.tenant_uuid, profile_attrs(params)) do
      :ok -> json(conn, %{status: "created"})
      {:error, reason} -> conn |> put_status(422) |> json(%{error: inspect(reason)})
    end
  end

  def show(conn, _params) do
    case Profile.get(actor(conn), conn.assigns.tenant_uuid) do
      {:ok, data} -> json(conn, %{profile: data})
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
  # verified JWT) — never from client-supplied params, so a request
  # body can't override which DID gets written to.
  defp actor(conn), do: %{did: conn.assigns.did, origin_instance_id: nil, portable_grant: nil}

  defp profile_attrs(params), do: Map.take(params, ~w(display_name bio avatar_cid))
end
