defmodule Przma.Storage.DocWriter do
  @moduledoc """
  One writer process per user (DID). Every doc-store WRITE for that user
  runs inside it, one at a time:

      request -> LanceDocAdapter -> DocWriter.run(did, fun) -> fun.() -> NIF -> S3

  WHY: Lance on S3 (Linode) has no safe way for two processes to commit to
  the same table at the same moment, and CouchDB's `_rev` conflict check is
  gone. Running a user's writes one after another inside one process makes
  read-modify-write ("$inc", "$add_to_set", merge of fields) safe, and the
  compactor uses the same process, so it never overlaps a write.

  Reads do NOT go through here — they read the latest committed version
  straight from S3.

  Processes are started on demand (DynamicSupervisor + Registry, both
  started in Przma.Application) and stop themselves after `idle_stop_ms`
  without work.

  LIMITS (see the guide):
    * single node only — with several Phoenix nodes, a DID's writes must be
      routed to one node (or a distributed registry such as :global/Horde).
    * a function passed to run/2 must NOT call run/2 for the same DID
      (it would wait for itself until the timeout).
    * when the caller times out, the write may still finish afterwards.
  """

  use GenServer, restart: :transient
  require Logger

  @registry Przma.Storage.DocWriterRegistry
  @supervisor Przma.Storage.DocWriterSupervisor

  # ── public API ───────────────────────────────────────────────────────

  @doc "Runs `fun` inside the DID's writer and returns its result."
  @spec run(String.t(), (-> term())) :: term()
  def run(did, fun) when is_binary(did) and is_function(fun, 0), do: run(did, fun, 1, cfg(:writer_timeout_ms, 30_000))

  @doc """
  Same as run/2 with its own timeout, for long jobs that must still be
  serialised per user (vector index builds, big batches of vectors).
  """
  @spec run_with_timeout(String.t(), (-> term()), pos_integer()) :: term()
  def run_with_timeout(did, fun, timeout_ms)
      when is_binary(did) and is_function(fun, 0) and is_integer(timeout_ms) and timeout_ms > 0,
      do: run(did, fun, 1, timeout_ms)

  @doc "Number of writes waiting for this DID (0 when no writer is running). For load tests."
  @spec queue_length(String.t()) :: non_neg_integer()
  def queue_length(did) do
    case Registry.lookup(@registry, did) do
      [{pid, _}] ->
        case Process.info(pid, :message_queue_len) do
          {:message_queue_len, n} -> n
          nil -> 0
        end

      [] ->
        0
    end
  end

  @doc "How many writer processes are running right now. For load tests."
  @spec count() :: non_neg_integer()
  def count, do: Registry.count(@registry)

  def start_link(did), do: GenServer.start_link(__MODULE__, did, name: via(did))

  # ── internal ─────────────────────────────────────────────────────────

  defp run(did, fun, attempt, timeout_ms) do
    with {:ok, pid} <- ensure_started(did) do
      try do
        GenServer.call(pid, {:run, fun}, timeout_ms)
      catch
        :exit, {:timeout, _} ->
          Logger.error("DocWriter timeout for #{did} (queue: #{queue_length(did)})")
          {:error, :doc_writer_timeout}

        # The writer stopped for being idle between lookup and call: start a new one.
        :exit, {reason, _} when reason in [:noproc, :normal, :shutdown] and attempt < 3 ->
          run(did, fun, attempt + 1, timeout_ms)

        :exit, {reason, _} ->
          {:error, {:doc_writer_exit, reason}}
      end
    end
  end

  defp ensure_started(did) do
    case Registry.lookup(@registry, did) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        case DynamicSupervisor.start_child(@supervisor, {__MODULE__, did}) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, reason} -> {:error, {:doc_writer_start_failed, reason}}
        end
    end
  end

  defp via(did), do: {:via, Registry, {@registry, did}}

  @impl true
  def init(did), do: {:ok, did, idle_ms()}

  @impl true
  def handle_call({:run, fun}, _from, did) do
    {:reply, safe(did, fun), did, idle_ms()}
  end

  @impl true
  def handle_info(:timeout, did), do: {:stop, :normal, did}
  def handle_info(_msg, did), do: {:noreply, did, idle_ms()}

  # A failing write must not kill the writer (other callers are queued).
  defp safe(did, fun) do
    fun.()
  rescue
    e ->
      Logger.error("DocWriter #{did}: " <> Exception.format(:error, e, __STACKTRACE__))
      {:error, {:doc_writer_exception, Exception.message(e)}}
  catch
    kind, reason ->
      Logger.error("DocWriter #{did}: #{inspect(kind)} #{inspect(reason)}")
      {:error, {kind, reason}}
  end

  defp idle_ms, do: cfg(:writer_idle_stop_ms, 300_000)

  defp cfg(key, default), do: Keyword.get(Application.get_env(:przma, :lance_doc, []), key, default)
end
