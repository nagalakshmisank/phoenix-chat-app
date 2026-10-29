defmodule Przma.Calendar.ReminderScheduler do
  @moduledoc """
  Every `interval_ms` (default 60 s) fires the reminders that are due.

  Reads {system}/calendar/private/reminders.lance with
      after: <cursor>   before: <now>
  — ids start with the fire time, so this returns exactly the rows that
  came due since the last run, oldest first. The cursor (last id handled)
  is saved in {system}/calendar/private/scheduler.lance so a restart
  continues where it stopped (up to 1 hour back on the very first start).

  Config (config/config.exs):
      config :przma, Przma.Calendar.ReminderScheduler,
        enabled: true, interval_ms: 60_000, import_holidays_on_boot: false

  SINGLE NODE: run exactly one scheduler. With several Phoenix nodes,
  enable it on one node only (enabled: false on the others).
  """

  use GenServer
  require Logger

  alias Przma.Calendar.{Calendars, Holidays, Ids, Reminders}
  alias Przma.Social.Store

  @page 1000
  @first_start_lookback_us 3_600_000_000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Runs one pass now (handy in iex)."
  def run_now, do: GenServer.call(__MODULE__, :run_now, 120_000)

  @impl true
  def init(_opts) do
    if cfg(:enabled, true) do
      Process.send_after(self(), :tick, 5_000)
      {:ok, %{cursor: nil}, {:continue, :boot}}
    else
      :ignore
    end
  end

  @impl true
  def handle_continue(:boot, state) do
    if cfg(:import_holidays_on_boot, false) do
      Task.start(fn -> Holidays.import_bundled() end)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(:tick, state) do
    state = safe_run(state)
    Process.send_after(self(), :tick, cfg(:interval_ms, 60_000))
    {:noreply, state}
  end

  @impl true
  def handle_call(:run_now, _from, state) do
    state = safe_run(state)
    {:reply, :ok, state}
  end

  # ── private ──────────────────────────────────────────────────────────

  defp safe_run(state) do
    cursor = state.cursor || load_cursor()
    %{state | cursor: run(cursor)}
  rescue
    error ->
      Logger.warning("ReminderScheduler pass failed: #{inspect(error)}")
      state
  end

  defp run(cursor) do
    before = Ids.pad(Ids.now_us() + 1)

    case Store.list(Ids.system_did(), "calendar", "reminders", after: cursor, before: before, limit: @page) do
      {:ok, []} ->
        cursor

      {:ok, rows} ->
        Enum.each(rows, &fire_safely/1)
        new_cursor = List.last(rows)["id"]
        save_cursor(new_cursor)
        if length(rows) == @page, do: run(new_cursor), else: new_cursor

      {:error, reason} ->
        Logger.warning("ReminderScheduler read failed: #{inspect(reason)}")
        cursor
    end
  end

  defp fire_safely(row) do
    Reminders.fire(row)
  rescue
    error -> Logger.warning("reminder #{row["id"]} failed: #{inspect(error)}")
  end

  defp load_cursor do
    case Store.get(Ids.system_did(), "calendar", "scheduler", "reminders") do
      {:ok, %{"cursor" => cursor}} when is_binary(cursor) -> cursor
      _ -> Ids.pad(Ids.now_us() - @first_start_lookback_us)
    end
  end

  defp save_cursor(cursor), do: Calendars.system_put("scheduler", "reminders", %{"cursor" => cursor})

  defp cfg(key, default), do: :przma |> Application.get_env(__MODULE__, []) |> Keyword.get(key, default)
end
