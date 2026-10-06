defmodule Przma.Social.Directory do
  @moduledoc """
  The ONE shared database (everything else is one database per user).
  It holds only what users must be able to look up about each other:

      social:public:accounts:{did_key}     did, nickname, display name, tenant id
      circle:public:invites:{invite_code}  invite code -> circle id + owner
      circle:public:index:{circle_id}      public circles (discovery)

  It is an ordinary CouchDB database created through CouchVault, owned by
  a reserved system DID that can never be a Keycloak username, so it gets
  the same partitioning, security and validate_doc_update as a user
  database. Its name is `Przma.Social.Directory.database/0`.
  """

  require Logger

  alias Przma.Social.{Cache, Key, Store}
  alias Przma.Storage.{CouchDbName, CouchVault}
  alias Przma.Vault.{Profile, PzdbConnector}

  @did "did:przma-system:directory"
  @gid "system"

  def did, do: @did
  def database, do: CouchDbName.from_did(@did)

  # ── accounts ─────────────────────────────────────────────────────────

  @doc "Creates/updates the caller's account record. Best-effort: logs and returns :ok on failure."
  def put_account(did, gid, attrs \\ %{}) do
    attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)

    fields =
      %{"account_did" => did, "tenant_id" => gid, "status" => "active"}
      |> put_present("nickname", attrs["nickname"])
      |> put_present("display_name", attrs["display_name"])
      |> put_present("avatar_cid", attrs["avatar_cid"])

    case write("social", "accounts", Key.did_key(did), fields) do
      :ok ->
        Cache.delete({:account, did})
        :ok

      {:error, reason} ->
        Logger.warning("Directory.put_account failed for #{did}: #{inspect(reason)}")
        :ok
    end
  end

  @doc """
  Makes sure the caller has an account record (covers users who
  registered before the directory existed). Cached, so after the first
  call it costs nothing.
  """
  def ensure_account(did, gid) do
    case Cache.get({:ensured, did}) do
      {:ok, true} ->
        :ok

      :miss ->
        case Store.get(@did, "social", "accounts", Key.did_key(did), space: "public") do
          {:ok, %{"tenant_id" => ^gid}} -> :ok
          _ -> put_account(did, gid, profile_fields(did))
        end

        Cache.put({:ensured, did}, true)
        :ok
    end
  end

  @doc "Account record of any user, or {:error, :unknown_user}."
  def account(did) when is_binary(did) do
    case Cache.get({:account, did}) do
      {:ok, account} ->
        {:ok, account}

      :miss ->
        with {:error, _} <- Store.get(@did, "social", "accounts", Key.did_key(did), space: "public"),
             {:error, _} <- account_from_profile(did) do
          {:error, :unknown_user}
        else
          {:ok, account} ->
            Cache.put({:account, did}, account)
            {:ok, account}
        end
    end
  end

  def account(_), do: {:error, :unknown_user}

  @doc "Best name to show for a DID: display name, else nickname, else the DID itself."
  def display_name(did) do
    case account(did) do
      {:ok, %{"display_name" => n}} when is_binary(n) and n != "" -> n
      {:ok, %{"nickname" => n}} when is_binary(n) and n != "" -> n
      _ -> did
    end
  end

  @doc "Tenant id (Keycloak sub) of a DID — needed to stamp `gid` on documents written for that user."
  def gid_for(@did), do: {:ok, @gid}

  def gid_for(did) do
    with {:ok, %{"tenant_id" => gid}} when is_binary(gid) <- account(did) do
      {:ok, gid}
    else
      _ -> {:error, :unknown_user}
    end
  end

  @doc "did:przma:<nickname> if that account exists (the DID is derived from the Keycloak username)."
  def lookup_nickname(nickname) when is_binary(nickname) do
    account("did:przma:" <> String.trim(nickname))
  end

  # ── circle invites ───────────────────────────────────────────────────

  def put_invite(code, circle_id, owner_did) do
    write("circle", "invites", code, %{"circle_id" => circle_id, "owner_did" => owner_did, "status" => "active"})
  end

  def invite(code) do
    with true <- Key.valid_id?(code),
         {:ok, %{"status" => "active"} = invite} <- Store.get(@did, "circle", "invites", code, space: "public") do
      {:ok, invite}
    else
      _ -> {:error, :invite_not_found}
    end
  end

  def close_invite(code), do: write("circle", "invites", code, %{"status" => "closed"})

  # ── public circle index ──────────────────────────────────────────────

  def index_circle(circle_id, owner_did, name) do
    write("circle", "index", circle_id, %{
      "circle_id" => circle_id,
      "owner_did" => owner_did,
      "name" => name,
      "status" => "active"
    })
  end

  def unindex_circle(circle_id) do
    case Store.get(@did, "circle", "index", circle_id, space: "public") do
      {:ok, _} -> write("circle", "index", circle_id, %{"status" => "removed"})
      _ -> :ok
    end
  end

  def public_circle(circle_id) do
    with true <- Key.valid_id?(circle_id),
         {:ok, %{"status" => "active"} = row} <- Store.get(@did, "circle", "index", circle_id, space: "public") do
      {:ok, row}
    else
      _ -> {:error, :not_found}
    end
  end

  def list_public_circles(limit \\ 50) do
    with {:ok, rows} <- Store.list(@did, "circle", "index", space: "public", limit: 1000) do
      {:ok, rows |> Enum.filter(&(&1["status"] == "active")) |> Enum.take(limit)}
    end
  end

  # ── private ──────────────────────────────────────────────────────────

  defp write(namespace, table, id, fields) do
    with :ok <- ensure_database() do
      Store.put(@did, namespace, table, id, fields, space: "public", gid: @gid)
    end
  end

  defp ensure_database do
    case Cache.get(:directory_ready) do
      {:ok, true} ->
        :ok

      :miss ->
        with {:ok, _db} <- CouchVault.ensure_user_db(%{did: @did}, @did) do
          Cache.put(:directory_ready, true)
          :ok
        end
    end
  end

  # A user who registered before the directory existed still has a
  # profile document; read tenant id and nickname from it and backfill.
  defp account_from_profile(did) do
    case read_profile(did) do
      {:ok, %{"gid" => gid} = profile} when is_binary(gid) ->
        put_account(did, gid, profile)
        Store.get(@did, "social", "accounts", Key.did_key(did), space: "public")

      _ ->
        {:error, :unknown_user}
    end
  end

  defp profile_fields(did) do
    case read_profile(did) do
      {:ok, profile} -> profile
      _ -> %{}
    end
  end

  defp read_profile(did) do
    actor = %{did: did, origin_instance_id: nil, portable_grant: nil}

    with {:ok, raw} <- PzdbConnector.read(actor, Profile.uri("read", did)),
         {:ok, %{} = profile} <- Jason.decode(raw) do
      {:ok, profile}
    else
      _ -> {:error, :not_found}
    end
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
