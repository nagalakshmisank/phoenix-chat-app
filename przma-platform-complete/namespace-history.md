I have This is not a simple oversight — there are layered gaps. 
Let me give you the complete analysis.

The analysis confirmed Przma.Sync.NamespaceManager, Przma.Sqld.LibSQL, and Przma.ServiceRegistry were all missing from the codebase despite being called in 12+ Phase 2 files. Code was generated in that session. It exists.
The March 23, 2026 session (6a1b9f9b) showed an earlier PRZMA.Application supervision tree (uppercase namespace) evolved from the original XRPC/Lexicon work. 
This created a second, slightly different supervisor structure running in parallel.
The current conversation then built the Activity Stream, Calendar Extensions, and Memorial Vault on top of PRZMA.PzDb — which is a wrapper abstraction — without wiring any of the new services into either supervision tree.

The Three-Layer Problem
Layer 1: Namespace inconsistency (historical)
Two naming conventions exist across the codebase and they are not reconciled:

March 2026 session:           Current conversation code:
Przma.Sync.NamespaceManager   PRZMA.Activity.StreamWriter
Przma.Sqld.LibSQL             PRZMA.Calendar.MeetingInvite
Przma.Vault.CASStore          PRZMA.Estate.BequeathmentPolicy
Przma.Application             PRZMAWeb.EstateController


Lowercase Przma.* is the umbrella app module namespace from the detailed Phase 2 build. Uppercase PRZMA.* crept in from the earlier XRPC session and was never unified. These are not aliases — they are different module atoms in the Erlang VM. The supervision tree that starts Przma.Sync.NamespaceManager will not boot PRZMA.Activity.StreamWriter. They are invisible to each other in the OTP supervision hierarchy.
Layer 2: New services not registered in the supervision tree
The five supervisor domains defined in the March 2026 session cover:

Przma.Supervisors.VaultInfrastructure   ← NamespaceManager, CASStore, LexiconRegistry
Przma.Supervisors.IdentityFederation    ← DIDResolver, KeyManager, Ed25519
Przma.Supervisors.FederationDelivery    ← Bridge B11, ActivityPub, APDeliveryJob
Przma.Supervisors.SyncAnalytics         ← SyncEngine, Broadway pipeline, Telemetry
Przma.Supervisors.AIAgentLayer          ← InferenceRouter, PatternDetector, AgentSupervisor


None of the new work is registered in any of these:

NOT in any supervision domain:
  PRZMA.Activity.StreamWriter        (no supervisor → crashes are unrecoverable)
  PRZMA.Activity.InsightEngine       (no supervisor)
  PRZMA.Activity.CurationJob         (Oban job — registered, but Oban queue missing)
  PRZMA.Estate.ActivationSupervisor  (dynamic supervisor — never started)
  PRZMA.Estate.Registry              (Phoenix Registry — never started)
  PRZMA.Estate.DormancyMonitor       (Oban job — queue not declared)
  PRZMA.Calendar.FeedSyncJob         (Oban queue :maintenance not declared)
  PRZMA.Calendar.APInboxHandler      (no supervisor)


Layer 3: PRZMA.PzDb — the abstraction with no backing implementation visible
All new modules call PRZMA.PzDb.write/3 and PRZMA.PzDb.read/1. The actual implementation that makes these calls work is Przma.Sync.NamespaceManager.execute/3 and Przma.Sync.NamespaceManager.query/3 from the March 2026 session. PRZMA.PzDb is a façade that needs to delegate to the NamespaceManager — but that delegation was never written, only assumed.

What Actually Needs to Happen
Fix 1: Resolve the namespace convention — pick one and apply it
The right answer is PRZMA.* everywhere (uppercase) because that is what the web layer, controllers, and new modules already use. The March 2026 Przma.* modules should be aliased or renamed. In Elixir this is a compile-time concern — you need consistency in defmodule declarations.

# In config/config.exs, establish the canonical namespace:
# All modules use PRZMA.* — the Przma.* modules from March session
# are aliased at the application boundary:

defmodule PRZMA.Sqld.LibSQL do
  # Delegate to the existing Przma.Sqld.LibSQL if keeping both,
  # or simply rename all Przma.* to PRZMA.*
end


Fix 2: Wire PRZMA.PzDb to the NamespaceManager
The PRZMA.PzDb module is the correct abstraction layer. It just needs its implementation written:

defmodule PRZMA.PzDb do
  alias PRZMA.Sync.NamespaceManager  # or Przma.Sync.NamespaceManager

  def write(uri, record, opts \\ []) do
    with {:ok, did}    <- extract_did(uri),
         {:ok, ns}     <- NamespaceManager.get_or_warm(did),
         {table, id}   <- parse_uri(uri),
         json          <- prepare_record(record, opts),
         :ok           <- NamespaceManager.execute(ns,
           "INSERT OR REPLACE INTO #{table} (id, data, updated_at)
            VALUES (?, ?, ?)",
           [id, json, System.os_time(:microsecond)]) do
      {:ok, id}
    end
  end

  def read(uri) do
    with {:ok, did}    <- extract_did(uri),
         {:ok, ns}     <- NamespaceManager.get_or_warm(did),
         {table, id}   <- parse_uri(uri),
         {:ok, rows}   <- NamespaceManager.query(ns,
           "SELECT data FROM #{table} WHERE id = ? AND deleted_at IS NULL",
           [id]) do
      case rows do
        [%{"data" => json} | _] ->
          {:ok, %{found: true, record: Jason.decode!(json)}}
        [] ->
          {:ok, %{found: false}}
      end
    end
  end

  def query(uri, opts \\ []) do
    # ... same pattern with WHERE clause building
  end

  def delete(uri, did) do
    # Soft delete: set deleted_at timestamp
  end

  # Parse "pzdb://did/space/table/id" → {did, space, table, id}
  defp extract_did("pzdb://" <> rest) do
    case String.split(rest, "/", parts: 2) do
      [did | _] -> {:ok, did}
      _         -> {:error, :invalid_uri}
    end
  end

  defp parse_uri("pzdb://" <> rest) do
    parts = String.split(rest, "/")
    table = parts |> Enum.drop(1) |> Enum.drop(-1) |> Enum.join("_")
    id    = List.last(parts)
    {table, id}
  end
end


Fix 3: Register all new services in the correct supervision domain
The five supervision domains should be updated:

defmodule PRZMA.Supervisors.SyncAnalytics do
  # ADD to existing children:
  PRZMA.Activity.InsightEngine,        # GenServer — insight expiry management
  PRZMA.Activity.LexiconDetector,      # ETS-backed term index (stateless, no supervisor needed)
end

defmodule PRZMA.Supervisors.FederationDelivery do
  # ADD to existing children:
  PRZMA.Calendar.APInboxHandler,       # AP inbox processing
  PRZMA.Activity.CommonsPublisher,     # AP federation for activity stream
end

defmodule PRZMA.Supervisors.AIAgentLayer do
  # ADD: the estate activation infrastructure
  {Registry, keys: :unique, name: PRZMA.Estate.Registry},
  {DynamicSupervisor, name: PRZMA.Estate.ActivationSupervisor, strategy: :one_for_one},
  PRZMA.Estate.DormancyMonitor,        # schedules itself via Oban on boot
end


Fix 4: Add missing Oban queues to config

# config/config.exs
config :przma, Oban,
  queues: [
    default:     10,
    maintenance: 5,   # FeedSyncJob, CurationJob, DormancyMonitor ← MISSING
    federation:  5,   # APDeliveryJob
    high:        20,  # agent jobs
  ]


The pzdb:// Namespace — How It Actually Maps
The pzdb:// URI scheme is the namespace system for PRZMA data. Each URI segment is a routing decision:

pzdb://  did:web:alice.com  /calendar/core/events/  abc123
         │                   │              │         │
         DID                 service        table     record ID
         ↓                   ↓              ↓
    NamespaceManager     determines      used as
    routes to this       sqld table      PRIMARY KEY
    user's sqld db       name            in that table


The db_name for the sqld instance is a hash of the DID:

# From the March 2026 NamespaceManager code:
defp db_name_for(did) do
  hash = :crypto.hash(:sha256, did) |> Base.encode16(case: :lower) |> String.slice(0, 16)
  "przma_vault_#{hash}"
end


Every pzdb:// write goes through: URI parsing → DID extraction → db_name_for(did) → NamespaceManager.get_or_warm(did) → HOT/WARM/COLD lookup in ETS → LibSQL.execute/3 → sqld HTTP pipeline API → response.
The calendar namespace, activity stream namespace, estate namespace, and memorial registry namespace all work through this single routing path. The PRZMA.PzDb façade is correct — it just needs its body implemented as shown above.

Summary
This is not an oversight in the current code’s intent — the abstraction is right. The gaps are:
1. Namespace casing — Przma.* vs PRZMA.* needs to be unified across all sessions’ output before compilation.
2. PRZMA.PzDb needs its body — the delegation from the façade to NamespaceManager.get_or_warm → execute/query was designed but not written.
3. Six new services need supervision — InsightEngine, APInboxHandler, CommonsPublisher, Estate.Registry, ActivationSupervisor, and DormancyMonitor are not in any supervision tree and will crash unrecoverably on failure.
4. Two Oban queues are missing — :maintenance and the Oban child spec itself needs the new queues declared, otherwise FeedSyncJob, CurationJob, and DormancyMonitor will never execute.
5. The PRZMA.Lexicon.Registry from the XRPC session (which tracks service-level schemas) needs entries for the activity stream verbs, calendar event types, and estate activity types — this is where the 24+ verb registry from the ActivityStream work should be registered as lexicon entries, not just as in-memory Elixir maps.​​​​​​​​​​​​​​​​