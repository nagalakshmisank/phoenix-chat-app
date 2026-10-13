defmodule Przma.Sim.Metrics do
  @moduledoc """
  Latency / error recorder for Przma.Sim.LoadTest (ETS, safe from many
  processes at once) plus a background sampler for queue length, writer
  processes and BEAM memory.
  """

  @ops :przma_sim_ops
  @errs :przma_sim_errors
  @sys :przma_sim_system

  def reset do
    for t <- [@ops, @errs, @sys] do
      if :ets.whereis(t) != :undefined, do: :ets.delete(t)
    end

    :ets.new(@ops, [:named_table, :public, :duplicate_bag, write_concurrency: true])
    :ets.new(@errs, [:named_table, :public, :bag, write_concurrency: true])
    :ets.new(@sys, [:named_table, :public, :set])
    :ets.insert(@sys, [{:max_queue, 0}, {:max_writers, 0}, {:max_mem, 0}])
    :ok
  end

  @doc "Runs `fun`, records its time under `op`, returns its result."
  def measure(op, fun) do
    {us, result} = :timer.tc(fn -> safe(fun) end)
    ok? = ok?(result)
    :ets.insert(@ops, {op, us, ok?})

    unless ok? do
      if length(:ets.lookup(@errs, op)) < 5, do: :ets.insert(@errs, {op, inspect(result, limit: 20, printable_limit: 300)})
    end

    result
  end

  # An exception in one simulated request is recorded as an error; the run goes on.
  def safe(fun) do
    fun.()
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  def ok?(:ok), do: true
  def ok?({:ok, _}), do: true
  def ok?(_), do: false

  @doc "Summary per operation: count, errors, p50/p95/p99/max in ms."
  def summary do
    @ops
    |> :ets.tab2list()
    |> Enum.group_by(&elem(&1, 0), fn {_, us, ok} -> {us, ok} end)
    |> Enum.map(fn {op, rows} ->
      times = rows |> Enum.map(&elem(&1, 0)) |> Enum.sort()
      n = length(times)

      %{
        op: op,
        count: n,
        errors: Enum.count(rows, fn {_, ok} -> not ok end),
        p50_ms: pct(times, n, 0.50),
        p95_ms: pct(times, n, 0.95),
        p99_ms: pct(times, n, 0.99),
        max_ms: ms(List.last(times)),
        avg_ms: Float.round(Enum.sum(times) / max(n, 1) / 1000, 1)
      }
    end)
    |> Enum.sort_by(& &1.op)
  end

  def errors, do: :ets.tab2list(@errs) |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

  def system, do: Map.new(:ets.tab2list(@sys))

  @doc "Samples DocWriter queue length (for `dids`), writer count and memory every `every_ms`."
  def start_sampler(dids, every_ms \\ 250) do
    spawn(fn -> sample_loop(dids, every_ms) end)
  end

  def stop_sampler(pid), do: Process.exit(pid, :kill)

  defp sample_loop(dids, every_ms) do
    q = dids |> Enum.map(&Przma.Storage.DocWriter.queue_length/1) |> Enum.max(fn -> 0 end)
    bump(:max_queue, q)
    bump(:max_writers, Przma.Storage.DocWriter.count())
    bump(:max_mem, :erlang.memory(:total))
    Process.sleep(every_ms)
    sample_loop(dids, every_ms)
  end

  defp bump(key, value) do
    case :ets.lookup(@sys, key) do
      [{^key, old}] when old >= value -> :ok
      _ -> :ets.insert(@sys, {key, value})
    end
  end

  defp pct(_times, 0, _p), do: 0.0
  defp pct(times, n, p), do: times |> Enum.at(min(n - 1, trunc(Float.ceil(n * p)) - 1)) |> ms()

  defp ms(nil), do: 0.0
  defp ms(us), do: Float.round(us / 1000, 1)
end
