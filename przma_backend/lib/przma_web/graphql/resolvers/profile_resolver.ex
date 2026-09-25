defmodule PRZMAWeb.Graphql.Resolvers.ProfileResolver do
  @moduledoc """
  GraphQL profile resolvers. Every call goes Profile -> PzdbConnector
  (pzdb URI, NamespacePolicy, PzdbAuthorization) -> DocStoreAdapter.
  """
  alias Przma.Vault.Profile

  def show(_args, %{context: %{did: did} = context}) when is_binary(did) do
    fetch(context)
  end

  def show(_args, _resolution), do: {:error, "unauthorized"}

  def create(args, %{context: %{did: did} = context}) when is_binary(did) do
    attrs = Map.put(profile_attrs(args), :tier, context.storage_tier)

    case Profile.create(actor(context), context.tenant_uuid, attrs) do
      :ok -> fetch(context)
      {:error, :already_exists} -> {:error, "profile already exists — use updateProfile"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  def create(_args, _resolution), do: {:error, "unauthorized"}

  def update(args, %{context: %{did: did} = context}) when is_binary(did) do
    case Profile.update(actor(context), context.tenant_uuid, profile_attrs(args)) do
      :ok -> fetch(context)
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  def update(_args, _resolution), do: {:error, "unauthorized"}

  @doc false
  def fetch(context) do
    with {:ok, raw} <- Profile.get(actor(context), context.tenant_uuid),
         {:ok, %{} = decoded} <- Jason.decode(raw) do
      {:ok, to_graphql(decoded)}
    else
      {:error, reason} -> {:error, inspect(reason)}
      _ -> {:error, "profile could not be decoded"}
    end
  end

  defp actor(context), do: %{did: context.did, origin_instance_id: nil, portable_grant: nil}

  # Whitelist — clients can never set did, gid, email, tier or timestamps.
  defp profile_attrs(args), do: Map.take(args, [:display_name, :bio, :avatar_cid, :nickname])

  defp to_graphql(p) do
    %{
      did: p["did"],
      email: p["email"],
      nickname: p["nickname"],
      display_name: p["display_name"],
      bio: p["bio"],
      avatar_cid: p["avatar_cid"],
      created_at: iso(p["created_at"]),
      updated_at: iso(p["updated_at"])
    }
  end

  defp iso(us) when is_integer(us), do: us |> DateTime.from_unix!(:microsecond) |> DateTime.to_iso8601()
  defp iso(_), do: nil
end
