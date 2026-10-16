defmodule Przma.Search do
  @moduledoc """
  Meaning-based ("vector") and keyword search over a user's own content.

  Every user has their own search table per space, next to their other
  Lance tables in S3:

      pzdb://did:przma:ravi/search/private/chunks
        -> s3://perkeep/did_przma_ravi/search/private/chunks.lance

  A row is one piece of text (see Przma.Search.Chunker) plus its vector.
  Vectors are made by the embedding model inside the Rust NIF
  (PRZMA_EMBED_MODEL, default minishlab/potion-base-8M).

  ## Saving (indexing)

      Search.index_text("did:przma:ravi", %{type: "file", id: "f_9k2m", title: "Ooty trip plan.pdf"}, text)
      Search.index_file("did:przma:ravi", %{type: "file", id: "f_9k2m", title: "Ooty trip plan.pdf"}, "/tmp/ooty.pdf")

  Re-indexing the same source replaces its old pieces (opts `replace: false`
  skips that, e.g. for brand-new chat messages).

  ## Searching

      Search.search("did:przma:ravi", "where did we stay in the hill station?")
      Search.search(did, "biryani", mode: :keyword)
      Search.search(did, "biryani recipe", mode: :hybrid, limit: 5, source_type: "file")

  Modes: :vector (meaning, default), :keyword (words in the text),
  :hybrid (both, merged by rank).

  ## Privacy

  Every function takes the OWNER's did and only ever opens that user's own
  table, so one user can never get another user's pieces. Callers must pass
  the did from the verified login (conn.assigns.did), never from params.

  ## Writes

  Writes (index, delete, build_index) go through Przma.Storage.DocWriter,
  one writer per user, like every other Lance table.
  """

  require Logger

  alias PRZMA.PzDb
  alias Przma.Search.{Chunker, TextExtract}
  alias Przma.Storage.{DocWriter, LanceCompactor}

  @spaces ~w(private personal public)
  @batch_rows 500
  @write_timeout_ms 120_000
  @index_timeout_ms 900_000

  @type source :: %{required(:type) => String.t(), required(:id) => String.t(), optional(:title) => String.t()}

  # ── where ───────────────────────────────────────────────────────────

  @doc "pzdb table URI of a user's search table."
  @spec table_uri(String.t(), String.t()) :: String.t()
  def table_uri(did, space \\ "private") when space in @spaces, do: "pzdb://#{did}/search/#{space}/chunks"

  # ── saving ──────────────────────────────────────────────────────────

  @doc """
  Splits `text` into pieces, embeds them and saves them in the owner's table.

  Opts: :space ("private"), :replace (true), :size / :overlap (Chunker).
  Returns {:ok, %{source_id, chunks, embed_ms, write_ms}}.
  """
  @spec index_text(String.t(), source(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def index_text(did, %{type: type, id: id} = source, text, opts \\ []) when is_binary(did) and is_binary(text) do
    space = Keyword.get(opts, :space, "private")
    uri = table_uri(did, space)
    now = System.os_time(:microsecond)

    rows =
      text
      |> Chunker.split(opts)
      |> Enum.with_index()
      |> Enum.map(fn {piece, i} ->
        %{
          id: "#{type}:#{id}##{i}",
          did: did,
          space: space,
          source_type: type,
          source_id: id,
          title: Map.get(source, :title),
          chunk_index: i,
          text: piece,
          created_at: now
        }
      end)

    with :ok <- maybe_replace(did, id, space, Keyword.get(opts, :replace, true)),
         {:ok, totals} <- write_batches(did, uri, rows) do
      {:ok, Map.merge(%{source_id: id, chunks: length(rows)}, totals)}
    end
  end

  @doc "Extracts text from a file on disk (txt/md/csv/pdf …) and indexes it."
  @spec index_file(String.t(), source(), Path.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def index_file(did, source, path, opts \\ []) do
    t0 = now_ms()

    with {:ok, text} <- TextExtract.from_file(path, Keyword.get(opts, :mime)),
         extract_ms = now_ms() - t0,
         {:ok, res} <- index_text(did, source, text, opts) do
      {:ok, Map.merge(res, %{extract_ms: extract_ms, text_bytes: byte_size(text)})}
    end
  end

  @doc "Removes every piece of one source (file deleted or re-indexed)."
  @spec delete_source(String.t(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def delete_source(did, source_id, space \\ "private") do
    filter = "source_id = '#{q(source_id)}'"
    DocWriter.run(did, fn -> PzDb.vec_delete(table_uri(did, space), filter) end)
  end

  # ── searching ───────────────────────────────────────────────────────

  @doc """
  Searches the owner's own table.

  Opts: :mode (:vector | :keyword | :hybrid), :space ("private"),
  :limit (10), :source_type ("file", "chat" …), :nprobes (index only, 20).

  Returns {:ok, %{mode, results: [%{id, source_type, source_id, title,
  chunk_index, text, score}], took_ms}}. Higher score = better match.
  """
  @spec search(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def search(did, query, opts \\ []) when is_binary(did) and is_binary(query) do
    mode = Keyword.get(opts, :mode, :vector)
    t0 = now_ms()

    result =
      case mode do
        :vector -> vector_search(did, query, opts)
        :keyword -> keyword_search(did, query, opts)
        :hybrid -> hybrid_search(did, query, opts)
        other -> {:error, {:unknown_mode, other}}
      end

    with {:ok, map} <- result do
      {:ok, map |> Map.put(:mode, mode) |> Map.put(:took_ms, now_ms() - t0)}
    end
  end

  defp vector_search(did, query, opts) do
    limit = Keyword.get(opts, :limit, 10)
    uri = table_uri(did, Keyword.get(opts, :space, "private"))

    with {:ok, %{"records" => recs} = raw} <-
           PzDb.vec_search(uri, query, limit, source_filter(opts), Keyword.get(opts, :nprobes, 20)) do
      results = Enum.map(recs, &to_result(&1, 1.0 - (&1["_distance"] || 1.0)))
      {:ok, %{results: results, embed_ms: raw["embed_ms"], search_ms: raw["search_ms"]}}
    end
  end

  # Rows whose text contains the query's words; score = share of words found.
  defp keyword_search(did, query, opts) do
    limit = Keyword.get(opts, :limit, 10)
    uri = table_uri(did, Keyword.get(opts, :space, "private"))

    case words(query) do
      [] ->
        {:ok, %{results: [], search_ms: 0}}

      words ->
        like = words |> Enum.map(&"lower(text) LIKE '%#{&1}%'") |> Enum.join(" OR ")
        filter = Enum.join(Enum.reject(["(#{like})", source_filter(opts)], &(&1 == "")), " AND ")

        with {:ok, %{"records" => recs} = raw} <- PzDb.vec_query(uri, filter, limit * 10) do
          results =
            recs
            |> Enum.map(fn r ->
              text = String.downcase(r["text"] || "")
              hits = Enum.count(words, &String.contains?(text, &1))
              to_result(r, hits / length(words))
            end)
            |> Enum.sort_by(& &1.score, :desc)
            |> Enum.take(limit)

          {:ok, %{results: results, search_ms: raw["search_ms"]}}
        end
    end
  end

  # Reciprocal rank fusion: a piece ranked high by either search ranks high.
  defp hybrid_search(did, query, opts) do
    wide = Keyword.put(opts, :limit, Keyword.get(opts, :limit, 10) * 3)

    with {:ok, %{results: vec}} <- vector_search(did, query, wide),
         {:ok, %{results: kw}} <- keyword_search(did, query, wide) do
      scores =
        [vec, kw]
        |> Enum.flat_map(fn list -> list |> Enum.with_index(1) |> Enum.map(fn {r, rank} -> {r, 1 / (60 + rank)} end) end)
        |> Enum.reduce(%{}, fn {r, s}, acc ->
          Map.update(acc, r.id, %{r | score: s}, fn old -> %{old | score: old.score + s} end)
        end)

      results =
        scores
        |> Map.values()
        |> Enum.sort_by(& &1.score, :desc)
        |> Enum.take(Keyword.get(opts, :limit, 10))
        |> Enum.map(&%{&1 | score: Float.round(&1.score, 5)})

      {:ok, %{results: results}}
    end
  end

  # ── speed / maintenance ─────────────────────────────────────────────

  @doc """
  Builds the vector index (IVF-PQ) on a user's table. Worth it from about
  10,000 pieces; small tables are searched fast enough without one.
  Opts: :space, :num_partitions (0 = auto), :num_sub_vectors (0 = auto).
  """
  @spec build_index(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def build_index(did, opts \\ []) do
    uri = table_uri(did, Keyword.get(opts, :space, "private"))
    p = Keyword.get(opts, :num_partitions, 0)
    s = Keyword.get(opts, :num_sub_vectors, 0)
    DocWriter.run_with_timeout(did, fn -> PzDb.vec_index(uri, p, s) end, @index_timeout_ms)
  end

  @doc "Merges small files and drops old versions now (the compactor also does it)."
  def optimize(did, space \\ "private") do
    keep = Keyword.get(Application.get_env(:przma, :lance_doc, []), :keep_versions_hours, 1)
    uri = table_uri(did, space)
    DocWriter.run_with_timeout(did, fn -> PzDb.vec_optimize(uri, keep) end, @index_timeout_ms)
  end

  @doc "Rows, version, vector size and indexes of a user's table."
  def stats(did, space \\ "private"), do: PzDb.vec_stats(table_uri(did, space))

  @doc "Loads the embedding model (call at boot to avoid a slow first search)."
  def model_info, do: PzDb.vec_model_info()

  # ── helpers ─────────────────────────────────────────────────────────

  defp maybe_replace(_did, _id, _space, false), do: :ok

  defp maybe_replace(did, id, space, true) do
    case delete_source(did, id, space) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, {:replace_failed, reason}}
    end
  end

  defp write_batches(did, uri, rows) do
    rows
    |> Enum.chunk_every(@batch_rows)
    |> Enum.reduce_while({:ok, %{embed_ms: 0, write_ms: 0, batches: 0}}, fn batch, {:ok, acc} ->
      case DocWriter.run_with_timeout(did, fn -> PzDb.vec_upsert(uri, batch) end, @write_timeout_ms) do
        {:ok, r} ->
          # many small writes -> the compactor merges the table's small files
          LanceCompactor.mark_dirty(did, uri)

          {:cont,
           {:ok,
            %{
              embed_ms: acc.embed_ms + (r["embed_ms"] || 0),
              write_ms: acc.write_ms + (r["write_ms"] || 0),
              batches: acc.batches + 1
            }}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp to_result(r, score) do
    %{
      id: r["id"],
      source_type: r["source_type"],
      source_id: r["source_id"],
      title: r["title"],
      chunk_index: r["chunk_index"],
      text: r["text"],
      score: Float.round(score * 1.0, 4)
    }
  end

  defp source_filter(opts) do
    case Keyword.get(opts, :source_type) do
      nil -> ""
      t -> "source_type = '#{q(t)}'"
    end
  end

  # Lower-case letters/digits only, so they are always safe inside LIKE '%…%'.
  defp words(query) do
    query
    |> String.downcase()
    |> String.split(~r/[^\p{L}\p{N}]+/u, trim: true)
    |> Enum.filter(&(String.length(&1) >= 2))
    |> Enum.uniq()
    |> Enum.take(8)
  end

  defp q(s), do: String.replace(to_string(s), "'", "''")
  defp now_ms, do: System.monotonic_time(:millisecond)
end
