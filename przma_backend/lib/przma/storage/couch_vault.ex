defmodule Przma.Storage.CouchVault do
  @moduledoc """
  Creates (idempotently) the ONE CouchDB database a user owns:

      przma_did_przma_kc_user1          partitioned=true, q=1 (one shard)
      ├── _security        admin-only (Phoenix is the only client for now)
      ├── _design/przma    validate_doc_update generated from NamespacePolicy
      ├── _design/folders  view "tree": namespace → space → table, with counts
      └── idx-by-space     global Mango index on "space"

  This is infrastructure, not data: it creates no documents. Every
  DOCUMENT read/write still goes through PzdbConnector. To keep even
  provisioning tied to the authenticated user, ensure_user_db/2 refuses
  to create a database for any DID other than the actor's own.

  Safe to call on every registration: an existing database is checked
  (must be partitioned), security is re-applied, and the design doc is
  only re-pushed when NamespacePolicy has changed.
  """

  alias Przma.Storage.{CouchClient, CouchDbName, CouchDesign}

  # Empty members would make the database readable by ANY CouchDB user.
  # "_admin" role only = locked to server admins (the Phoenix service).
  @security %{
    "admins" => %{"names" => [], "roles" => ["_admin"]},
    "members" => %{"names" => [], "roles" => ["_admin"]}
  }

  # Folder-style listing for Fauxton / curl:
  #   GET /{db}/_design/folders/_view/tree?group_level=1  -> namespaces
  #   GET /{db}/_design/folders/_view/tree?group_level=2  -> namespace/space folders
  #   GET /{db}/_design/folders/_view/tree?group_level=3  -> tables inside each folder
  @folders_design %{
    "_id" => "_design/folders",
    "language" => "javascript",
    "options" => %{"partitioned" => false},
    "views" => %{
      "tree" => %{
        "map" =>
          "function (doc) { if (doc.namespace && doc.space && doc.table) { emit([doc.namespace, doc.space, doc.table], 1); } }",
        "reduce" => "_count"
      }
    }
  }

  @space_index %{
    "index" => %{"fields" => ["space"]},
    "name" => "by-space",
    "ddoc" => "idx-by-space",
    "type" => "json",
    "partitioned" => false
  }

  @spec ensure_user_db(actor :: %{did: String.t()}, did :: String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def ensure_user_db(%{did: actor_did}, did) when actor_did != did,
    do: {:error, :cannot_provision_other_users_database}

  def ensure_user_db(_actor, did) do
    db = CouchDbName.from_did(did)

    with :ok <- ensure_partitioned_db(db),
         :ok <- CouchClient.put_security(db, @security),
         :ok <- ensure_design(db),
         :ok <- ensure_doc(db, @folders_design),
         :ok <- CouchClient.create_index(db, @space_index) do
      {:ok, db}
    end
  end

  defp ensure_partitioned_db(db) do
    case CouchClient.create_db(db, partitioned: true, q: 1) do
      :ok ->
        :ok

      {:error, :db_exists} ->
        case CouchClient.db_info(db) do
          {:ok, %{"props" => %{"partitioned" => true}}} -> :ok
          {:ok, _} -> {:error, {:database_not_partitioned, db}}
          err -> err
        end

      err ->
        err
    end
  end

  defp ensure_design(db) do
    desired = CouchDesign.design_doc()
    version = desired["policy_version"]

    case CouchClient.get_doc(db, CouchDesign.design_id()) do
      {:ok, %{"policy_version" => ^version}} -> :ok
      {:ok, %{"_rev" => rev}} -> put(db, Map.put(desired, "_rev", rev))
      {:error, :not_found} -> put(db, desired)
      err -> err
    end
  end

  # Create-only: an existing doc with the same id is left as it is.
  defp ensure_doc(db, %{"_id" => id} = doc) do
    case CouchClient.get_doc(db, id) do
      {:ok, _} -> :ok
      {:error, :not_found} -> put(db, doc)
      err -> err
    end
  end

  defp put(db, doc) do
    case CouchClient.put_doc(db, doc) do
      {:ok, _rev} -> :ok
      err -> err
    end
  end
end
