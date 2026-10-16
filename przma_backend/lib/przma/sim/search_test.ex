defmodule Przma.Sim.SearchTest do
  @moduledoc """
  Tests Lance documents + embeddings + vector search end to end, through the
  real code path (Przma.Search -> PRZMA.PzDb -> Rust NIF -> LanceDB -> S3).

      Przma.Sim.SearchTest.run()                                   # all tests, 10,000-piece scale test
      Przma.Sim.SearchTest.run(scale: 2_000, concurrency_seconds: 20)
      Przma.Sim.SearchTest.run(file: "/tmp/sample.pdf", file_query: "refund policy")

  Tests
    1 model        load the embedding model, vector size
    2 embed        speed of embedding 1,000 sentences
    3 accuracy     16 short documents, 14 questions worded differently: is the right one 1st / in top 3?
    4 keyword      word search ("biryani")
    5 hybrid       meaning + words together, same 14 questions
    6 privacy      user A never gets user B's documents
    7 scale        N pieces: save speed, search speed without and with the vector index, index recall
    8 big file     (only with file:) extract -> split -> embed -> save -> search
    9 concurrency  3 users each saving messages while searching their own table

  Users are did:przma:simsearch<run>_a / _b / _c / _w1.. so the data can be
  removed afterwards with:  Przma.Sim.LoadTest.cleanup("search<run>", confirm: true)

  Report: printed, and saved as /tmp/przma_search_<run>.json
  """

  alias PRZMA.PzDb
  alias Przma.Search
  alias Przma.Storage.DocWriter

  # 16 short documents: {key, owner, title, text}
  @docs [
    {"ooty", :a, "Ooty trip plan", "Family trip to Ooty: we took the toy train, walked in the tea gardens and stayed three nights at Sterling resort near the lake."},
    {"goa", :a, "Goa holiday video", "Holiday video from Goa beach with the sunset and big waves, recorded on the last evening."},
    {"invoice", :a, "Hosting invoice", "Invoice for October web hosting, payment of 4500 rupees due by the end of the month."},
    {"electricity", :a, "Electricity bill", "Electricity bill for September has been paid, the amount was 2300 rupees."},
    {"biryani", :a, "Biryani recipe", "Recipe for chicken biryani with basmati rice, onions, yoghurt and whole spices cooked on low flame."},
    {"dosa", :a, "Dosa recipe", "How to make crispy masala dosa with potato filling and coconut chutney."},
    {"release", :a, "Team meeting notes", "Team meeting notes: we agreed to release the chat app to customers on Friday."},
    {"deadline", :a, "Client call", "After the client call the project deadline was moved to next Monday."},
    {"car", :a, "Car service", "Car service booked at the showroom for a brake check and oil change."},
    {"cricket", :a, "Cricket highlights", "Cricket match highlights: India versus Australia, a great chase in the final over."},
    {"football", :a, "Football training", "Football training happens every Saturday morning at the school ground."},
    {"pandas", :a, "Python tutorial", "Python tutorial on reading CSV files with the pandas library and cleaning the columns."},
    {"genserver", :a, "Elixir example", "Elixir GenServer example that keeps a simple counter in its state."},
    {"wedding", :a, "Wedding invitation", "Wedding invitation for my cousin's marriage in Madurai next month."},
    {"birthday", :a, "Birthday plan", "Birthday party plan with a chocolate cake, balloons and decorations at home."},
    {"secret", :b, "B private note", "User B private note: the locker code for the office cupboard is kept with the manager."}
  ]

  # questions use different words from the documents: {question, expected key}
  @questions [
    {"where did we stay in the hill station?", "ooty"},
    {"beach holiday clip", "goa"},
    {"how much is the server hosting bill", "invoice"},
    {"power bill payment", "electricity"},
    {"how do I cook rice with chicken", "biryani"},
    {"south indian breakfast recipe", "dosa"},
    {"when will the app launch", "release"},
    {"the deadline was postponed", "deadline"},
    {"vehicle maintenance appointment", "car"},
    {"sports match summary", "cricket"},
    {"weekend soccer practice", "football"},
    {"load a spreadsheet file in python", "pandas"},
    {"process that holds state in elixir", "genserver"},
    {"marriage invite", "wedding"}
  ]

  @words ~w(meeting project report invoice payment travel train hotel beach video photo family friend
            school office client release deadline recipe rice chicken spices cricket football match
            weather rain summer winter city village market price budget salary loan bank account phone
            laptop software server database search document file upload download music movie song
            doctor hospital medicine garden flower tree river lake mountain road car bus bike ticket)

  def run(opts \\ []) do
    run_id = :crypto.strong_rand_bytes(3) |> Base.encode16(case: :lower)
    scale = Keyword.get(opts, :scale, 10_000)
    conc_s = Keyword.get(opts, :concurrency_seconds, 30)
    old_level = Logger.level()
    Logger.configure(level: :critical)

    users = %{a: did(run_id, "a"), b: did(run_id, "b"), c: did(run_id, "c")}
    IO.puts("\n=== SEARCH TEST run=#{run_id}  scale=#{scale}  concurrency=#{conc_s}s ===")

    try do
      report =
        %{run_id: run_id, base: Application.get_env(:przma, :vault_base_path)}
        |> step(:t1_model, fn -> t_model() end)
        |> step(:t2_embed, fn -> t_embed() end)
        |> step(:t3_accuracy, fn -> t_accuracy(users) end)
        |> step(:t4_keyword, fn -> t_keyword(users) end)
        |> step(:t5_hybrid, fn -> t_hybrid(users) end)
        |> step(:t6_privacy, fn -> t_privacy(users) end)
        |> step(:t7_scale, fn -> t_scale(users.c, scale) end)
        |> then(fn r ->
          case Keyword.get(opts, :file) do
            nil -> r
            path -> step(r, :t8_big_file, fn -> t_file(users.a, path, Keyword.get(opts, :file_query, "summary")) end)
          end
        end)
        |> step(:t9_concurrency, fn -> t_concurrency(run_id, conc_s) end)

      path = "/tmp/przma_search_#{run_id}.json"
      File.write!(path, Jason.encode!(report, pretty: true))
      print_summary(report)
      IO.puts("\nReport saved: #{path}")
      IO.puts("Cleanup: Przma.Sim.LoadTest.cleanup(\"search#{run_id}\", confirm: true)")
      report
    after
      Logger.configure(level: old_level)
    end
  end

  # ── tests ───────────────────────────────────────────────────────────

  defp t_model do
    {:ok, info} = Search.model_info()
    %{model: info["model"], dim: info["dim"], load_ms: info["load_ms"]}
  end

  defp t_embed do
    texts = for i <- 1..1000, do: sentence(i, 20)
    {:ok, r} = PzDb.vec_embed(texts)
    ms = max(r["embed_ms"], 1)
    %{texts: r["count"], dim: r["dim"], embed_ms: ms, per_second: round(r["count"] * 1000 / ms)}
  end

  defp t_accuracy(users) do
    save =
      for {key, owner, title, text} <- @docs do
        {:ok, r} = Search.index_text(Map.fetch!(users, owner), %{type: "doc", id: key, title: title}, text)
        r.write_ms
      end

    rows =
      for {question, expected} <- @questions do
        {:ok, res} = Search.search(users.a, question, limit: 3)
        ids = Enum.map(res.results, & &1.source_id)
        %{question: question, expected: expected, got: ids, top1: List.first(ids) == expected, top3: expected in ids, ms: res.took_ms}
      end

    %{
      documents: length(@docs),
      save_ms: stats(save),
      questions: length(rows),
      top1_correct: Enum.count(rows, & &1.top1),
      top3_correct: Enum.count(rows, & &1.top3),
      search_ms: stats(Enum.map(rows, & &1.ms)),
      wrong: rows |> Enum.reject(& &1.top1) |> Enum.map(&Map.take(&1, [:question, :expected, :got]))
    }
  end

  defp t_keyword(users) do
    {:ok, res} = Search.search(users.a, "biryani", mode: :keyword, limit: 3)
    ids = Enum.map(res.results, & &1.source_id)
    %{query: "biryani", got: ids, correct: List.first(ids) == "biryani", ms: res.took_ms}
  end

  defp t_hybrid(users) do
    rows =
      for {question, expected} <- @questions do
        {:ok, res} = Search.search(users.a, question, mode: :hybrid, limit: 3)
        ids = Enum.map(res.results, & &1.source_id)
        %{top1: List.first(ids) == expected, top3: expected in ids, ms: res.took_ms}
      end

    %{questions: length(rows), top1_correct: Enum.count(rows, & &1.top1), top3_correct: Enum.count(rows, & &1.top3), search_ms: stats(Enum.map(rows, & &1.ms))}
  end

  defp t_privacy(users) do
    {:ok, a} = Search.search(users.a, "locker code office cupboard manager", mode: :hybrid, limit: 10)
    {:ok, b} = Search.search(users.b, "Ooty trip tea gardens", mode: :hybrid, limit: 10)
    leaks_to_a = Enum.count(a.results, &(&1.source_id == "secret"))
    leaks_to_b = Enum.count(b.results, &(&1.source_id != "secret"))
    %{a_sees_b_docs: leaks_to_a, b_sees_a_docs: leaks_to_b, ok: leaks_to_a == 0 and leaks_to_b == 0}
  end

  defp t_scale(did, n) do
    uri = Search.table_uri(did)
    now = System.os_time(:microsecond)
    t0 = now_ms()

    batch_ms =
      1..n
      |> Enum.chunk_every(1000)
      |> Enum.map(fn ids ->
        rows =
          for i <- ids do
            %{id: "scale##{i}", did: did, space: "private", source_type: "scale", source_id: "s#{i}", title: "piece #{i}",
              chunk_index: 0, text: sentence(i, 30), created_at: now}
          end

        t = now_ms()
        {:ok, _} = DocWriter.run_with_timeout(did, fn -> PzDb.vec_upsert(uri, rows) end, 300_000)
        now_ms() - t
      end)

    save_total = now_ms() - t0
    queries = for i <- 1..20, do: sentence(i * 7919, 8)
    {before_ms, before_ids} = timed_searches(did, queries)

    t = now_ms()
    index = Search.build_index(did)
    index_ms = now_ms() - t
    {after_ms, after_ids} = timed_searches(did, queries)

    recall =
      Enum.zip(before_ids, after_ids)
      |> Enum.map(fn {exact, approx} -> length(exact -- (exact -- approx)) / max(length(exact), 1) end)
      |> then(&(Enum.sum(&1) / max(length(&1), 1)))

    {:ok, st} = Search.stats(did)

    %{
      pieces: n,
      save_total_ms: save_total,
      save_per_1000_ms: stats(batch_ms),
      pieces_per_second: round(n * 1000 / max(save_total, 1)),
      search_no_index_ms: stats(before_ms),
      index_build: (case index do
        {:ok, r} -> %{ok: true, ms: index_ms, rows: r["rows"]}
        {:error, e} -> %{ok: false, error: inspect(e)}
      end),
      search_with_index_ms: stats(after_ms),
      recall_at_10: Float.round(recall, 3),
      table: Map.take(st, ["rows", "version", "dim", "indices"])
    }
  end

  defp t_file(did, path, query) do
    size = File.stat!(path).size

    case Search.index_file(did, %{type: "file", id: "bigfile", title: Path.basename(path)}, path) do
      {:ok, r} ->
        {:ok, res} = Search.search(did, query, limit: 3, source_type: "file")

        %{
          file: path, file_bytes: size, text_bytes: r.text_bytes, pieces: r.chunks,
          extract_ms: r.extract_ms, embed_ms: r.embed_ms, write_ms: r.write_ms,
          query: query, search_ms: res.took_ms,
          top3: Enum.map(res.results, &%{score: &1.score, text: String.slice(&1.text, 0, 120)})
        }

      {:error, reason} ->
        %{file: path, error: inspect(reason)}
    end
  end

  # 3 users: each saves messages to its own table while searching it.
  defp t_concurrency(run_id, seconds) do
    deadline = now_ms() + seconds * 1000

    tasks =
      for u <- 1..3 do
        did = did(run_id, "w#{u}")

        writer = Task.async(fn -> writer_loop(did, deadline, 1, []) end)
        reader = Task.async(fn -> reader_loop(did, deadline, []) end)
        {did, writer, reader}
      end

    per_user =
      for {did, w, r} <- tasks do
        writes = Task.await(w, :infinity)
        reads = Task.await(r, :infinity)
        {:ok, st} = Search.stats(did)
        ok_w = for {:ok, ms} <- writes, do: ms
        %{writes: writes, reads: reads, ok_w: ok_w, rows: st["rows"] || 0}
      end

    all_w = Enum.flat_map(per_user, & &1.writes)
    all_r = Enum.flat_map(per_user, & &1.reads)
    ok_w = for {:ok, ms} <- all_w, do: ms
    ok_r = for {:ok, ms} <- all_r, do: ms

    %{
      seconds: seconds,
      users: 3,
      messages_saved: length(ok_w),
      save_failed: length(all_w) - length(ok_w),
      save_ms: stats(ok_w),
      searches: length(ok_r),
      search_failed: length(all_r) - length(ok_r),
      search_ms: stats(ok_r),
      every_saved_message_in_table: Enum.all?(per_user, &(&1.rows == length(&1.ok_w))),
      first_errors: (for({:error, e} <- all_w ++ all_r, do: e) |> Enum.take(3))
    }
  end

  defp writer_loop(did, deadline, n, acc) do
    if now_ms() < deadline do
      t = now_ms()

      r =
        case Search.index_text(did, %{type: "chat", id: "m#{n}", title: "chat"}, sentence(n, 15), replace: false) do
          {:ok, _} -> {:ok, now_ms() - t}
          {:error, e} -> {:error, inspect(e) |> String.slice(0, 200)}
        end

      writer_loop(did, deadline, n + 1, [r | acc])
    else
      acc
    end
  end

  defp reader_loop(did, deadline, acc) do
    if now_ms() < deadline do
      t = now_ms()

      r =
        case Search.search(did, sentence(System.unique_integer([:positive]), 6), limit: 5) do
          {:ok, _} -> {:ok, now_ms() - t}
          {:error, e} -> {:error, inspect(e) |> String.slice(0, 200)}
        end

      Process.sleep(1000)
      reader_loop(did, deadline, [r | acc])
    else
      acc
    end
  end

  # ── output ──────────────────────────────────────────────────────────

  defp print_summary(r) do
    IO.puts("\n================ SEARCH TEST REPORT  run=#{r.run_id} ================")
    line(r, :t1_model, fn m -> "Model: #{m.model}  (#{m.dim} numbers per text, loaded in #{m.load_ms} ms)" end)
    line(r, :t2_embed, fn m -> "Embedding: #{m.texts} sentences in #{m.embed_ms} ms  (#{m.per_second}/s)" end)
    line(r, :t3_accuracy, fn m -> "Accuracy (meaning): right answer 1st #{m.top1_correct}/#{m.questions}, in top 3 #{m.top3_correct}/#{m.questions}   search #{fmt(m.search_ms)}" end)
    line(r, :t4_keyword, fn m -> "Keyword search 'biryani': #{if m.correct, do: "correct", else: "WRONG"}  (#{m.ms} ms)" end)
    line(r, :t5_hybrid, fn m -> "Hybrid: right answer 1st #{m.top1_correct}/#{m.questions}, in top 3 #{m.top3_correct}/#{m.questions}" end)
    line(r, :t6_privacy, fn m -> "Privacy: #{if m.ok, do: "OK - no user sees another user's documents", else: "LEAK #{inspect(m)}"}" end)

    line(r, :t7_scale, fn m ->
      "Scale #{m.pieces} pieces: saved in #{m.save_total_ms} ms (#{m.pieces_per_second}/s)\n" <>
        "   search without index #{fmt(m.search_no_index_ms)}\n" <>
        "   index build #{inspect(m.index_build)}\n" <>
        "   search with index    #{fmt(m.search_with_index_ms)}   recall@10 #{m.recall_at_10}"
    end)

    line(r, :t8_big_file, fn m ->
      if m[:error], do: "Big file: ERROR #{m.error}",
        else: "Big file #{m.file_bytes} bytes -> #{m.pieces} pieces: extract #{m.extract_ms} ms, embed #{m.embed_ms} ms, save #{m.write_ms} ms, search #{m.search_ms} ms"
    end)

    line(r, :t9_concurrency, fn m ->
      "Concurrency #{m.users} users x #{m.seconds}s: #{m.messages_saved} saved (#{m.save_failed} failed) #{fmt(m.save_ms)}\n" <>
        "   #{m.searches} searches (#{m.search_failed} failed) #{fmt(m.search_ms)}   all saved messages present: #{m.every_saved_message_in_table}"
    end)
  end

  defp line(r, key, fun) do
    case Map.get(r, key) do
      nil -> :ok
      %{error: e} = m when map_size(m) == 1 -> IO.puts("#{key}: ERROR #{e}")
      m -> IO.puts(fun.(m))
    end
  end

  # ── helpers ─────────────────────────────────────────────────────────

  defp step(report, name, fun) do
    IO.puts("  running #{name} ...")

    value =
      try do
        fun.()
      rescue
        e -> %{error: Exception.message(e) |> String.slice(0, 300)}
      catch
        kind, reason -> %{error: "#{kind}: #{inspect(reason) |> String.slice(0, 300)}"}
      end

    Map.put(report, name, value)
  end

  defp timed_searches(did, queries) do
    results =
      for q <- queries do
        t = now_ms()
        {:ok, res} = Search.search(did, q, limit: 10)
        {now_ms() - t, Enum.map(res.results, & &1.id)}
      end

    {Enum.map(results, &elem(&1, 0)), Enum.map(results, &elem(&1, 1))}
  end

  # Deterministic pseudo-random sentence from the word list (same seed = same sentence).
  defp sentence(seed, n) do
    count = length(@words)
    state = :rand.seed_s(:exsss, {seed, seed * 7 + 1, seed * 13 + 3})

    {words, _} =
      Enum.map_reduce(1..n, state, fn _, st ->
        {i, st} = :rand.uniform_s(count, st)
        {Enum.at(@words, i - 1), st}
      end)

    Enum.join(words, " ")
  end

  defp did(run_id, tag), do: "did:przma:simsearch#{run_id}_#{tag}"

  defp stats([]), do: %{count: 0}

  defp stats(list) do
    s = Enum.sort(list)
    n = length(s)
    at = fn p -> Enum.at(s, min(n - 1, max(trunc(Float.ceil(n * p)) - 1, 0))) end
    %{count: n, p50: at.(0.5), p95: at.(0.95), max: List.last(s)}
  end

  defp fmt(%{count: 0}), do: "-"
  defp fmt(%{p50: a, p95: b, max: c}), do: "p50 #{a} ms, p95 #{b} ms, max #{c} ms"
  defp fmt(_), do: "-"

  defp now_ms, do: System.monotonic_time(:millisecond)
end
