defmodule Przma.Social.Store do
  @moduledoc """
  The one place the social services (chat, circle, contacts, follows,
  notifications) read and write documents. Everything goes through
  PzdbConnector, so the pzdb URI, NamespacePolicy and PzdbAuthorization
  checks still run for every call, exactly as they do for profile/files.

  WHOSE DATABASE: each call names the DID whose database is touched and
  runs as that database's owner. The caller is therefore responsible for
  deciding whether the logged-in user may touch it. The rules the callers
  follow:

    * a user's own request reads/writes that user's own database
    * Przma.Chat.Delivery writes into a RECIPIENT's database
      (inbox item, chat-list counter, circle membership pointer)
    * Przma.Circle.* reads/writes circle data in the circle OWNER's
      database, only after an invite-code or role check

  No resolver calls this module directly.

  Field names to avoid in `fields` (DocStoreAdapter sets or drops them):
  id, tier, type, namespace, space, table, did, gid, created_at, updated_at.
  """

  alias Przma.Vault.{PzdbConnector, PzdbUri}

  @type did :: String.t()

  @doc "One document by record id. {:error, :not_found} when it (or the database) does not exist."
  @spec get(did(), String.t(), String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def get(did, namespace, table, id, opts \\ []) do
    with {:ok, raw} <- PzdbConnector.read_by_id(actor(did), uri(did, namespace, table, "read", opts), id),
         {:ok, %{} = doc} <- Jason.decode(raw) do
      {:ok, doc}
    else
      {:error, _} = err -> err
      _ -> {:error, :invalid_document}
    end
  end

  @doc """
  Creates the document or merges `fields` into the existing one (fields
  not mentioned are kept). Supports the adapter's atomic operations:
  "$inc" => %{"unread_count" => 1}, "$add_to_set" => %{...}.
  """
  @spec put(did(), String.t(), String.t(), String.t(), map(), keyword()) :: :ok | {:error, term()}
  def put(did, namespace, table, id, fields, opts \\ []) do
    with {:ok, gid} <- gid(did, opts) do
      row = fields |> Map.new(fn {k, v} -> {to_string(k), v} end) |> Map.put("id", id)
      PzdbConnector.upsert(actor(did), uri(did, namespace, table, gid, opts), [row], [:id])
    end
  end

  @doc """
  Ordered list of a table's documents. Options: :prefix, :after, :before,
  :limit, :descending (see DocStoreAdapter.query_range/2) and :space.
  """
  @spec list(did(), String.t(), String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def list(did, namespace, table, opts \\ []) do
    {uri_opts, range_opts} = Keyword.split(opts, [:space])

    with {:ok, raw} <- PzdbConnector.read_range(actor(did), uri(did, namespace, table, "read", uri_opts), range_opts),
         {:ok, rows} when is_list(rows) <- Jason.decode(raw) do
      {:ok, rows}
    else
      {:error, _} = err -> err
      _ -> {:error, :invalid_document}
    end
  end

  # ── private ──────────────────────────────────────────────────────────

  defp actor(did), do: %{did: did, origin_instance_id: nil, portable_grant: nil}

  # The tenant id (Keycloak `sub`) is stamped on every written document
  # as `gid`, so writes need the real one. Reads do not use it.
  defp gid(did, opts) do
    case Keyword.get(opts, :gid) do
      gid when is_binary(gid) and gid != "" -> {:ok, gid}
      _ -> Przma.Social.Directory.gid_for(did)
    end
  end

  defp uri(did, namespace, table, tenant, opts) do
    %PzdbUri{
      transport: :s3,
      tenant_id: tenant,
      did: did,
      namespace: namespace,
      space: Keyword.get(opts, :space, "private"),
      table: table
    }
    |> PzdbUri.to_string()
  end
end
