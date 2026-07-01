# lib/przma/platform/metadata_index.ex
#
# Cross-service metadata index.
# When any service creates or updates a resource, it emits a call to index/3.
# The metadata service maintains a search_index Lance table across all services.
# The companion service reads from this index for full-vault context assembly.

defmodule PRZMA.Platform.MetadataIndex do
  alias PRZMA.Calendar.NIF
  alias PRZMA.Platform.{CAS, ServicesCatalogue}
  require Logger

  @base_path Application.compile_env(:przma, [:vault, :base_path], "/var/przma/vaults")

  # ── INDEX ENTRY TYPES ────────────────────────────────────────────────────

  @doc """
  Index a resource when it is created or significantly updated.

  Called by every service after a successful write:
    Calendar: after create/update event or task
    Vault:    after create/update entry
    Chat:     after message send
    Files:    after upload complete
    Creative: after project save

  opts:
    :title   — display title for search results
    :snippet — ≤200 char preview text
    :tags    — list of string tags
    :source  — which service emitted this (defaults to :unknown)
  """
  def index(did, uri, opts \\ []) when is_binary(uri) do
    title   = opts[:title]   || ""
    snippet = opts[:snippet] || ""
    tags    = opts[:tags]    || []
    source  = opts[:source]  || :unknown

    entry = %{
      uri:        uri,
      did:        did,
      service:    ServicesCatalogue.cas_writer_id(source),
      title:      title,
      snippet:    truncate(snippet, 200),
      tags_json:  Jason.encode!(tags),
      indexed_at: System.os_time(:microsecond),
      created_at: opts[:created_at] || System.os_time(:microsecond),
    }

    # Write to search_index Lance table (async — non-blocking)
    Task.start(fn -> write_search_index_entry(did, entry) end)

    # Update cross-service reference if source URI provided
    if source_uri = opts[:source_uri] do
      Task.start(fn -> write_reference(did, source_uri, uri, "linked") end)
    end

    :ok
  end

  @doc "Remove an entry from the search index when a resource is deleted"
  def deindex(did, uri) when is_binary(uri) do
    Task.start(fn -> delete_search_index_entry(did, uri) end)
    :ok
  end

  # ── SEARCH ───────────────────────────────────────────────────────────────

  @doc """
  Full-text + semantic search across all services for a DID.
  Returns ranked results with service, title, snippet, and URI.
  """
  def search(did, query, opts \\ []) do
    limit       = opts[:limit]   || 20
    service     = opts[:service]          # nil = all services
    top_k       = opts[:top_k]   || limit

    # Phase final: DuckDB full-text search + vector search on search_index.lance
    # For now: return empty (DuckDB FTS extension wiring)
    {:ok, []}
  end

  @doc """
  List cross-service references for a resource.
  Returns all przma:// URIs that reference or are referenced by the given URI.
  """
  def references_for(did, uri) do
    # Phase final: query references.lance for source_uri = uri OR target_uri = uri
    {:ok, []}
  end

  @doc "List all tags for a DID, with resource counts"
  def list_tags(did) do
    # Phase final: query tags.lance
    {:ok, []}
  end

  # ── COMPANION CONTEXT ────────────────────────────────────────────────────

  @doc """
  Assemble cross-service context for the companion Arc Engine.
  Called by CompanionContext.assemble/2 to enrich beyond calendar.

  Returns:
    recent_across_services: last N resources created across all services
    active_projects:        creative projects in progress
    pending_files:          files awaiting review
    unseen_memories:        vault entries not yet surfaced to companion
  """
  def companion_context(did, opts \\ []) do
    since_micros = opts[:since_micros] || (
      DateTime.utc_now()
      |> DateTime.add(-7 * 86400, :second)
      |> DateTime.to_unix(:microsecond)
    )

    # Phase final: DuckDB query on search_index.lance
    {:ok, %{
      recent_across_services: [],
      active_projects:        [],
      pending_files:          [],
      unseen_memories:        [],
    }}
  end

  # ── PRIVATE ──────────────────────────────────────────────────────────────

  defp write_search_index_entry(did, entry) do
    lance_path = "#{@base_path}/#{did}/metadata/core/search_index"
    # Phase final: write entry via NIF
    :ok
  end

  defp delete_search_index_entry(did, uri) do
    lance_path = "#{@base_path}/#{did}/metadata/core/search_index"
    # Phase final: delete by uri column via NIF
    :ok
  end

  defp write_reference(did, source_uri, target_uri, rel_type) do
    lance_path = "#{@base_path}/#{did}/metadata/core/references"
    # Phase final: write reference via NIF
    :ok
  end

  defp truncate(text, max) when byte_size(text) <= max, do: text
  defp truncate(text, max), do: binary_part(text, 0, max) <> "…"
end
