# lib/przma/services/service_stubs.ex
#
# Interface contracts for all non-calendar PRZMA services.
# Each module defines:
#   - Its public API (what other services call)
#   - Its CAS write pattern
#   - Its Metadata index emissions
#   - Its cross-service dependencies
#
# Implementation depth mirrors calendar service phases.
# Calendar is the reference implementation — all others follow the same pattern.

# ═══════════════════════════════════════════════════════════════════════════════
# VAULT SERVICE
# ═══════════════════════════════════════════════════════════════════════════════

defmodule PRZMA.Services.Vault do
  @moduledoc """
  Sovereign personal journal — 8 domains, full-text + semantic search.

  Lance tables: vault/{space}/entries, vault/{space}/practice_logs

  CAS pattern:
    body_cas     — UTF-8 journal text (encrypted)
    richtext_cas — rendered/formatted version (encrypted)

  Emits to Metadata: every entry create/update
  Emits to Companion: entries with high salience score

  Calendar → Vault: post-meeting reflections routed by event category:
    MEETING     → my_people
    PRACTICE    → my_practices
    STUDY       → what_i_learned
    APPOINTMENT → my_health
    ACTIVITY    → my_day
  """

  alias PRZMA.Platform.{CAS, MetadataIndex, ServicesCatalogue}

  @base_path Application.compile_env(:przma, [:vault, :base_path], "/var/przma/vaults")

  def create(did, domain, attrs) do
    with {:ok, body_cas} <- CAS.put_text(did, attrs["body"] || "", written_by: "vault") do
      entry = attrs
        |> Map.put("body_cas",   body_cas)
        |> Map.put("domain",     domain)
        |> Map.put("did",        did)
        |> Map.put("id",         generate_id())
        |> Map.put("created_at", now_micros())
        |> Map.put("updated_at", now_micros())
        |> Map.put("version",    1)

      # Write to Lance
      # NIF.vault_create_entry(@base_path, did, Jason.encode!(entry))

      # Emit to metadata index
      MetadataIndex.index(did, uri(did, entry["id"]), [
        title:   entry["title"] || "Vault Entry",
        snippet: String.slice(attrs["body"] || "", 0, 200),
        source:  :vault,
      ])

      {:ok, entry}
    end
  end

  def create_from_calendar(did, event, reflection_text, domain) do
    create(did, domain, %{
      "title"       => "Reflection: #{event["title"]}",
      "body"        => reflection_text,
      "entry_type"  => "reflection",
      "source_uri"  => "przma://#{did}/calendar/core/event/#{event["id"]}",
      "source_type" => "calendar_event",
    })
  end

  defp uri(did, id), do: "przma://#{did}/vault/core/entry/#{id}"
  defp generate_id, do: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  defp now_micros,  do: System.os_time(:microsecond)
end

# ═══════════════════════════════════════════════════════════════════════════════
# CHAT SERVICE
# ═══════════════════════════════════════════════════════════════════════════════

defmodule PRZMA.Services.Chat do
  @moduledoc """
  Messaging — DMs (Core), group chat (Circle), public threads (Commons).

  Lance tables: chat/{space}/messages, chat/{space}/threads

  Three-tier delivery:
    Core (DMs):    direct Phoenix channel + CAS blob for body
    Circle:        Gun.js P2P with BLAKE3 content verification + relay fallback
    Commons:       ActivityPub Create Note + relay inbox buffer

  CAS pattern:
    body_cas — message text (encrypted for Core/Circle, plaintext for Commons)

  Emits to Metadata: every thread create, message in searchable threads

  Companion channel: companion thread type — messages go to companion memory
  """

  alias PRZMA.Platform.{CAS, MetadataIndex}

  def send_message(did, thread_id, text, opts \\ []) do
    space      = opts[:space] || "core"
    circle_did = opts[:circle_did]

    with {:ok, body_cas} <- CAS.put_text(did, text, written_by: "chat") do
      message = %{
        "id"          => generate_id(),
        "did"         => did,
        "space"       => space_string(space, circle_did),
        "thread_id"   => thread_id,
        "body_cas"    => body_cas,
        "body_mime"   => "text/plain",
        "attachments_json" => "[]",
        "reactions_json"   => "{}",
        "mentions_json"    => "[]",
        "created_at"  => System.os_time(:microsecond),
      }

      # Write to Lance, deliver via Gun.js or ActivityPub
      # route_delivery(message, space, circle_did)

      {:ok, message}
    end
  end

  defp space_string(:core, _), do: "core"
  defp space_string(:commons, _), do: "commons"
  defp space_string(:circle, did), do: "circle:#{did}"
  defp space_string(s, _) when is_binary(s), do: s
  defp generate_id, do: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
end

# ═══════════════════════════════════════════════════════════════════════════════
# FILES SERVICE
# ═══════════════════════════════════════════════════════════════════════════════

defmodule PRZMA.Services.Files do
  @moduledoc """
  Versioned file management with chunked parallel upload.

  Lance tables: files/{space}/files, files/{space}/upload_sessions

  Upload flow:
    1. POST /api/v1/files/upload/start    → returns session_id + chunk_size
    2. PUT  /api/v1/files/upload/{session_id}/chunk/{n}  → CAS put per chunk
    3. POST /api/v1/files/upload/{session_id}/complete   → assemble + write Lance

  CAS pattern:
    Each chunk → CAS URI (content_cas_{n})
    Assembled file → single content_cas URI stored in files.lance
    Thumbnail → thumbnail_cas URI (generated for image/video/pdf)

  Emits to Metadata: on upload complete, on file delete
  """

  alias PRZMA.Platform.{CAS, MetadataIndex}

  def start_upload(did, filename, mime_type, total_bytes, opts \\ []) do
    chunk_size = opts[:chunk_size] || 5 * 1024 * 1024  # 5 MB default
    total_chunks = ceil(total_bytes / chunk_size)

    session = %{
      "session_id"      => generate_id(),
      "did"             => did,
      "file_name"       => filename,
      "mime_type"       => mime_type,
      "total_bytes"     => total_bytes,
      "chunk_size"      => chunk_size,
      "total_chunks"    => total_chunks,
      "received_chunks_json" => "[]",
      "chunk_hashes_json"    => "[]",
      "status"          => "active",
      "expires_at"      => System.os_time(:microsecond) + 24 * 3600 * 1_000_000,
      "created_at"      => System.os_time(:microsecond),
    }
    {:ok, session}
  end

  def upload_chunk(did, session_id, chunk_index, chunk_data) do
    with {:ok, cas_uri} <- CAS.put(did, chunk_data, written_by: "files") do
      # Update session: mark chunk received, store CAS URI
      {:ok, %{chunk_index: chunk_index, cas_uri: cas_uri}}
    end
  end

  def complete_upload(did, session_id, opts \\ []) do
    # Retrieve all chunks from CAS, concatenate, write assembled file
    # Write to files.lance with final CAS URI
    {:ok, %{file_id: generate_id(), status: :complete}}
  end

  defp generate_id, do: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
end

# ═══════════════════════════════════════════════════════════════════════════════
# AI SERVICE
# ═══════════════════════════════════════════════════════════════════════════════

defmodule PRZMA.Services.AI do
  @moduledoc """
  Local model registry and inference management.

  Lance tables: ai/core/model_registry, ai/core/inference_log

  Model locations (per deployment mode):
    Local/OwnDomain: {vault}/{did}/models/{model_name}.tflite
    Cloud SaaS:      TF Serving endpoint
    BYOS:            TFLite on client, S3 for model storage

  Registered models:
    przma_embedder_v1     — 768-dim sentence embeddings (calendar + vault + chat)
    przma_classifier_v1   — HOLNN 7-filter classification (446 input, 49 output)
    przma_asr_v1          — Whisper-based ASR (meeting transcription)
    przma_sapience_v1     — Sapience Index predictor (perception intelligence)

  Produces: embedding vectors, classification scores, transcripts, Sapience Index
  Consumed by: Calendar (embeddings), Companion (HOLNN, Sapience), Chat (ASR)
  """

  def register_model(did, model_attrs) do
    model = Map.merge(model_attrs, %{
      "id"               => generate_id(),
      "did"              => did,
      "is_active"        => true,
      "adapter_version"  => 0,
      "created_at"       => System.os_time(:microsecond),
    })
    # NIF.ai_register_model(@base_path, did, Jason.encode!(model))
    {:ok, model}
  end

  def infer(did, model_id, input, call_type) do
    started_at = System.monotonic_time(:millisecond)
    # Route to TFLite NIF or TF Serving based on deployment mode
    result = dispatch_inference(did, model_id, input, call_type)
    latency_ms = System.monotonic_time(:millisecond) - started_at

    log_inference(did, model_id, call_type, latency_ms)
    result
  end

  defp dispatch_inference(did, model_id, input, call_type) do
    # Phase final: real TFLite NIF dispatch
    {:ok, %{output: [], model_id: model_id, latency_ms: 0}}
  end

  defp log_inference(did, model_id, call_type, latency_ms) do
    # Write to inference_log.lance (async)
    :ok
  end

  defp generate_id, do: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
end

# ═══════════════════════════════════════════════════════════════════════════════
# AGENTS SERVICE
# ═══════════════════════════════════════════════════════════════════════════════

defmodule PRZMA.Services.Agents do
  @moduledoc """
  Agent session orchestration — OpenClaw-inspired OTP architecture.

  Process hierarchy per agent invocation:
    AgentGateway (GenServer)     — entry point, auth, tool grants
      └── AgentSession (GenServer) — holds session state, context
            └── AgentLoop (Task)     — step executor (may be recursive)
                  └── DNA PromptBuilder — composes 6-layer prompt
    Oban Heartbeat Worker        — keeps session alive, records to Lance

  Lance tables: agents/{space}/sessions, agents/{space}/execution_log

  Tool grants model (scoped, time-limited):
    calendar:read  — can read user's calendar events
    vault:write    — can write to vault (e.g. scribe agent)
    files:write    — can upload files (e.g. export agent)
    chat:send      — can send messages (e.g. notification agent)
    metadata:read  — can query search index
    ai:infer       — can call AI models

  Agents available by tier:
    free_local:    companion only (no user-facing agents)
    essential:     companion + 1 additional agent
    professional:  companion + 5 agents
    sovereign:     companion + unlimited agents
  """

  def start_session(did, agent_type, context_uri, opts \\ []) do
    space      = opts[:space] || "core"
    circle_did = opts[:circle_did]

    session = %{
      "id"               => generate_id(),
      "did"              => did,
      "agent_type"       => agent_type,
      "agent_version"    => "1.0.0",
      "space"            => space,
      "circle_did"       => circle_did,
      "status"           => "active",
      "tool_grants_json" => Jason.encode!(opts[:tool_grants] || []),
      "context_uri"      => context_uri,
      "heartbeat_at"     => System.os_time(:microsecond),
      "started_at"       => System.os_time(:microsecond),
      "output_uris_json" => "[]",
    }

    # Write to sessions.lance
    # Start Oban heartbeat
    # Spawn AgentSession GenServer

    {:ok, session}
  end

  def complete_session(did, session_id, output_uris) do
    # Update sessions.lance: status=completed, ended_at, output_uris_json
    {:ok, %{session_id: session_id, outputs: output_uris}}
  end

  defp generate_id, do: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
end

# ═══════════════════════════════════════════════════════════════════════════════
# CREATIVE SERVICE (PRZMA Studio)
# ═══════════════════════════════════════════════════════════════════════════════

defmodule PRZMA.Services.Creative do
  @moduledoc """
  PRZMA Studio — sovereign creative workspace.

  Not a SaaS analytics dashboard — it's the user's creative vault.
  Projects contain assets; assets are CAS blobs.
  Published projects flow to ActivityPub Commons.

  Lance tables: creative/{space}/projects, creative/{space}/assets

  Project types:
    writing  — long-form text, books, essays
    audio    — music, podcast, ambient
    visual   — images, illustrations, design
    video    — video production timelines
    mixed    — multi-media projects

  CAS pattern:
    Each asset → content_cas URI
    Project timeline → timeline_cas URI (JSON edit sequence)

  Calendar integration:
    create_deadline_event(project) → Calendar.Events.create/2
    projects near deadline surface in companion morning briefing

  Emits to Metadata: on project publish, on asset add
  Emits to Calendar: project milestone events
  Publishes to Commons: via ActivityPub Create Note with media attachments
  """

  alias PRZMA.Platform.{CAS, MetadataIndex}

  def create_project(did, attrs, opts \\ []) do
    space = opts[:space] || "core"

    project = attrs
      |> Map.put("id",         generate_id())
      |> Map.put("did",        did)
      |> Map.put("space",      space)
      |> Map.put("status",     "draft")
      |> Map.put("assets_json",        "[]")
      |> Map.put("collaborators_json", "[]")
      |> Map.put("tags_json",          "[]")
      |> Map.put("created_at", System.os_time(:microsecond))
      |> Map.put("updated_at", System.os_time(:microsecond))
      |> Map.put("version",    1)

    MetadataIndex.index(did, uri(did, project["id"]), [
      title:   project["title"] || "Creative Project",
      snippet: project["description"] || "",
      source:  :creative,
    ])

    {:ok, project}
  end

  def add_asset(did, project_id, asset_data, mime_type, name) do
    with {:ok, content_cas} <- CAS.put(did, asset_data,
                                  mime_type: mime_type, written_by: "creative") do
      asset = %{
        "id"          => generate_id(),
        "did"         => did,
        "project_id"  => project_id,
        "name"        => name,
        "content_cas" => content_cas,
        "mime_type"   => mime_type,
        "size_bytes"  => byte_size(asset_data),
        "created_at"  => System.os_time(:microsecond),
      }
      {:ok, asset}
    end
  end

  def publish(did, project_id) do
    # Retrieve project, build ActivityPub Create activity with media attachments
    # POST to AP outbox
    {:ok, %{ap_id: "https://#{did_domain(did)}/ap/projects/#{project_id}"}}
  end

  def create_deadline_event(did, project) do
    if project["deadline_at"] do
      PRZMA.Calendar.Events.create(did, %{
        "title"     => "Deadline: #{project["title"]}",
        "category"  => "MILESTONE",
        "start_at"  => project["deadline_at"],
        "end_at"    => project["deadline_at"] + 3_600_000_000,
        "space"     => "core",
        "source_uri"=> uri(did, project["id"]),
      })
    else
      {:ok, nil}
    end
  end

  defp uri(did, id), do: "przma://#{did}/creative/core/project/#{id}"
  defp did_domain(did), do: did |> String.split(":") |> List.last()
  defp generate_id, do: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
end

# ═══════════════════════════════════════════════════════════════════════════════
# COMPANION SERVICE (Arc Engine)
# ═══════════════════════════════════════════════════════════════════════════════

defmodule PRZMA.Services.Companion do
  @moduledoc """
  Arc Engine — perception intelligence layer.

  The companion reads from ALL services via the metadata index.
  It writes only to companion/{space}/memories and companion/core/sapience_snapshots.
  It NEVER writes to other service namespaces.

  Lance tables:
    companion/core/memories
    companion/core/sapience_snapshots
    companion/core/arc_timeline

  Memory formation rules:
    - High-salience vault entries → episodic memory
    - Recurring calendar patterns → procedural memory
    - Chat threads with mentions → semantic memory
    - Practice completions → procedural memory

  Sapience Index: S = 40Λ + 30(1-Γ) + 15Φ₄ + 15P
    Λ  — coherence score (from HeartMath HRV patterns, if sensor available)
    Γ  — distortion index (from HOLNN classification of recent vault entries)
    Φ₄ — Heart Filter clarity (from Heart Filter HOLNN output)
    P  — practice adherence (from calendar practice_adherence DuckDB query)

  Filter states: CLEAR / FOGGED (never open/close — see PRZMA terminology rules)
    Body, Senses, Mind, Heart (Gateway), Ego, Knowledge, Detachment

  The companion surfaces memories, patterns, and insights proactively.
  It responds to: vault writes, calendar changes, chat messages, practice completions.

  Expiry: insight-type memories expire after 3 sessions if not recalled.
          Episodic memories are permanent.
  """

  alias PRZMA.Platform.{CAS, MetadataIndex}

  # ── MEMORY FORMATION ─────────────────────────────────────────────────────

  def form_memory(did, attrs) do
    with {:ok, body_cas} <- CAS.put_text(did, attrs["body"] || "", written_by: "companion") do
      memory = attrs
        |> Map.put("id",           generate_id())
        |> Map.put("did",          did)
        |> Map.put("body_cas",     body_cas)
        |> Map.put("recalled_count", 0)
        |> Map.put("created_at",   System.os_time(:microsecond))
        |> Map.put("updated_at",   System.os_time(:microsecond))

      # NIF.companion_create_memory(@base_path, did, Jason.encode!(memory))
      {:ok, memory}
    end
  end

  # ── SAPIENCE INDEX ────────────────────────────────────────────────────────

  def compute_sapience(did, opts \\ []) do
    # Gather inputs from other services
    practice_adherence = opts[:practice_adherence] || 0.0
    phi4               = opts[:heart_filter_clarity] || 0.5
    gamma              = opts[:distortion_index] || 0.3
    lambda             = opts[:coherence] || 0.5

    # S = 40Λ + 30(1-Γ) + 15Φ₄ + 15P
    s = 40 * lambda + 30 * (1 - gamma) + 15 * phi4 + 15 * practice_adherence

    snapshot = %{
      "id"             => generate_id(),
      "did"            => did,
      "lambda"         => lambda,
      "gamma"          => gamma,
      "phi4"           => phi4,
      "practice_score" => practice_adherence,
      "sapience_index" => s,
      "filter_states_json" => Jason.encode!(default_filter_states()),
      "pb_accumulator" => opts[:pb] || 0.0,
      "cri_modulation" => opts[:cri] || 1.0,
      "sas_score"      => opts[:sas] || 0.0,
      "snapshot_at"    => System.os_time(:microsecond),
      "period_days"    => opts[:period_days] || 30,
    }

    # NIF.companion_save_sapience_snapshot(@base_path, did, Jason.encode!(snapshot))
    {:ok, snapshot}
  end

  # ── ARC TIMELINE ─────────────────────────────────────────────────────────

  @doc "Surface a resource to the Arc timeline — called when companion proactively surfaces an item"
  def surface(did, resource_uri, reason, filter, relevance) do
    entry = %{
      "id"           => generate_id(),
      "did"          => did,
      "resource_uri" => resource_uri,
      "surface_type" => "proactive",
      "reason"       => reason,
      "filter"       => filter,
      "relevance"    => relevance,
      "surfaced_at"  => System.os_time(:microsecond),
      "acted_on"     => false,
    }
    # NIF.companion_record_arc_event(@base_path, did, Jason.encode!(entry))
    {:ok, entry}
  end

  # ── FILTER STATES ─────────────────────────────────────────────────────────

  @doc "Get the current CLEAR/FOGGED state of all 7 filters for a DID"
  def filter_states(did) do
    # Phase final: read from latest sapience snapshot
    {:ok, default_filter_states()}
  end

  defp default_filter_states do
    %{
      body:        "FOGGED",
      senses:      "FOGGED",
      mind:        "FOGGED",
      heart:       "FOGGED",     # Heart is the Gateway filter
      ego:         "FOGGED",
      knowledge:   "FOGGED",
      detachment:  "FOGGED",
    }
  end

  defp generate_id, do: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
end
