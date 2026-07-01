# lib/przma/platform/services_catalogue.ex
#
# PRZMA Platform Services Catalogue
#
# This module is the canonical reference for:
#   - Service names, namespaces, and Lance paths
#   - Cross-service data flow rules
#   - CAS reference conventions
#   - Service capability flags per deployment mode
#
# Nine services. One CAS. One namespace scheme. Zero Postgres.
#
#   przma://{did}/{service}/{space}/{type}/{id}
#
#   Service     │ Namespace   │ Offline? │ Social?  │ Federation
#   ────────────┼─────────────┼──────────┼──────────┼────────────
#   Vault       │ vault/      │ ✓        │ –        │ –
#   Calendar    │ calendar/   │ ✓        │ ✓        │ CalDAV + ActivityPub
#   Chat        │ chat/       │ partial  │ ✓        │ ActivityPub + Gun.js
#   Files       │ files/      │ ✓        │ ✓        │ CAS export
#   Metadata    │ metadata/   │ ✓        │ –        │ –
#   AI          │ ai/         │ ✓ (local)│ –        │ –
#   Agents      │ agents/     │ partial  │ ✓        │ –
#   Creative    │ creative/   │ ✓        │ ✓        │ ActivityPub
#   Companion   │ companion/  │ ✓        │ –        │ –

defmodule PRZMA.Platform.ServicesCatalogue do
  @moduledoc """
  Authoritative catalogue of all PRZMA platform services.
  Import this module anywhere you need service metadata.
  """

  # ── SERVICE REGISTRY ──────────────────────────────────────────────────────

  @services %{
    vault: %{
      name:          "Vault",
      namespace:     "vault",
      description:   "Sovereign personal journal — 8 domains mapped to PRZMA's 7 Filters and 2 Lenses",
      offline:       true,
      social:        false,
      federation:    nil,
      tables:        ~w(entries practice_logs),
      domains: ~w(my_health my_day my_people my_thoughts who_i_am what_i_learned quiet_moments my_practices),
    },

    calendar: %{
      name:          "Calendar",
      namespace:     "calendar",
      description:   "Sovereign calendar with circle governance, meeting intelligence, and federation",
      offline:       true,
      social:        true,
      federation:    [:caldav, :activitypub, :ical],
      tables:        ~w(events tasks availability booking_links reminders polls transcripts),
    },

    chat: %{
      name:          "Chat",
      namespace:     "chat",
      description:   "Messaging — DMs (Core), group (Circle), public threads (Commons). Gun.js P2P + ActivityPub",
      offline:       :partial,   # read works offline; delivery needs connectivity
      social:        true,
      federation:    [:activitypub, :gun_js],
      tables:        ~w(messages threads),
    },

    files: %{
      name:          "Files",
      namespace:     "files",
      description:   "Versioned file management with chunked parallel upload. All blobs in CAS.",
      offline:       true,
      social:        true,
      federation:    [:cas_export],
      tables:        ~w(files upload_sessions),
    },

    metadata: %{
      name:          "Metadata",
      namespace:     "metadata",
      description:   "Cross-service reference graph, tags, and global search index. Read-only for other services.",
      offline:       true,
      social:        false,
      federation:    nil,
      tables:        ~w(references tags search_index),
    },

    ai: %{
      name:          "AI",
      namespace:     "ai",
      description:   "Local model registry and inference tracking. TFLite on-device, Axon/EXLA for server.",
      offline:       :local,   # on-device inference offline; cloud models need connectivity
      social:        false,
      federation:    nil,
      tables:        ~w(model_registry inference_log),
    },

    agents: %{
      name:          "Agents",
      namespace:     "agents",
      description:   "Agent session orchestration — OpenClaw-inspired OTP agents with Oban heartbeats.",
      offline:       :partial,
      social:        true,
      federation:    nil,
      tables:        ~w(sessions execution_log),
    },

    creative: %{
      name:          "Creative",
      namespace:     "creative",
      description:   "PRZMA Studio — sovereign creative workspace for writing, audio, visual, and mixed media.",
      offline:       true,
      social:        true,
      federation:    [:activitypub],
      tables:        ~w(projects assets),
    },

    companion: %{
      name:          "Companion",
      namespace:     "companion",
      description:   "Arc Engine — perception intelligence layer. Reads all services. Stores memories, Sapience Index, HOLNN state.",
      offline:       true,
      social:        false,
      federation:    nil,
      tables:        ~w(memories sapience_snapshots arc_timeline),
    },
  }

  # ── PUBLIC API ───────────────────────────────────────────────────────────

  def all,         do: @services
  def service(id), do: Map.get(@services, id)
  def names,       do: Map.keys(@services)

  def namespace(service_id) do
    get_in(@services, [service_id, :namespace])
  end

  def offline?(service_id) do
    get_in(@services, [service_id, :offline]) == true
  end

  def social?(service_id) do
    get_in(@services, [service_id, :social]) == true
  end

  def tables_for(service_id) do
    get_in(@services, [service_id, :tables]) || []
  end

  @doc "Build the Lance table path for a specific service and table"
  def lance_path(base_path, did, service_id, space, table) do
    ns = namespace(service_id)
    "#{base_path}/#{did}/#{ns}/#{space}/#{table}"
  end

  @doc "Build a PRZMA URI for a resource"
  def uri(did, service_id, space, res_type, id) do
    ns = namespace(service_id)
    space_str = space_to_string(space)
    "przma://#{did}/#{ns}/#{space_str}/#{res_type}/#{id}"
  end

  # ── CAS CONVENTIONS ──────────────────────────────────────────────────────

  @doc """
  The CAS root path for a DID's vault.
  All services share this single CAS store.
  """
  def cas_root(base_path, did) do
    "#{base_path}/#{did}/cas"
  end

  @doc """
  Build a CAS URI string from a BLAKE3 hash.
  Use this everywhere a CAS reference is stored in a Lance record.
  """
  def cas_uri(hash), do: "cas:#{hash}"

  @doc "Extract the hash from a CAS URI"
  def cas_hash("cas:" <> hash), do: hash
  def cas_hash(hash), do: hash

  # ── CROSS-SERVICE DATA FLOW ───────────────────────────────────────────────

  @doc """
  Rules for how data flows between services.
  Services NEVER copy data — they reference by CAS URI or przma:// URI.

  Permitted flows:
    Calendar → Vault:     post-meeting reflections route to vault domains
    Calendar → Metadata:  event created/updated → search index updated
    Calendar → Companion: context push after every significant event change
    Chat → Vault:         saved messages route to vault (My People domain)
    Chat → Metadata:      thread and message indexed for search
    Files → Metadata:     file uploaded → search index entry created
    Vault → Companion:    vault entries are primary companion memory source
    Metadata → Companion: cross-service context assembly for Arc Engine
    AI → Agents:          model inference results returned to agent sessions
    Creative → Metadata:  published projects indexed
    Creative → Calendar:  project deadlines → calendar events
    * → Metadata:         any resource creation should emit an index event
  """
  def permitted_flow?(source, target) do
    allowed = %{
      calendar:  [:vault, :metadata, :companion],
      chat:      [:vault, :metadata],
      files:     [:metadata],
      vault:     [:companion],
      metadata:  [:companion],
      ai:        [:agents],
      creative:  [:metadata, :calendar],
      agents:    [:vault, :files, :metadata],
      companion: [],  # companion is read-only output — never writes to other services
    }
    Map.get(allowed, source, []) |> Enum.member?(target)
  end

  @doc """
  The CAS written_by identifier for each service.
  Used to track blob provenance in CAS metadata.
  """
  def cas_writer_id(service_id) do
    namespace(service_id) || "unknown"
  end

  # ── DEPLOYMENT MODE AVAILABILITY ─────────────────────────────────────────

  @doc """
  Which services are available in each deployment mode.
  All services are available in all modes, but with different backends.
  """
  def available_in_mode?(service_id, mode) do
    case {service_id, mode} do
      # AI inference is available locally in all modes; remote APIs only in cloud
      {:ai, :local}       -> :local_only
      {:ai, :own_domain}  -> :local_only
      {:ai, :cloud_saas}  -> :full
      {:ai, :byos}        -> :full

      # Agents work in all modes but may have reduced tool access offline
      {:agents, :local}   -> :limited
      {:agents, _}        -> :full

      # Chat needs Gun.js relay for Circle tier offline; DMs work fully offline
      {:chat, :local}     -> :limited  # DMs work; group requires relay
      {:chat, _}          -> :full

      # Everything else: full in all modes
      {_, _} -> :full
    end
  end

  # ── PRIVATE ──────────────────────────────────────────────────────────────

  defp space_to_string(:core),              do: "core"
  defp space_to_string(:commons),           do: "commons"
  defp space_to_string({:circle, did}),     do: "circle:#{did}"
  defp space_to_string("core"),             do: "core"
  defp space_to_string("commons"),          do: "commons"
  defp space_to_string("circle:" <> _ = s), do: s
  defp space_to_string(other),              do: to_string(other)
end
