defmodule Przma.Calendar.Holidays do
  @moduledoc """
  Regional holidays, shown on top of every calendar (read-only).

  Stored ONCE for everybody, in the calendar system DID's PUBLIC space:

      {system}/calendar/public/holidays.lance   {region}-{yyyymmdd}-{slug}
        region, date "2026-01-26", name, holiday_kind (public | optional | festival)

  Region codes: country "IN", or country_state "IN_TN". A calendar whose
  region is "IN_TN" shows both "IN" (national) and "IN_TN" (state) holidays.

  Data comes from JSON files in priv/calendar/holidays/*.json (one array
  of {region, date, name, holiday_kind}). Load them with
      Przma.Calendar.Holidays.import_bundled()
  (or set import_holidays_on_boot: true for the scheduler).
  """

  alias Przma.Calendar.{Calendars, Ids}
  alias Przma.Social.Store

  @region ~r/^[A-Z]{2}(_[A-Z0-9]{1,3})?$/
  @ist_offset_min 330

  def import_bundled do
    :przma
    |> Application.app_dir("priv/calendar/holidays/*.json")
    |> Path.wildcard()
    |> Enum.map(&import_file/1)
  end

  def import_file(path) do
    with {:ok, body} <- File.read(path),
         {:ok, rows} when is_list(rows) <- Jason.decode(body) do
      results = Enum.map(rows, &put/1)
      {:ok, path, Enum.count(results, &(&1 == :ok))}
    else
      err -> {:error, path, err}
    end
  end

  def put(%{"region" => region, "date" => date, "name" => name} = row) do
    with true <- Regex.match?(@region, region),
         {:ok, d} <- Date.from_iso8601(date) do
      Calendars.system_put(
        "holidays",
        "#{region}-#{yyyymmdd(d)}-#{slug(name)}",
        %{
          "region" => region,
          "date" => Date.to_iso8601(d),
          "name" => name,
          "holiday_kind" => row["holiday_kind"] || "public",
          "status" => "active"
        },
        space: "public"
      )
    else
      _ -> {:error, :invalid_holiday}
    end
  end

  def put(_), do: {:error, :invalid_holiday}

  @doc "API: holidays of one region between two ISO times."
  def list(region, from_iso, to_iso) do
    with true <- is_binary(region) and Regex.match?(@region, region),
         {:ok, from, _} <- Ids.parse_time(from_iso),
         {:ok, to, _} <- Ids.parse_time(to_iso) do
      {:ok, overlay([region], from, to)}
    else
      false -> {:error, :invalid_region}
      err -> err
    end
  end

  @doc "Holiday items (same shape as event occurrences, kind \"holiday\") for [from, to)."
  def overlay(regions, from, to) do
    from_date = Ids.local_date(from, @ist_offset_min)
    to_date = Ids.local_date(to - 1, @ist_offset_min)

    regions
    |> Enum.flat_map(&expand/1)
    |> Enum.uniq()
    |> Enum.flat_map(fn region ->
      case Store.list(Ids.system_did(), "calendar", "holidays",
             space: "public",
             prefix: region <> "-",
             after: "#{region}-#{yyyymmdd(from_date)}",
             before: "#{region}-#{yyyymmdd(Date.add(to_date, 1))}",
             limit: 1000
           ) do
        {:ok, rows} -> for %{"status" => "active"} = row <- rows, do: view(row)
        _ -> []
      end
    end)
  end

  defp view(row) do
    {:ok, date} = Date.from_iso8601(row["date"])
    start = DateTime.new!(date, ~T[00:00:00], "Etc/UTC") |> DateTime.to_unix(:microsecond)
    start = start - @ist_offset_min * Ids.minute_us()

    %{
      "kind" => "holiday",
      "event_id" => row["id"],
      "title" => row["name"],
      "holiday_kind" => row["holiday_kind"],
      "region" => row["region"],
      "all_day" => true,
      "status" => "confirmed",
      "starts_at" => Ids.to_local_iso(start, @ist_offset_min),
      "occurrence_start" => Ids.to_local_iso(start, @ist_offset_min),
      "my_role" => "viewer",
      "sort_key" => start
    }
  end

  # "IN_TN" -> ["IN", "IN_TN"]; "IN" -> ["IN"]
  defp expand(region) when is_binary(region) do
    if Regex.match?(@region, region) do
      case String.split(region, "_", parts: 2) do
        [country, _state] -> [country, region]
        [country] -> [country]
      end
    else
      []
    end
  end

  defp expand(_), do: []

  defp yyyymmdd(%Date{} = d), do: Date.to_iso8601(d, :basic)

  defp slug(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
    |> String.slice(0, 40)
    |> case do
      "" -> "holiday"
      s -> s
    end
  end
end
