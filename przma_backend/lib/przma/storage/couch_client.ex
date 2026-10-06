defmodule Przma.Storage.CouchClient do
  @moduledoc """
  Thin HTTP client for CouchDB, built on :hackney (already a dependency).

  ACCESS RULE — this module is internal plumbing, not an API:

    * Przma.Vault.DocStoreAdapter  — document reads/writes, reached ONLY
      through PzdbConnector (pzdb URI + NamespacePolicy + PzdbAuthorization)
    * Przma.Storage.CouchVault     — per-user database provisioning

  No other module may call it. test/przma/architecture_guard_test.exs
  fails the build if anything else references this module.

  Credentials come from config :przma, :couchdb (runtime.exs, env vars).
  They are sent as a Basic auth header — never put them in COUCHDB_URL,
  so they never appear in logs.
  """

  @type db :: String.t()
  @type doc_id :: String.t()

  # ── databases ────────────────────────────────────────────────────────

  @doc """
  Creates a database. Both options must be chosen at creation — neither
  can be changed later without copying the database:
    * partitioned: true  — namespace becomes a CouchDB partition
    * q: 1               — shard count; 1 keeps small per-user DBs to one file
  """
  @spec create_db(db(), keyword()) :: :ok | {:error, :db_exists | term()}
  def create_db(db, opts \\ []) do
    params =
      [
        if(Keyword.get(opts, :partitioned, false), do: "partitioned=true"),
        if(q = Keyword.get(opts, :q), do: "q=#{q}")
      ]
      |> Enum.reject(&is_nil/1)

    query = if params == [], do: "", else: "?" <> Enum.join(params, "&")

    case request(:put, db_path(db) <> query, nil) do
      {:ok, status, _} when status in [201, 202] -> :ok
      {:ok, 412, _} -> {:error, :db_exists}
      other -> to_error(other)
    end
  end

  @spec db_info(db()) :: {:ok, map()} | {:error, :not_found | term()}
  def db_info(db) do
    case request(:get, db_path(db), nil) do
      {:ok, 200, body} -> {:ok, body}
      {:ok, 404, _} -> {:error, :not_found}
      other -> to_error(other)
    end
  end

  @doc "Deletes a database. Used by integration tests for cleanup."
  @spec delete_db(db()) :: :ok | {:error, term()}
  def delete_db(db) do
    case request(:delete, db_path(db), nil) do
      {:ok, status, _} when status in [200, 202, 404] -> :ok
      other -> to_error(other)
    end
  end

  @spec put_security(db(), map()) :: :ok | {:error, term()}
  def put_security(db, security) do
    case request(:put, db_path(db) <> "/_security", security) do
      {:ok, 200, _} -> :ok
      other -> to_error(other)
    end
  end

  @doc "Creates a Mango index. Idempotent — CouchDB answers \"exists\" for a repeat."
  @spec create_index(db(), map()) :: :ok | {:error, term()}
  def create_index(db, index_def) do
    case request(:post, db_path(db) <> "/_index", index_def) do
      {:ok, 200, _} -> :ok
      other -> to_error(other)
    end
  end

  # ── documents ────────────────────────────────────────────────────────

  @spec get_doc(db(), doc_id()) :: {:ok, map()} | {:error, :not_found | term()}
  def get_doc(db, id) do
    case request(:get, doc_path(db, id), nil) do
      {:ok, 200, body} -> {:ok, body}
      {:ok, 404, _} -> {:error, :not_found}
      other -> to_error(other)
    end
  end

  @doc """
  Creates or updates a document. To update, the map must carry the
  current "_rev". Returns the new revision.
  """
  @spec put_doc(db(), map()) ::
          {:ok, String.t()} | {:error, :conflict | :database_not_found | {:forbidden, String.t()} | term()}
  def put_doc(db, %{"_id" => id} = doc) do
    case request(:put, doc_path(db, id), doc) do
      {:ok, status, %{"rev" => rev}} when status in [201, 202] -> {:ok, rev}
      {:ok, 409, _} -> {:error, :conflict}
      {:ok, 403, %{"reason" => reason}} -> {:error, {:forbidden, reason}}
      {:ok, 404, _} -> {:error, :database_not_found}
      other -> to_error(other)
    end
  end

  @doc """
  All documents in `partition` whose _id starts with `prefix`, sorted by
  _id (e.g. partition "files", prefix "files:private:index:"). Uses the
  partition's own _all_docs, so only that namespace is read.
  Returns {:error, :not_found} when the database does not exist.
  """
  @spec list_by_prefix(db(), String.t(), String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def list_by_prefix(db, partition, prefix, opts \\ []) do
    query =
      URI.encode_query(%{
        "startkey" => Jason.encode!(prefix),
        "endkey" => Jason.encode!(prefix <> "\u{FFF0}"),
        "include_docs" => "true",
        "limit" => Integer.to_string(Keyword.get(opts, :limit, 1000))
      })

    case request(:get, db_path(db) <> "/_partition/" <> encode(partition) <> "/_all_docs?" <> query, nil) do
      {:ok, 200, %{"rows" => rows}} -> {:ok, for(%{"doc" => doc} <- rows, is_map(doc), do: doc)}
      {:ok, 404, _} -> {:error, :not_found}
      other -> to_error(other)
    end
  end

  @doc """
  Documents in `partition` between two _id keys, sorted by _id. Used for
  paged, ordered reads (a chat thread, newest first). `startkey` and
  `endkey` are full document ids; with `descending: true` pass the HIGH
  key as `startkey` and the LOW key as `endkey` (CouchDB's own rule).
  Returns {:error, :not_found} when the database does not exist.
  """
  @spec list_range(db(), String.t(), String.t(), String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def list_range(db, partition, startkey, endkey, opts \\ []) do
    query =
      URI.encode_query(%{
        "startkey" => Jason.encode!(startkey),
        "endkey" => Jason.encode!(endkey),
        "include_docs" => "true",
        "descending" => to_string(Keyword.get(opts, :descending, false)),
        "limit" => Integer.to_string(Keyword.get(opts, :limit, 200))
      })

    case request(:get, db_path(db) <> "/_partition/" <> encode(partition) <> "/_all_docs?" <> query, nil) do
      {:ok, 200, %{"rows" => rows}} -> {:ok, for(%{"doc" => doc} <- rows, is_map(doc), do: doc)}
      {:ok, 404, _} -> {:error, :not_found}
      other -> to_error(other)
    end
  end

  # ── internal ─────────────────────────────────────────────────────────

  defp db_path(db), do: "/" <> encode(db)

  # "_design/x" keeps its slash; every other id is fully percent-encoded
  # (":" becomes %3A, which CouchDB accepts).
  defp doc_path(db, "_design/" <> name), do: db_path(db) <> "/_design/" <> encode(name)
  defp doc_path(db, id), do: db_path(db) <> "/" <> encode(id)

  defp encode(segment), do: URI.encode(segment, &URI.char_unreserved?/1)

  defp request(method, path, body) do
    with {:ok, cfg} <- config() do
      url = String.trim_trailing(cfg[:url], "/") <> path

      headers =
        [
          {"authorization", "Basic " <> Base.encode64("#{cfg[:username]}:#{cfg[:password]}")},
          {"accept", "application/json"}
        ] ++ if(body, do: [{"content-type", "application/json"}], else: [])

      payload = if body, do: Jason.encode!(body), else: ""
      opts = [:with_body, recv_timeout: cfg[:timeout] || 15_000, connect_timeout: 5_000]

      case :hackney.request(method, url, headers, payload, opts) do
        {:ok, status, _headers, resp_body} -> {:ok, status, decode(resp_body)}
        {:error, reason} -> {:error, {:couchdb_unreachable, reason}}
      end
    end
  end

  defp decode(""), do: %{}

  defp decode(raw) do
    case Jason.decode(raw) do
      {:ok, decoded} -> decoded
      _ -> %{"raw" => raw}
    end
  end

  defp to_error({:ok, status, body}), do: {:error, {:couchdb_http, status, body}}
  defp to_error({:error, _} = err), do: err

  defp config do
    cfg = Application.get_env(:przma, :couchdb, [])

    if cfg[:url] && cfg[:username] && cfg[:password] do
      {:ok, cfg}
    else
      {:error, :couchdb_not_configured}
    end
  end
end
