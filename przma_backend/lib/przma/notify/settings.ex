defmodule Przma.Notify.Settings do
  @moduledoc """
  Per-user notification switches, one per category:

      social:private:notification_settings:default

  Categories: message, circle_message, file, circle, follow. A category
  that is switched off still stores and counts its items; they are just
  delivered silently (no alert).
  """

  alias Przma.Social.Store

  @categories ~w(message circle_message file circle follow)
  @id "default"

  def categories, do: @categories

  def get(did) do
    stored =
      case Store.get(did, "social", "notification_settings", @id) do
        {:ok, doc} -> doc
        _ -> %{}
      end

    {:ok, Map.new(@categories, fn c -> {c, Map.get(stored, c, true) != false} end)}
  end

  def update(did, changes) do
    fields =
      changes
      |> Map.new(fn {k, v} -> {to_string(k), v} end)
      |> Map.take(@categories)
      |> Enum.filter(fn {_k, v} -> is_boolean(v) end)
      |> Map.new()

    with :ok <- Store.put(did, "social", "notification_settings", @id, fields), do: get(did)
  end

  def enabled?(did, category) when category in @categories do
    {:ok, settings} = get(did)
    settings[category]
  end

  def enabled?(_did, _category), do: true
end
