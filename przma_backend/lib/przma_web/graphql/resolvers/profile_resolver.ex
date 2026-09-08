defmodule PRZMAWeb.Graphql.Resolvers.ProfileResolver do
  alias Przma.Vault.Profile

  def show(_args, %{context: context}) do
    case Profile.get(actor(context), context.tenant_uuid) do
      {:ok, raw} -> {:ok, decode_profile(raw)}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  def create(args, %{context: context}) do
    case Profile.create(actor(context), context.tenant_uuid, profile_attrs(args)) do
      :ok -> {:ok, %{did: context.did}}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  def update(args, %{context: context}) do
    case Profile.update(actor(context), context.tenant_uuid, profile_attrs(args)) do
      :ok -> {:ok, %{did: context.did}}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp actor(context), do: %{did: context.did, origin_instance_id: nil, portable_grant: nil, roles: context.roles}
  defp profile_attrs(args), do: Map.take(args, [:display_name, :bio, :avatar_cid])

  defp decode_profile(raw) do
    case Jason.decode(raw) do
      {:ok, %{} = decoded} ->
        %{did: decoded["did"], display_name: decoded["display_name"], bio: decoded["bio"], avatar_cid: decoded["avatar_cid"]}
      _ ->
        %{did: nil, display_name: nil, bio: nil, avatar_cid: nil}
    end
  end
end