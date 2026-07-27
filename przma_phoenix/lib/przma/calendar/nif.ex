# lib/przma/calendar/nif.ex
#
# Rustler NIF wrapper for the przma-calendar Rust crate.
# All functions delegate to the compiled Rust NIF.

defmodule PRZMA.Calendar.NIF do
  # NIF disabled: native crate not present in this branch. Stubs below
  # raise :nif_not_loaded if called. CAS path uses PRZMA.PzDb.NIF.

  # ── Events ────────────────────────────────────────────────────────────────

  @doc "Create a calendar event. Returns {:ok, id} | {:error, reason}"
  def create_event(_base_path, _did, _event_json),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc "Get a single event by id and space"
  def get_event(_base_path, _did, _event_id, _space),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc "List events with optional filters (query_json)"
  def list_events(_base_path, _did, _query_json),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc "Update an existing event"
  def update_event(_base_path, _did, _event_json),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc "Cancel an event (sets status = cancelled)"
  def cancel_event(_base_path, _did, _event_id, _space),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc "Semantic vector search over events"
  def semantic_search_events(_base_path, _did, _space, _embedding_json, _top_k),
    do: :erlang.nif_error(:nif_not_loaded)

  # ── Tasks ─────────────────────────────────────────────────────────────────

  @doc "Create a calendar task"
  def create_task(_base_path, _did, _task_json),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc "Mark a task as complete"
  def complete_task(_base_path, _did, _task_id, _space, _completed_by),
    do: :erlang.nif_error(:nif_not_loaded)

  # ── CAS ───────────────────────────────────────────────────────────────────

  @doc "Store bytes in CAS. Returns {:ok, blake3_hash}"
  def cas_put(_base_path, _did, _data),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc "Retrieve bytes from CAS by hash"
  def cas_get(_base_path, _did, _hash),
    do: :erlang.nif_error(:nif_not_loaded)

  # ── Recurrence ────────────────────────────────────────────────────────────

  @doc "Expand an rrule string into concrete UTC microsecond timestamps"
  def expand_rrule(_rrule_str, _dtstart_micros, _tz, _range_start, _range_end, _max),
    do: :erlang.nif_error(:nif_not_loaded)

  # ── Analytics ─────────────────────────────────────────────────────────────

  @doc "Run a named analytics query via DuckDB on Lance files"
  def calendar_analytics(_base_path, _did, _query_type, _params_json),
    do: :erlang.nif_error(:nif_not_loaded)
end

defmodule PRZMA.Calendar.NIF.Phase6 do
  @moduledoc """
  Phase 6 NIF stubs — merged into PRZMA.Calendar.NIF on next refactor.
  Listed here to document the full Phase 6 NIF surface.
  Call via PRZMA.Calendar.NIF after compile with all NIFs registered.
  """
  # embed_text/2, embed_event/4, embed_and_update_event/4,
  # rank_events_by_similarity/3, time_distribution/4,
  # practice_adherence/5, meeting_patterns/4, generate_insights/4
  # All registered in przma-nif/src/lib.rs rustler::init! block.
end

