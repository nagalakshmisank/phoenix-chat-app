Good. This confirms it. Not an oversight — this is ADR-001, locked in April 2026 as part of the przma-platform-v1.0.0.tar.gz build. But the implication for namespace services and Horde is significant and worth walking through completely, because it fundamentally changes the nature of both.

What ADR-001 Actually Changed
The sqld/LibSQL removal was not just swapping one database for another. It changed the architectural topology of how user data is accessed.
sqld was a server. It ran as a separate process, listened on HTTP, and you connected to it. The NamespaceManager’s entire job — the HOT/WARM/COLD ETS connection pool, the JWT-scoped namespace tokens, the LibSQL HTTP pipeline client — existed because maintaining network connections to a server is expensive and needs lifecycle management.
LanceDB via Rustler NIF is embedded. It runs inside the Elixir process as a Rust library loaded as a shared object (.so). There is no server. There is no network connection. There is no connection pool to manage. There is no JWT to scope a namespace. There is no HTTP pipeline to call.

OLD:
Elixir process
  │
  ├─ NamespaceManager (GenServer)
  │    └─ ETS: {did → sqld_conn} HOT/WARM/COLD
  │         └─ LibSQL HTTP client
  │              └─ HTTP/2 → sqld server process → sqld database file
  │                          (separate OS process, separate memory)

NEW:
Elixir process
  │
  ├─ Rustler NIF (loaded once at boot, stays in memory)
  │    └─ LanceDB Rust library
  │         └─ LanceDB table handle → Arrow file on disk
  │              (same OS process, same BEAM memory space)


That entire left branch of the old architecture — NamespaceManager → ETS pool → LibSQL → HTTP → sqld — collapses into a single NIF call. The Rust runtime holds the LanceDB state; Elixir calls into it directly.

What Happens to the NamespaceManager
The Przma.Sync.NamespaceManager GenServer as designed for sqld is not needed in its original form. What remains useful is a much thinner concept: a file path resolver and optional table handle cache.
The “namespace” for LanceDB is not a server namespace — it is a filesystem path. The per-user isolation that sqld achieved via db_name = "przma_vault_{hash16_of_did}" and JWT scoping is achieved in LanceDB via the vault directory:

/var/przma/vaults/{did_hash}/
  ├── activity/
  │   ├── core/
  │   │   ├── perception_events.lance
  │   │   ├── preserve_events.lance
  │   │   ├── arc_history.lance
  │   │   ├── patterns.lance
  │   │   └── insights.lance
  │   └── commons/
  │       └── public_stream.lance
  ├── calendar/
  │   ├── core/
  │   │   ├── events.lance
  │   │   ├── tasks.lance
  │   │   └── meeting_invites.lance
  │   └── feeds/
  │       └── {feed_slug}/
  │           └── events.lance
  └── vault/
      ├── core/
      │   └── entries.lance
      └── private/
          └── estate/
              └── bequeathment_policy.lance


Access control is filesystem-level — the PRZMA process runs with permissions to all vault directories but the NIF enforces DID scoping by construction of the path. No JWT needed. No connection to scope. Just a correctly derived path.
The new NamespaceManager is therefore much simpler:

defmodule PRZMA.Vault.NamespaceManager do
  @moduledoc """
  Resolves pzdb:// URIs to LanceDB file paths and manages
  open table handle references in ETS.

  No HTTP. No JWT. No connection pool. No HOT/WARM/COLD tiers.
  Just path derivation and optional NIF handle caching.

  Called by PRZMA.PzDb — not by service modules directly.
  """

  @base_path Application.compile_env(:przma, [:vault, :base_path], "/var/przma/vaults")

  @doc "Derive the filesystem path for a pzdb:// URI."
  def path_for("pzdb://" <> rest) do
    [did | path_parts] = String.split(rest, "/")
    did_hash    = :crypto.hash(:sha256, did) |> Base.encode16(case: :lower) |> String.slice(0, 32)
    table_parts = Enum.drop(path_parts, -1)  # drop the record ID
    table_name  = List.last(table_parts)
    dir         = Path.join([@base_path, did_hash] ++ Enum.drop_while(table_parts, &(&1 == table_name)))

    %{
      did:        did,
      did_hash:   did_hash,
      table_dir:  dir,
      table_name: table_name,
      table_path: Path.join(dir, "#{table_name}.lance"),
      record_id:  List.last(path_parts),
    }
  end

  @doc "Ensure the vault directory for a DID exists."
  def ensure_vault_dirs(did_hash) do
    base = Path.join(@base_path, did_hash)
    File.mkdir_p!(base)
    :ok
  end
end


The ETS handle cache (if needed at all) caches the opaque NIF reference to an open LanceDB table, not a network connection:

# Optional — LanceDB tables may be fast enough to open on every call
# that caching handles adds complexity without enough benefit.
# Profile before adding ETS caching.


This is the key difference: in sqld, opening a connection was expensive (TCP handshake, auth, protocol negotiation). In LanceDB via NIF, opening a table is a file descriptor open — orders of magnitude cheaper. The ETS caching was essential for sqld; for LanceDB it may be unnecessary complexity.

What Happens to PRZMA.PzDb
The pzdb:// URI scheme is unchanged — it is the correct abstraction and all service code correctly uses it. Only the backing implementation changes:

defmodule PRZMA.PzDb do
  alias PRZMA.Vault.NamespaceManager
  alias PRZMA.NIF, as: LanceNIF  # the Rustler NIF module

  def write(uri, record, opts \\ []) do
    ns = NamespaceManager.path_for(uri)
    NamespaceManager.ensure_vault_dirs(ns.did_hash)

    row = record
      |> Map.put("id", ns.record_id)
      |> Map.put("did", ns.did)
      |> maybe_encrypt(opts[:encrypt], ns.did)
      |> Jason.encode!()

    # Single NIF call — no HTTP, no pool, no JWT
    case LanceNIF.lance_insert(ns.table_path, ns.record_id, row) do
      :ok       -> {:ok, ns.record_id}
      {:error, reason} -> {:error, reason}
    end
  end

  def read(uri) do
    ns = NamespaceManager.path_for(uri)
    case LanceNIF.lance_get(ns.table_path, ns.record_id) do
      {:ok, nil}  -> {:ok, %{found: false}}
      {:ok, json} -> {:ok, %{found: true, record: Jason.decode!(json)}}
      {:error, r} -> {:error, r}
    end
  end

  def query(uri, opts \\ []) do
    ns     = NamespaceManager.path_for(uri)
    filter = opts[:filter] || "deleted_at IS NULL"
    limit  = opts[:limit]  || 100

    # DuckDB SQL over Lance file — this is the ADR-001 pattern
    sql = "SELECT data FROM read_lance('#{ns.table_path}')
           WHERE #{filter} ORDER BY created_at DESC LIMIT #{limit}"

    case LanceNIF.duckdb_query(sql) do
      {:ok, rows_json} ->
        records = rows_json |> Jason.decode!() |> Enum.map(& &1["data"] |> Jason.decode!())
        {:ok, %{"records" => records}}
      {:error, reason} ->
        {:error, reason}
    end
  end

  def delete(uri, _did) do
    # Soft delete: set deleted_at
    ns  = NamespaceManager.path_for(uri)
    now = System.os_time(:microsecond)
    LanceNIF.lance_update(ns.table_path, ns.record_id, %{"deleted_at" => now})
  end

  defp maybe_encrypt(record, true, did) do
    key  = PRZMA.Vault.Crypto.get_vault_key(did)
    Map.put(record, "__encrypted", true)
    |> Jason.encode!()
    |> PRZMA.Crypto.aes_gcm_encrypt(key)
    |> Base.encode64()
    |> then(&%{"__ciphertext" => &1})
  end
  defp maybe_encrypt(record, _, _), do: record
end


What Happens to Horde
Horde’s role changes substantially. For sqld it was potentially useful for storage namespace distribution — if you ran multiple Phoenix nodes, you might want a cluster-wide view of which namespaces were hot. That use case disappears entirely with LanceDB because LanceDB is local-first and embedded. Each Phoenix node has its own LanceDB files. The storage layer does not span nodes — the S3 sync does.
Horde’s remaining role is now exclusively process distribution:

Horde role in LanceDB architecture:

STILL NEEDED:
  ├── PRZMA.Estate.Registry (Horde.Registry)
  │     Estate activators must be unique cluster-wide.
  │     Two nodes cannot both run an activation for the same owner_did.
  │
  ├── PRZMA.Agent.SessionRegistry (Horde.Registry)
  │     Agent sessions must be unique cluster-wide.
  │     A user's companion session should route to the same node.
  │
  └── PRZMA.Vault.WriteLockRegistry (Horde.Registry)
        Prevents concurrent Lance writes for the same DID from two nodes.
        LanceDB supports single-writer-multiple-reader; Horde enforces this.

NOT NEEDED:
  ├── Storage namespace registry (eliminated — just file paths)
  ├── Connection pool distribution (eliminated — no connections)
  └── sqld namespace HOT/WARM/COLD coordination (eliminated — no server)


The single-writer constraint is the most important Horde responsibility in the new architecture. LanceDB supports multiple concurrent readers but only one writer per table at a time. If two Phoenix nodes both try to write to alice‘s perception_events.lance, you get corruption. Horde’s Registry with unique keys solves this: before writing to any Lance table, claim a Horde lock for {did, table_name}. If the lock is already claimed on another node, route the write to that node’s process or queue it.

defmodule PRZMA.Vault.WriteLock do
  use GenServer

  def start_link({did, table}) do
    GenServer.start_link(__MODULE__, {did, table},
      name: {:via, Horde.Registry, {PRZMA.Vault.WriteLockRegistry, {did, table}}})
  end

  # Only one instance of this GenServer exists cluster-wide per {did, table} pair.
  # All writes for that table are serialized through this single process.
  def write(did, table_path, record_id, data) do
    via = {:via, Horde.Registry, {PRZMA.Vault.WriteLockRegistry, {did, table_path}}}
    case GenServer.whereis(via) do
      nil ->
        # Start a new write lock GenServer on this node
        {:ok, pid} = DynamicSupervisor.start_child(
          PRZMA.Vault.WriteLockSupervisor,
          {__MODULE__, {did, table_path}}
        )
        GenServer.call(pid, {:write, record_id, data})
      pid ->
        # Route to wherever the lock lives (Horde handles cross-node)
        GenServer.call(pid, {:write, record_id, data})
    end
  end
end


Updated Supervision Tree
The five domains from the March 2026 session update as follows:

defmodule PRZMA.Application do
  use Application

  def start(_type, _args) do
    children = [
      # Core infrastructure
      PRZMA.Repo,                          # PostgreSQL control plane — unchanged
      {Phoenix.PubSub, name: PRZMA.PubSub},
      PRZMAWeb.Presence,

      # ETS tables (before domains)
      PRZMA.ETS.Supervisor,

      # Horde cluster (process distribution — NOT storage distribution)
      {Horde.Registry, [name: PRZMA.Vault.WriteLockRegistry, keys: :unique, members: :auto]},
      {Horde.Registry, [name: PRZMA.Estate.Registry,        keys: :unique, members: :auto]},
      {Horde.Registry, [name: PRZMA.Agent.SessionRegistry,  keys: :unique, members: :auto]},
      {Horde.DynamicSupervisor, [name: PRZMA.Vault.WriteLockSupervisor, members: :auto]},

      # Oban (with correct queues)
      {Oban, Application.fetch_env!(:przma, Oban)},

      # Five domains
      PRZMA.Supervisors.VaultInfrastructure,
      PRZMA.Supervisors.IdentityFederation,
      PRZMA.Supervisors.FederationDelivery,
      PRZMA.Supervisors.SyncAnalytics,
      PRZMA.Supervisors.AIAgentLayer,

      PRZMAWeb.Endpoint,
    ]
    Supervisor.start_link(children, strategy: :one_for_one, name: PRZMA.Supervisor)
  end
end

defmodule PRZMA.Supervisors.VaultInfrastructure do
  use Supervisor
  def init(:ok) do
    children = [
      PRZMA.Lexicon.Registry,               # XRPC lexicon ETS table
      # REMOVED: Przma.Sync.NamespaceManager (sqld connection pool — gone)
      # REMOVED: Przma.Sqld.LibSQL           (sqld HTTP client — gone)
      # REMOVED: Przma.Sync.NotifyRegistry   (sqld notify channels — gone)
      # NEW: NIF is loaded at boot via :erlang.load_nif, not a GenServer
      PRZMA.Vault.NIF.Loader,               # ensures .so is loaded, validates NIF health
      PRZMA.Vault.S3.Client,                # S3 for blobs + Lance file sync
    ]
    Supervisor.init(children, strategy: :one_for_one)
  end
end

defmodule PRZMA.Supervisors.SyncAnalytics do
  use Supervisor
  def init(:ok) do
    children = [
      PRZMA.Activity.InsightEngine,         # NEW — insight expiry GenServer
      PRZMA.Sync.BroadwayPipeline,          # Broadway sync — still needed
      PRZMA.Telemetry,
    ]
    Supervisor.init(children, strategy: :one_for_one)
  end
end

defmodule PRZMA.Supervisors.AIAgentLayer do
  use Supervisor
  def init(:ok) do
    children = [
      PRZMA.Agent.AgentSupervisor,
      PRZMA.HOLNN.InferenceRouter,
      # Estate activation infrastructure
      {DynamicSupervisor, name: PRZMA.Estate.ActivationSupervisor, strategy: :one_for_one},
    ]
    Supervisor.init(children, strategy: :one_for_one)
  end
end


Summary of What Actually Changed



|Component                    |sqld era                                 |LanceDB era                                             |
|-----------------------------|-----------------------------------------|--------------------------------------------------------|
|`Przma.Sqld.LibSQL`          |HTTP pipeline client                     |**Deleted**                                             |
|`Przma.Sync.NamespaceManager`|Connection pool GenServer                |**Replaced** — thin path resolver, optional handle cache|
|`Przma.Sync.NotifyRegistry`  |sqld notify channel map                  |**Deleted** — LanceDB has no notify protocol            |
|`PRZMA.PzDb`                 |Façade → LibSQL → HTTP                   |**Re-backed** — Façade → NIF → Lance file               |
|Horde storage namespace role |Could distribute namespace connections   |**Eliminated** — no connections to distribute           |
|Horde process registry role  |Secondary use                            |**Primary use** — write locks, estate, agents           |
|Namespace isolation          |sqld `db_name` + JWT token               |Filesystem path + NIF call convention                   |
|ETS connection pool          |Essential — network connections expensive|Optional — file opens are cheap                         |
|Oban queues                  |`:default`, `:federation`                |**Add** `:maintenance` for Feed/Curation/Dormancy jobs  |

The architecture is cleaner now, not more complex. The entire network-connection-management layer is gone. What remains is: derive a path from a DID, call a NIF, get Arrow data back. Horde is a process coordination tool, not a storage routing tool. PRZMA.PzDb is the one place where pzdb:// URIs are resolved — nothing else in the codebase should know what backs them.​​​​​​​​​​​​​​​​